module Main(main) where

import Control.Exception
import Control.Monad.Identity
import Data.Char
import Prelude
import System.Directory
import System.FilePath as FP
import System.IO
import qualified Data.ByteString.Lazy as LBS

import DataConstructors
import E.Main
import E.Program
import E.Rules
import E.Type
import FrontEnd.Class
import Grin.Main(compileToGrin)
import Grin.Show(render)
import Ho.Build
import Ho.Collected
import Ho.Library
import Name.Name
import Options
import StringTable.Atom
import Support.TempDir
import Util.Gen
import Util.SetLike as S
import Version.Version(versionSimple)
import qualified FlagDump as FD
import qualified Interactive

main = wrapMain $ do
    hSetEncoding stdout utf8
    hSetEncoding stderr utf8
    o <- processOptions
    when (dump FD.Atom) $
        addAtExit dumpStringTableStats
    -- set temporary directory
    maybeDo $ do x <- optWorkDir o; return $ setTempDir x
    let darg = progressM $ do
        (argstring,_) <- getArgString
        return (argstring ++ "\n" ++ versionSimple)
    case optMode o of
        BuildHl hl    -> darg >> buildLibrary processInitialHo processDecls hl
        ListLibraries -> listLibraries
        ShowHo ho     -> dumpHoFile ho
        PurgeCache    -> purgeCache
        Preprocess    -> forM_ (optArgs o) $ \fn -> do
            lbs <- LBS.readFile fn
            res <- preprocessHs options fn lbs
            LBS.putStr res
        _               -> darg >> processFiles (optArgs o)

-- we are very careful to only delete cache files.
purgeCache = do
    Just hc <- findHoCache
    ds <- getDirectoryContents hc
    let cacheFile fn = case map toLower (reverse fn) of
            'o':'h':'.':fs -> length fs == 26 && all isAlphaNum fs
            _ -> False
    forM_ ds $ \fn -> when (cacheFile fn) (removeFile (hc </> fn))

processFiles :: [String] -> IO ()
processFiles cs = f cs (optMainFunc options) where
    f [] Nothing  = do
        int <- Interactive.isInteractive
        when (not int) $ putErrDie "jhc: no input files"
        g [Left preludeModule]
    f [] (Just (b,m)) = do
        m <- getModule (parseName Val m)
        g [Left m]
    f cs _ = g (map fileOrModule cs)
    g fs = processCollectedHo . snd =<< parseFiles options [outputName] []
	    fs processInitialHo processDecls
    fileOrModule f = case reverse f of
        ('s':'h':'.':_)     -> Right f
        ('s':'h':'l':'.':_) -> Right f
        ('c':'s':'h':'.':_) -> Right f
        _                   -> Left $ toModule f

processCollectedHo cho = do
    if optStop options == CompileHo then return () else do
    putProgressLn "Collected Compilation..."

    when (dump FD.ClassSummary) $ do
        putStrLn "  ---- class summary ---- "
        printClassSummary (choClassHierarchy cho)
    when (dump FD.Class) $ do
        putStrLn "  ---- class hierarchy ---- "
        printClassHierarchy (choClassHierarchy cho)

    let dataTable = choDataTable cho
        combinators = values $ choCombinators cho

    evaluate dataTable
    evaluate combinators

    let prog = programUpdate program {
            progCombinators = combinators,
            progDataTable = dataTable
            }
    -- dump final version of various requested things
    wdump FD.Datatable $ putErrLn (render $ showDataTable dataTable)
    wdump FD.DatatableBuiltin $
	putErrLn (render $ showDataTable samplePrimitiveDataTable)
    dumpRules (Rules $ fromList
	[(combIdent x,combRules x) | x <- combinators, not $ null (combRules x)])

    -- enter interactive mode
    int <- Interactive.isInteractive
    if int then Interactive.interact cho else do
        prog <- compileWholeProgram prog
        compileToGrin prog

progressM c  = wdump FD.Progress $ (c >>= putErrLn) >> hFlush stderr
