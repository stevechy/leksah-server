{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Utils.FileUtils
-- Copyright   :  2007-2011 Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GPL
--
-- Maintainer  :  maintainer@leksah.org
-- Stability   :  provisional
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

module IDE.Utils.FileUtils (
    allModules
,   allHiFiles
,   allHaskellSourceFiles
,   isEmptyDirectory
,   cabalFileName
,   allCabalFiles
,   getConfigFilePathForLoad
,   hasSavedConfigFile
,   getConfigDir
,   getConfigFilePathForSave
,   getCollectorPath
,   getSysLibDir
,   moduleNameFromFilePath
,   moduleNameFromFilePath'
,   findKnownPackages
,   isSubPath
,   findSourceFile
,   findSourceFile'
,   haskellSrcExts
,   getCabalUserPackageDir
,   autoExtractCabalTarFiles
,   autoExtractTarFiles
,   getInstalledPackageIds
,   getSourcePackageIds
,   figureOutGhcOpts
,   figureOutHaddockOpts
,   allFilesWithExtensions
,   myCanonicalizePath
) where

import Prelude hiding (readFile)
import System.FilePath
       (splitFileName, dropExtension, takeExtension,
        combine, addExtension, (</>), normalise, splitPath, takeFileName)
import Distribution.ModuleName (toFilePath, ModuleName)
import Control.Monad (foldM, filterM)
import Data.Maybe (catMaybes)
import Distribution.Simple.PreProcess.Unlit (unlit)
import System.Directory
       (canonicalizePath, doesDirectoryExist, doesFileExist,
        setCurrentDirectory, getCurrentDirectory, getDirectoryContents,
        createDirectory, getHomeDirectory)
import Text.ParserCombinators.Parsec.Language (haskellDef, haskell)
#if MIN_VERSION_parsec(3,0,0)
import qualified Text.ParserCombinators.Parsec.Token as P
       (GenTokenParser(..), TokenParser, identStart)
#else
import qualified Text.ParserCombinators.Parsec.Token as P
       (TokenParser(..), identStart)
#endif
import Text.ParserCombinators.Parsec
       (GenParser, parse, oneOf, (<|>), alphaNum, noneOf, char, try,
        (<?>), many, CharParser)
import Data.Set (Set)
import Data.List
    (isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Set as  Set (empty, fromList)
import Distribution.Package (PackageIdentifier)
import Data.Char (ord)
import Distribution.Text (simpleParse)

import IDE.Utils.Utils
import IDE.Core.CTypes(configDirName)
import qualified Distribution.Text as  T (simpleParse)
import System.Log.Logger(errorM,warningM,debugM)
import IDE.Utils.Tool
import Control.Monad.IO.Class (MonadIO(..), MonadIO)
import Control.Exception as E (SomeException, catch)
import System.IO.Strict (readFile)
import qualified Data.Text as T
       (pack, map, stripPrefix, isSuffixOf, take, length, unpack, init,
        last, words)
import Data.Monoid ((<>))
import Control.Applicative ((<$>))
import Data.Text (Text)

haskellSrcExts :: [FilePath]
haskellSrcExts = ["hs","lhs","chs","hs.pp","lhs.pp","chs.pp","hsc"]

-- | canonicalizePath without crashing
myCanonicalizePath :: FilePath -> IO FilePath
myCanonicalizePath fp = do
    exists <- doesFileExist fp
    if exists
        then canonicalizePath fp
        else return fp


-- | Returns True if the second path is a location which starts with the first path
isSubPath :: FilePath -> FilePath -> Bool
isSubPath fp1 fp2 =
    let fpn1    =   splitPath $ normalise fp1
        fpn2    =   splitPath $ normalise fp2
        res     =   isPrefixOf fpn1 fpn2
    in res

findSourceFile :: [FilePath]
    -> [FilePath]
    -> ModuleName
    -> IO (Maybe FilePath)
findSourceFile directories exts modId  =
    let modulePath      =   toFilePath modId
        allPathes       =   map (\ d -> d </> modulePath) directories
        allPossibles    =   concatMap (\ p -> map (addExtension p) exts)
                                allPathes
    in  find' allPossibles

findSourceFile' :: [FilePath]
    -> FilePath
    -> IO (Maybe FilePath)
findSourceFile' directories modulePath  =
    let allPathes       =   map (\ d -> d </> modulePath) directories
    in  find' allPathes


find' :: [FilePath] -> IO (Maybe FilePath)
find' []            =   return Nothing
find' (h:t)         =   E.catch (do
    exists <- doesFileExist h
    if exists
        then return (Just h)
        else find' t)
        $ \ (_ :: SomeException) -> return Nothing

-- | The directory where config files reside
--
getConfigDir :: IO FilePath
getConfigDir = do
    d <- getHomeDirectory
    let filePath = d </> configDirName
    exists <- doesDirectoryExist filePath
    if exists
        then return filePath
        else do
            createDirectory filePath
            return filePath

getConfigDirForLoad :: IO (Maybe FilePath)
getConfigDirForLoad = do
    d <- getHomeDirectory
    let filePath = d </> configDirName
    exists <- doesDirectoryExist filePath
    if exists
        then return (Just filePath)
        else return Nothing

hasSavedConfigFile :: FilePath -> IO Bool
hasSavedConfigFile fn = do
    savedConfigFile <- getConfigFilePathForSave fn
    doesFileExist savedConfigFile


getConfigFilePathForLoad :: FilePath -> Maybe FilePath -> FilePath -> IO FilePath
getConfigFilePathForLoad fn mbFilePath dataDir = do
    mbCd <- case mbFilePath of
                Just p -> return (Just p)
                Nothing -> getConfigDirForLoad
    case mbCd of
        Nothing -> getFromData
        Just cd -> do
            ex <- doesFileExist (cd </> fn)
            if ex
                then return (cd </> fn)
                else getFromData
    where getFromData = do
            ex <- doesFileExist (dataDir </> "data" </> fn)
            if ex
                then return (dataDir </> "data" </> fn)
                else error $"Config file not found: " ++ fn

getConfigFilePathForSave :: FilePath -> IO FilePath
getConfigFilePathForSave fn = do
    cd <- getConfigDir
    return (cd </> fn)

allModules :: FilePath -> IO [ModuleName]
allModules filePath = E.catch (do
    exists <- doesDirectoryExist filePath
    if exists
        then do
            filesAndDirs <- getDirectoryContents filePath
            let filesAndDirs' = map (\s -> combine filePath s)
                                    $filter (\s -> s /= "." && s /= ".." && s /= "_darcs" && s /= "dist"
                                        && s /= "Setup.lhs") filesAndDirs
            dirs <-  filterM (\f -> doesDirectoryExist f) filesAndDirs'
            files <-  filterM (\f -> doesFileExist f) filesAndDirs'
            let hsFiles =   filter (\f -> let ext = takeExtension f in
                                            ext == ".hs" || ext == ".lhs") files
            mbModuleStrs <- mapM moduleNameFromFilePath hsFiles
            let mbModuleNames = catMaybes $
                                    map (\n -> case n of
                                                    Nothing -> Nothing
                                                    Just s -> simpleParse $ T.unpack s)
                                        mbModuleStrs
            otherModules <- mapM allModules dirs
            return (mbModuleNames ++ concat otherModules)
        else return [])
            $ \ (_ :: SomeException) -> return []

allHiFiles :: FilePath -> IO [FilePath]
allHiFiles = allFilesWithExtensions [".hi"] True []

allCabalFiles :: FilePath -> IO [FilePath]
allCabalFiles = allFilesWithExtensions [".cabal"] False []

allHaskellSourceFiles :: FilePath -> IO [FilePath]
allHaskellSourceFiles = allFilesWithExtensions [".hs",".lhs"] True []

allFilesWithExtensions :: [FilePath] -> Bool -> [FilePath] -> FilePath -> IO [FilePath]
allFilesWithExtensions extensions recurseFurther collecting filePath = E.catch (do
    exists <- doesDirectoryExist filePath
    if exists
        then do
            filesAndDirs <- getDirectoryContents filePath
            let filesAndDirs' = map (\s -> combine filePath s)
                                    $filter (\s -> s /= "." && s /= ".." && s /= "_darcs") filesAndDirs
            dirs    <-  filterM (\f -> doesDirectoryExist f) filesAndDirs'
            files   <-  filterM (\f -> doesFileExist f) filesAndDirs'
            let choosenFiles =   filter (\f -> let ext = takeExtension f in
                                                    elem ext extensions) files
            allFiles <-
                if recurseFurther || (not recurseFurther && null choosenFiles)
                    then foldM (allFilesWithExtensions extensions recurseFurther) (choosenFiles ++ collecting) dirs
                    else return (choosenFiles ++ collecting)
            return (allFiles)
        else return collecting)
            $ \ (_ :: SomeException) -> return collecting


moduleNameFromFilePath :: FilePath -> IO (Maybe Text)
moduleNameFromFilePath fp = E.catch (do
    exists <- doesFileExist fp
    if exists
        then do
            str <-  readFile fp
            moduleNameFromFilePath' fp str
        else return Nothing)
            $ \ (_ :: SomeException) -> return Nothing

moduleNameFromFilePath' :: FilePath -> FilePath -> IO (Maybe Text)
moduleNameFromFilePath' fp str = do
    let unlitRes = if takeExtension fp == ".lhs"
                    then unlit fp str
                    else Left str
    case unlitRes of
        Right err -> do
            errorM "leksah-server" (show err)
            return Nothing
        Left str' -> do
            let parseRes = parse moduleNameParser fp str'
            case parseRes of
                Left _ -> do
                    return Nothing
                Right str'' -> return (Just str'')

lexer :: P.TokenParser st
lexer = haskell

lexeme :: CharParser st a -> CharParser st a
lexeme = P.lexeme lexer

whiteSpace :: CharParser st ()
whiteSpace = P.whiteSpace lexer

symbol :: Text -> CharParser st Text
symbol = (T.pack <$>) . P.symbol lexer . T.unpack

moduleNameParser :: CharParser () Text
moduleNameParser = do
    whiteSpace
    many skipPreproc
    whiteSpace
    symbol "module"
    str <- lexeme mident
    return str
    <?> "module identifier"

skipPreproc :: CharParser () ()
skipPreproc = do
    try (do
        whiteSpace
        char '#'
        many (noneOf "\n")
        return ())
    <?> "preproc"

mident :: GenParser Char st Text
mident
        = do{ c <- P.identStart haskellDef
            ; cs <- many (alphaNum <|> oneOf "_'.")
            ; return (T.pack (c:cs))
            }
        <?> "midentifier"

findKnownPackages :: FilePath -> IO (Set Text)
findKnownPackages filePath = E.catch (do
    paths           <-  getDirectoryContents filePath
    let nameList    =   map (T.pack . dropExtension) $
            filter (\s -> leksahMetadataSystemFileExtension `isSuffixOf` s) paths
    return (Set.fromList nameList))
        $ \ (_ :: SomeException) -> return (Set.empty)

isEmptyDirectory :: FilePath -> IO Bool
isEmptyDirectory filePath = E.catch (do
    exists <- doesDirectoryExist filePath
    if exists
        then do
            filesAndDirs <- getDirectoryContents filePath
            return . null $ filter (not . ("." `isPrefixOf`) . takeFileName) filesAndDirs
        else return False)
        (\ (_ :: SomeException) -> return False)

cabalFileName :: FilePath -> IO (Maybe FilePath)
cabalFileName filePath = E.catch (do
    exists <- doesDirectoryExist filePath
    if exists
        then do
            filesAndDirs <- map (filePath </>) <$> getDirectoryContents filePath
            files <-  filterM (\f -> doesFileExist f) filesAndDirs
            case filter (\f -> let ext = takeExtension f in ext == ".cabal") files of
                [f] -> return (Just f)
                []  -> return Nothing
                _   -> do
                    warningM "leksah-server" "Multiple cabal files"
                    return Nothing
        else return Nothing)
        (\ (_ :: SomeException) -> return Nothing)

getCabalUserPackageDir :: IO (Maybe FilePath)
getCabalUserPackageDir = do
    (!output,_) <- runTool' "cabal" ["help"] Nothing
    case T.stripPrefix "  " (toolline $ last output) of
        Just s | "config" `T.isSuffixOf` s -> return . Just . T.unpack $ T.take (T.length s - 6) s <> "packages"
        _ -> return Nothing

autoExtractCabalTarFiles :: FilePath -> IO ()
autoExtractCabalTarFiles filePath = do
    dir <- getCurrentDirectory
    autoExtractTarFiles' filePath
    setCurrentDirectory dir

autoExtractTarFiles :: FilePath -> IO ()
autoExtractTarFiles filePath = do
    dir <- getCurrentDirectory
    autoExtractTarFiles' filePath
    setCurrentDirectory dir

autoExtractTarFiles' :: FilePath -> IO ()
autoExtractTarFiles' filePath =
    E.catch (do
        exists <- doesDirectoryExist filePath
        if exists
            then do
                filesAndDirs             <- getDirectoryContents filePath
                let filesAndDirs'        =  map (\s -> combine filePath s)
                                                $ filter (\s -> s /= "." && s /= ".." && not (isPrefixOf "00-index" s)) filesAndDirs
                dirs                     <- filterM (\f -> doesDirectoryExist f) filesAndDirs'
                files                    <- filterM (\f -> doesFileExist f) filesAndDirs'
                let choosenFiles         =  filter (\f -> isSuffixOf ".tar.gz" f) files
                let decompressionTargets =  filter (\f -> (dropExtension . dropExtension) f `notElem` dirs) choosenFiles
                mapM_ (\f -> let (dir,fn) = splitFileName f
                                 command = "tar -zxf " ++ fn in do
                                    setCurrentDirectory dir
                                    handle   <- runCommand command
                                    waitForProcess handle
                                    return ())
                        decompressionTargets
                mapM_ autoExtractTarFiles' dirs
                return ()
            else return ()
    ) $ \ (_ :: SomeException) -> return ()


getCollectorPath :: MonadIO m => m FilePath
getCollectorPath = liftIO $ do
    configDir <- getConfigDir
    let filePath = configDir </> "metadata"
    exists    <- doesDirectoryExist filePath
    if exists
        then return filePath
        else do
            createDirectory filePath
            return filePath

getSysLibDir :: IO FilePath
getSysLibDir = E.catch (do
    (!output,_) <- runTool' "ghc" ["--print-libdir"] Nothing
    let libDir = toolline $ head output
        libDir2 = if ord (T.last libDir) == 13
                    then T.init libDir
                    else libDir
    return . normalise $ T.unpack libDir2
    ) $ \ (_ :: SomeException) -> error ("FileUtils>>getSysLibDir failed")

getInstalledPackageIds :: IO [PackageIdentifier]
getInstalledPackageIds = E.catch (do
    (!output, _) <- runTool' "ghc-pkg" ["list", "--simple-output"] Nothing
    return $ concatMap names output
    ) $ \ (_ :: SomeException) -> error ("FileUtils>>getInstalledPackageIds failed")
  where
    names (ToolOutput n) = catMaybes (map (T.simpleParse . T.unpack) (T.words n))
    names _ = []

getSourcePackageIds :: IO [PackageIdentifier]
getSourcePackageIds = E.catch (do
    (!output, _) <- runTool' "ghc-pkg" ["list", "--simple-output"] Nothing
    return . catMaybes $ map names output
    ) $ \ (_ :: SomeException) -> error ("FileUtils>>getInstalledPackageIds failed")
  where
    names (ToolOutput n) = T.simpleParse . T.unpack $ T.map replaceSpace n
    names _ = Nothing
    replaceSpace ' ' = '-'
    replaceSpace c = c

figureOutHaddockOpts :: IO [Text]
figureOutHaddockOpts = do
    (!output,_) <- runTool' "cabal" (["haddock","--with-haddock=leksahecho","--executables"]) Nothing
    let opts = concatMap (words . T.unpack . toolline) output
    let res = filterOptGhc opts
    debugM "leksah-server" ("figureOutHaddockOpts " ++ show res)
    return $ map T.pack res
    where
        filterOptGhc []    = []
        filterOptGhc (s:r) = case stripPrefix "--optghc=" s of
                                    Nothing -> filterOptGhc r
                                    Just s'  -> s' : filterOptGhc r

figureOutGhcOpts :: IO [Text]
figureOutGhcOpts = do
    debugM "leksah-server" "figureOutGhcOpts"
    (!output,_) <- runTool' "cabal" ["build","--with-ghc=leksahecho"] Nothing
    let res = case catMaybes $ map (findMake . T.unpack . toolline) output of
                options:_ -> words options
                _         -> []
    debugM "leksah-server" $ ("figureOutGhcOpts " ++ show res)
    return $ map T.pack res
    where
        findMake [] = Nothing
        findMake line@(_:xs) =
                case stripPrefix "--make " line of
                    Nothing -> findMake xs
                    s -> s
