module FrontEnd.Lex.Parse(parse,parseStmt) where

import Util.Std

import FrontEnd.HsSyn
import FrontEnd.Lex.Layout
import FrontEnd.Lex.Lexer
import FrontEnd.Lex.ParseMonad
import FrontEnd.Warning
import Options
import PackedString
import qualified FlagDump as FD
import qualified FrontEnd.Lex.Parser as P

parse :: Opt -> FilePath -> String -> IO HsModule
parse opt fp s = case scanner opt s of
    Left s -> fail s
    Right s -> do
        wdump FD.Tokens $ do
            putStrLn "-- scanned"
            putStrLn $ unwords [ s | L _ _ s <- s ]
        s <- doLayout opt fp s
        wdump FD.Tokens $ do
            putStrLn "-- after layout"
            putStrLn $ unwords [ s | L _ _ s <- s ]
            putStrLn $ unwords [ show t ++ ":" ++s | L _ t s <- s ]
        case runP (withSrcLoc bogusASrcLoc { srcLocFileName = packString fp } $ P.parseModule s) opt of
            (ws, ~(Just p)) -> do
                processErrors ws
                return p { hsModuleOpt = opt }

parseStmt :: (Applicative m,MonadWarn m) => Opt -> FilePath -> String -> m HsStmt
parseStmt opt fp s = case scanner opt s of
    Left s -> fail s
    Right s -> do
        s <- doLayout opt fp s
        case runP (withSrcLoc bogusASrcLoc { srcLocFileName = packString fp } $ P.parseStmt s) opt of
            (ws, ~(Just p)) -> do
                mapM_ addWarning ws
                return p