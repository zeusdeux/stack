{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}

-- | Run a GHCi configured with the user's package(s).

module Stack.Ghci
    ( GhciOpts(..)
    , GhciPkgInfo(..)
    , ghciSetup
    , ghci
    ) where

import           Control.Exception.Enclosed (tryAny)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.RWS.Strict
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Resource
import qualified Data.ByteString.Char8 as S8
import           Data.Either
import           Data.Function
import           Data.List
import           Data.List.Extra (nubOrd)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Maybe.Extra (forMaybeM)
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Distribution.ModuleName (ModuleName)
import           Distribution.Text (display)
import           Network.HTTP.Client.Conduit
import           Path
import           Path.Extra (toFilePathNoTrailingSep)
import           Path.IO
import           Prelude
import           Stack.Build
import           Stack.Build.Installed
import           Stack.Build.Source
import           Stack.Build.Target
import           Stack.Constants
import           Stack.Exec
import           Stack.Package
import           Stack.Types
import           Stack.Types.Internal
import           System.Directory (getTemporaryDirectory)

-- | Command-line options for GHC.
data GhciOpts = GhciOpts
    { ghciNoBuild            :: !Bool
    , ghciArgs               :: ![String]
    , ghciGhcCommand         :: !(Maybe FilePath)
    , ghciNoLoadModules      :: !Bool
    , ghciAdditionalPackages :: ![String]
    , ghciMainIs             :: !(Maybe Text)
    , ghciSkipIntermediate   :: !Bool
    , ghciBuildOpts          :: !BuildOpts
    } deriving Show

-- | Necessary information to load a package or its components.
data GhciPkgInfo = GhciPkgInfo
    { ghciPkgName :: !PackageName
    , ghciPkgOpts :: ![(NamedComponent, BuildInfoOpts)]
    , ghciPkgDir :: !(Path Abs Dir)
    , ghciPkgModules :: !(Set ModuleName)
    , ghciPkgModFiles :: !(Set (Path Abs File)) -- ^ Module file paths.
    , ghciPkgCFiles :: !(Set (Path Abs File)) -- ^ C files.
    , ghciPkgMainIs :: !(Map NamedComponent (Set (Path Abs File)))
    , ghciPkgPackage :: !Package
    } deriving Show

-- | Launch a GHCi session for the given local package targets with the
-- given options and configure it with the load paths and extensions
-- of those targets.
ghci
    :: (HasConfig r, HasBuildConfig r, HasHttpManager r, MonadMask m, HasLogLevel r, HasTerminal r, HasEnvConfig r, MonadReader r m, MonadIO m, MonadThrow m, MonadLogger m, MonadCatch m, MonadBaseControl IO m)
    => GhciOpts -> m ()
ghci GhciOpts{..} = do
    let bopts = ghciBuildOpts
            { boptsTestOpts = (boptsTestOpts ghciBuildOpts) { toDisableRun = True }
            , boptsBenchmarkOpts = (boptsBenchmarkOpts ghciBuildOpts) { beoDisableRun = True }
            }
    (targets,mainIsTargets,pkgs) <- ghciSetup bopts ghciNoBuild ghciSkipIntermediate ghciMainIs
    config <- asks getConfig
    bconfig <- asks getBuildConfig
    mainFile <- figureOutMainFile bopts mainIsTargets targets pkgs
    wc <- getWhichCompiler
    let pkgopts = hidePkgOpt ++ genOpts ++ ghcOpts
        hidePkgOpt = if null pkgs then [] else ["-hide-all-packages"]
        genOpts = nubOrd (concatMap (concatMap (bioOneWordOpts . snd) . ghciPkgOpts) pkgs)
        (omittedOpts, ghcOpts) = partition badForGhci $
            concatMap (concatMap (bioOpts . snd) . ghciPkgOpts) pkgs ++
            getUserOptions Nothing ++
            concatMap (getUserOptions . Just . ghciPkgName) pkgs
        getUserOptions mpkg =
            map T.unpack (M.findWithDefault [] mpkg (configGhcOptions config))
        badForGhci x =
            isPrefixOf "-O" x || elem x (words "-debug -threaded -ticky -static -Werror")
    unless (null omittedOpts) $
        $logWarn
            ("The following GHC options are incompatible with GHCi and have not been passed to it: " <>
             T.unwords (map T.pack (nubOrd omittedOpts)))
    oiDir <- objectInterfaceDir bconfig
    let modulesToLoad = nubOrd $
            concatMap (map display . S.toList . ghciPkgModules) pkgs
        thingsToLoad =
            maybe [] (return . toFilePath) mainFile <> modulesToLoad
        odir =
            [ "-odir=" <> toFilePathNoTrailingSep oiDir
            , "-hidir=" <> toFilePathNoTrailingSep oiDir ]
    $logInfo
        ("Configuring GHCi with the following packages: " <>
         T.intercalate ", " (map (packageNameText . ghciPkgName) pkgs))
    let execGhci extras = do
            menv <- liftIO $ configEnvOverride config defaultEnvSettings
            exec menv
                 (fromMaybe (compilerExeName wc) ghciGhcCommand)
                 ("--interactive" :
                 -- This initial "-i" resets the include directories to not
                 -- include CWD.
                  "-i" :
                  odir <> pkgopts <> ghciArgs <> extras)
    tmp <- liftIO getTemporaryDirectory
    withCanonicalizedTempDirectory tmp "ghci" $ \tmpDir -> do
        let macrosFile = tmpDir </> $(mkRelFile "cabal_macros.h")
        macrosOpts <- preprocessCabalMacros pkgs macrosFile
        if ghciNoLoadModules
            then execGhci macrosOpts
            else do
                let scriptPath = tmpDir </> $(mkRelFile "ghci-script")
                    fp = toFilePath scriptPath
                    loadModules = ":load " <> unwords (map show thingsToLoad)
                    bringIntoScope = ":module + " <> unwords modulesToLoad
                liftIO (writeFile fp (unlines [loadModules,bringIntoScope]))
                execGhci (macrosOpts ++ ["-ghci-script=" <> fp])

-- | Figure out the main-is file to load based on the targets. Sometimes there
-- is none, sometimes it's unambiguous, sometimes it's
-- ambiguous. Warns and returns nothing if it's ambiguous.
figureOutMainFile
    :: (Monad m, MonadLogger m)
    => BuildOpts
    -> Maybe (Map PackageName SimpleTarget)
    -> Map PackageName SimpleTarget
    -> [GhciPkgInfo]
    -> m (Maybe (Path Abs File))
figureOutMainFile bopts mainIsTargets targets0 packages =
    case candidates of
        [] -> return Nothing
        [c@(_,_,fp)] -> do $logInfo ("Using main module: " <> renderCandidate c)
                           return (Just fp)
        candidate:_ -> borderedWarning $ do
            $logWarn "The main module to load is ambiguous. Candidates are: "
            forM_ (map renderCandidate candidates) $logWarn
            $logWarn
                "None will be loaded. You can specify which one to pick by: "
            $logWarn
                (" 1) Specifying targets to stack ghci e.g. stack ghci " <>
                 sampleTargetArg candidate)
            $logWarn
                (" 2) Specifying what the main is e.g. stack ghci " <>
                 sampleMainIsArg candidate)
            return Nothing
  where
    targets = fromMaybe targets0 mainIsTargets
    candidates = do
        pkg <- packages
        case M.lookup (ghciPkgName pkg) targets of
            Nothing -> []
            Just target -> do
                (component,mains) <-
                    M.toList $
                    M.filterWithKey (\k _ -> k `S.member` wantedComponents)
                                    (ghciPkgMainIs pkg)
                main <- S.toList mains
                return (ghciPkgName pkg, component, main)
              where
                wantedComponents =
                    wantedPackageComponents bopts target (ghciPkgPackage pkg)
    renderCandidate (pkgName,namedComponent,mainIs) =
        "Package `" <> packageNameText pkgName <> "' component " <>
        renderComp namedComponent <>
        " with main-is file: " <>
        T.pack (toFilePath mainIs)
    renderComp c =
        case c of
            CLib -> "lib"
            CExe name -> "exe:" <> name
            CTest name -> "test:" <> name
            CBench name -> "bench:" <> name
    sampleTargetArg (pkg,comp,_) =
        packageNameText pkg <> ":" <> renderComp comp
    sampleMainIsArg (pkg,comp,_) =
        "--main-is " <> packageNameText pkg <> ":" <> renderComp comp

-- | Create a list of infos for each target containing necessary
-- information to load that package/components.
ghciSetup
    :: (HasConfig r, HasHttpManager r, HasBuildConfig r, MonadMask m, HasTerminal r, HasLogLevel r, HasEnvConfig r, MonadReader r m, MonadIO m, MonadThrow m, MonadLogger m, MonadCatch m, MonadBaseControl IO m)
    => BuildOpts
    -> Bool
    -> Bool
    -> Maybe Text
    -> m (Map PackageName SimpleTarget, Maybe (Map PackageName SimpleTarget), [GhciPkgInfo])
ghciSetup bopts noBuild skipIntermediate mainIs = do
    (_,_,targets) <- parseTargetsFromBuildOpts AllowNoTargets bopts
    mainIsTargets <-
        case mainIs of
            Nothing -> return Nothing
            Just target -> do
                (_,_,targets') <- parseTargetsFromBuildOpts AllowNoTargets bopts { boptsTargets = [target] }
                return (Just targets')
    econfig <- asks getEnvConfig
    (realTargets,_,_,_,sourceMap) <- loadSourceMap AllowNoTargets bopts
    menv <- getMinimalEnvOverride
    (installedMap, _, _, _) <- getInstalled
        menv
        GetInstalledOpts
            { getInstalledProfiling = False
            , getInstalledHaddock   = False
            }
        sourceMap
    directlyWanted <-
        forMaybeM (M.toList (envConfigPackages econfig)) $
        \(dir,validWanted) ->
             do cabalfp <- getCabalFileName dir
                name <- parsePackageNameFromFilePath cabalfp
                if validWanted
                    then case M.lookup name targets of
                             Just simpleTargets ->
                                 return (Just (name, (cabalfp, simpleTargets)))
                             Nothing -> return Nothing
                    else return Nothing
    let intermediateDeps = getIntermediateDeps sourceMap directlyWanted
    wanted <-
        if skipIntermediate || null intermediateDeps
            then return directlyWanted
            else do
                $logInfo $ T.concat
                    [ "The following libraries will also be loaded into GHCi because "
                    , "they are intermediate dependencies of your targets:\n    "
                    , T.intercalate ", " (map (packageNameText . fst) intermediateDeps)
                    , "\n(Use --skip-intermediate-deps to omit these)"
                    ]
                return (directlyWanted ++ intermediateDeps)
    -- Try to build, but optimistically launch GHCi anyway if it fails (#1065)
    unless noBuild $ do
        eres <- tryAny $ build (const (return ())) Nothing bopts
        case eres of
            Right () -> return ()
            Left err -> do
                $logError $ T.pack (show err)
                $logWarn "Warning: build failed, but optimistically launching GHCi anyway"
    -- Load the list of modules _after_ building, to catch changes in unlisted dependencies (#1180)
    let localLibs = [name | (name, (_, target)) <- wanted , hasLocalComp isCLib target]
    infos <-
        forM wanted $
        \(name,(cabalfp,target)) ->
             makeGhciPkgInfo bopts sourceMap installedMap localLibs name cabalfp target
    checkForIssues infos
    return (realTargets, mainIsTargets, infos)
  where
    hasLocalComp p t =
        case t of
            STLocalComps s -> any p (S.toList s)
            STLocalAll -> True
            _ -> False

-- | Make information necessary to load the given package in GHCi.
makeGhciPkgInfo
    :: (MonadReader r m, HasEnvConfig r, MonadLogger m, MonadIO m, MonadCatch m)
    => BuildOpts
    -> SourceMap
    -> InstalledMap
    -> [PackageName]
    -> PackageName
    -> Path Abs File
    -> SimpleTarget
    -> m GhciPkgInfo
makeGhciPkgInfo bopts sourceMap installedMap locals name cabalfp target = do
    econfig <- asks getEnvConfig
    bconfig <- asks getBuildConfig
    let config =
            PackageConfig
            { packageConfigEnableTests = True
            , packageConfigEnableBenchmarks = True
            , packageConfigFlags = localFlags (boptsFlags bopts) bconfig name
            , packageConfigCompilerVersion = envConfigCompilerVersion econfig
            , packageConfigPlatform = configPlatform (getConfig bconfig)
            }
    (warnings,pkg) <- readPackage config cabalfp
    mapM_ (printCabalFileWarning cabalfp) warnings
    (mods,files,opts) <- getPackageOpts (packageOpts pkg) sourceMap installedMap locals cabalfp
    let filteredOpts = filterWanted opts
        filterWanted = M.filterWithKey (\k _ -> k `S.member` allWanted)
        allWanted = wantedPackageComponents bopts target pkg
        setMapMaybe f = S.fromList . mapMaybe f . S.toList
    return
        GhciPkgInfo
        { ghciPkgName = packageName pkg
        , ghciPkgOpts = M.toList filteredOpts
        , ghciPkgDir = parent cabalfp
        , ghciPkgModules = mconcat (M.elems (filterWanted mods))
        , ghciPkgModFiles = mconcat (M.elems (filterWanted (M.map (setMapMaybe dotCabalModulePath) files)))
        , ghciPkgMainIs = M.map (setMapMaybe dotCabalMainPath) files
        , ghciPkgCFiles = mconcat (M.elems (filterWanted (M.map (setMapMaybe dotCabalCFilePath) files)))
        , ghciPkgPackage = pkg
        }

-- NOTE: this should make the same choices as the components code in
-- 'loadLocalPackage'. Unfortunately for now we reiterate this logic
-- (differently).
wantedPackageComponents :: BuildOpts -> SimpleTarget -> Package -> Set NamedComponent
wantedPackageComponents _ (STLocalComps cs) _ = cs
wantedPackageComponents bopts STLocalAll pkg = S.fromList $
    (if packageHasLibrary pkg then [CLib] else []) ++
    map CExe (S.toList (packageExes pkg)) <>
    (if boptsTests bopts then map CTest (M.keys (packageTests pkg)) else []) <>
    (if boptsBenchmarks bopts then map CBench (S.toList (packageBenchmarks pkg)) else [])
wantedPackageComponents _ _ _ = S.empty

checkForIssues :: (MonadThrow m, MonadLogger m) => [GhciPkgInfo] -> m ()
checkForIssues pkgs = do
    unless (null issues) $ borderedWarning $ do
        $logWarn "There are issues with this project which may prevent GHCi from working properly."
        $logWarn ""
        mapM_ $logWarn $ intercalate [""] issues
        $logWarn ""
        $logWarn "To resolve, remove the flag(s) from the cabal file(s) and instead put them at the top of the haskell files."
        $logWarn ""
        $logWarn "It isn't yet possible to load multiple packages into GHCi in all cases - see"
        $logWarn "https://ghc.haskell.org/trac/ghc/ticket/10827"
  where
    issues = concat
        [ mixedFlag "-XNoImplicitPrelude"
          [ "-XNoImplicitPrelude will be used, but GHCi will likely fail to build things which depend on the implicit prelude." ]
        , mixedFlag "-XCPP"
          [ "-XCPP will be used, but it can cause issues with multiline strings."
          , "See https://downloads.haskell.org/~ghc/7.10.2/docs/html/users_guide/options-phases.html#cpp-string-gaps"
          ]
        , mixedFlag "-XNoTraditionalRecordSyntax"
          [ "-XNoTraditionalRecordSyntax will be used, but it break modules which use record syntax." ]
        , mixedFlag "-XTemplateHaskell"
          [ "-XTemplateHaskell will be used, but it may cause compilation issues due to different parsing of '$' when there's no space after it." ]
        , mixedFlag "-XQuasiQuotes"
          [ "-XQuasiQuotes will be used, but it may cause parse failures due to a different meaning for list comprehension syntax like [x| ... ]" ]
        , mixedFlag "-XSafe"
          [ "-XSafe will be used, but it will fail to compile unsafe modules." ]
        , mixedFlag "-XArrows"
          [ "-XArrows will be used, but it will cause non-arrow usages of proc, (-<), (-<<) to fail" ]
        , mixedFlag "-XOverloadedStrings"
          [ "-XOverloadedStrings will be used, but it can cause type ambiguity in code not usually compiled with it." ]
        , mixedFlag "-XOverloadedLists"
          [ "-XOverloadedLists will be used, but it can cause type ambiguity in code not usually compiled with it." ]
        , mixedFlag "-XMonoLocalBinds"
          [ "-XMonoLocalBinds will be used, but it can cause type errors in code which expects generalized local bindings." ]
        , mixedFlag "-XTypeFamilies"
          [ "-XTypeFamilies will be used, but it implies -XMonoLocalBinds, and so can cause type errors in code which expects generalized local bindings." ]
        , mixedFlag "-XGADTs"
          [ "-XGADTs will be used, but it implies -XMonoLocalBinds, and so can cause type errors in code which expects generalized local bindings." ]
        , mixedFlag "-XNewQualifiedOperators"
          [ "-XNewQualifiedOperators will be used, but this will break usages of the old qualified operator syntax." ]
        ]
    mixedFlag flag msgs =
        let x = partitionComps (== flag) in
        [ msgs ++ showWhich x | mixedSettings x ]
    mixedSettings (xs, ys) = xs /= [] && ys /= []
    showWhich (haveIt, don'tHaveIt) =
        [ "It is specified for:"
        , "    " <> renderPkgComponents haveIt
        , "But not for: "
        , "    " <> renderPkgComponents don'tHaveIt
        ]
    partitionComps f = (map fst xs, map fst ys)
      where
        (xs, ys) = partition (any f . snd) compsWithOpts
    compsWithOpts = map (\(k, bio) -> (k, bioOneWordOpts bio ++ bioOpts bio)) compsWithBios
    compsWithBios =
        [ ((ghciPkgName pkg, c), bio)
        | pkg <- pkgs
        , (c, bio) <- ghciPkgOpts pkg
        ]

borderedWarning :: MonadLogger m => m a -> m a
borderedWarning f = do
    $logWarn ""
    $logWarn "* * * * * * * *"
    x <- f
    $logWarn "* * * * * * * *"
    $logWarn ""
    return x

-- Adds in intermediate dependencies between ghci targets. Note that it
-- will return a Lib component for these intermediate dependencies even
-- if they don't have a library (but that's fine for the usage within
-- this module).
getIntermediateDeps
    :: SourceMap
    -> [(PackageName, (Path Abs File, SimpleTarget))]
    -> [(PackageName, (Path Abs File, SimpleTarget))]
getIntermediateDeps sourceMap targets =
    M.toList $
    (\mp -> foldl' (flip M.delete) mp (map fst targets)) $
    M.mapMaybe id $
    execState (mapM_ (mapM_ go . getDeps . fst) targets)
              (M.fromList (map (\(k, x) -> (k, Just x)) targets))
  where
    getDeps :: PackageName -> [PackageName]
    getDeps name =
        case M.lookup name sourceMap of
            Just (PSLocal lp) -> M.keys (packageDeps (lpPackage lp))
            _ -> []
    go :: PackageName -> State (Map PackageName (Maybe (Path Abs File, SimpleTarget))) Bool
    go name = do
        cache <- get
        case (M.lookup name cache, M.lookup name sourceMap) of
            (Just (Just _), _) -> return True
            (Just Nothing, _) -> return False
            (_, Just (PSLocal lp)) -> do
                let deps = M.keys (packageDeps (lpPackage lp))
                isIntermediate <- liftM or $ mapM go deps
                if isIntermediate
                    then do
                        modify (M.insert name (Just (lpCabalFile lp, STLocalComps (S.singleton CLib))))
                        return True
                    else do
                        modify (M.insert name Nothing)
                        return False
            (_, Just PSUpstream{}) -> return False
            (Nothing, Nothing) -> return False

preprocessCabalMacros :: MonadIO m => [GhciPkgInfo] -> Path Abs File -> m [String]
preprocessCabalMacros pkgs out = liftIO $ do
    let fps = nubOrd (concatMap (mapMaybe (bioCabalMacros . snd) . ghciPkgOpts) pkgs)
    files <- mapM (S8.readFile . toFilePath) fps
    if null files then return [] else do
        S8.writeFile (toFilePath out) $ S8.intercalate "\n#undef CURRENT_PACKAGE_KEY\n" files
        return ["-optP-include", "-optP" <> toFilePath out]
