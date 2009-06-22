{-# OPTIONS_GHC -fglasgow-exts #-}
module Support.IniParse(parseIniFiles) where


import Control.Monad.State
import GenUtil
import Data.Char
import Data.List
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Foldable as Seq
import Control.Monad

-- quick and dirty parser.

type St = (Int,FilePath,String)

newtype P a = P (State St a)
    deriving(Monad,MonadState St)


third (_,_,x) = x

look :: P String
look = gets third


discard :: Int -> P ()
discard n = do
    (fl,fp,s) <- get
    let (x,y) = splitAt n s
    put (fl + length (filter (== '\n') x),fp, y)

abort :: String -> P a
abort msg = do
    (l,fp,_)  <- get
    fail $ fp ++ ":" ++ show l ++ ": " ++ msg


dropSpace = do
    x <- look
    case x of
        ';':_ -> pdropWhile ('\n' /=) >> dropSpace
        c:_ | isSpace c -> pdropWhile isSpace >> dropSpace
        _ -> return ()

pdropWhile f  = do
    x <- look
    case x of
        c:_ | f c -> discard 1 >> pdropWhile f
        _ -> return ()

ptakeWhile f  = do
    x <- look
    let ts = takeWhile f x
    discard (length ts)
    return ts



pThings ch rs zs  = ans where
    ans = look >>= \x -> case x of
        '[':_ -> do
            hv <- pHeader
            dropSpace
            pThings hv Seq.empty (zs Seq.|> (ch,rs))
        _:_ -> do
            v <- pValue
            dropSpace
            pThings ch (rs Seq.|> v) zs
        [] -> return (zs Seq.|> (ch,rs))

trim = rbdropWhile isSpace

expect w = do
    cs <- look
    if w `isPrefixOf` cs then discard (length w) else abort ("expected " ++ show w)


pValue = do
    n <- ptakeWhile (`notElem` ['\n','='])
    expect "="
    rs <- ptakeWhile (/= '\n')
    return (trim n, trim rs)

pHeader = do
    expect "["
    n <- ptakeWhile (`notElem` "]\n")
    expect "]"
    return (trim n)



-- We use laziness cleverly to avoid repeating work
processIni :: Seq.Seq (String,Seq.Seq (String,String)) -> Map.Map String (Map.Map String String)
processIni iniRaw = ans where
    iniMap,iniMap' :: Map.Map String (Seq.Seq (String,String))
    iniMap = Map.fromListWith (flip (Seq.><)) (Seq.toList iniRaw)
    iniMap' = Map.map expandChains iniMap
    expandChains x = join (fmap ecp x)
    ecp :: (String,String) -> Seq.Seq (String,String)
    ecp ("merge",v) = Map.findWithDefault Seq.empty v iniMap'
    ecp x = Seq.singleton x
    ans = Map.map (\c -> Seq.foldl res Map.empty c) iniMap'
    res mp (k,v) | Just r <- getPrefix "+" (reverse k) = Map.insertWith f (reverse $ dropWhile isSpace r) v mp where
        f y x = x ++ " " ++ y
    res mp (k,v) = Map.insert k v mp

    

parseIniFile :: FilePath -> IO (Seq.Seq (String,Seq.Seq (String,String)))
parseIniFile fp = do
    let P act = dropSpace >> pThings "default" Seq.empty Seq.empty
    c <- readFile fp
    return $ evalState act (0,fp,c)


parseIniFiles 
    :: Bool          -- ^ whether verbose is enabled
    -> [FilePath]    -- ^ the files (in order) we attempt to parse
    -> [String]      -- ^ the m-flags 
    -> IO (Map.Map String String)
parseIniFiles verbose fs ss = do
    let rf fn = catch (do c <- parseIniFile fn; pverb ("reading " ++ fn); return c) (\_ -> return Seq.empty) 
        pverb s = if verbose then putErrLn s else return ()
    fsc <- mapM rf fs
    let pini = processIni (foldr (Seq.><) Seq.empty fsc)
        f (x:xs) cm = case span (/= '=') x of
            (be,'=':re) -> f xs (Map.insert be re cm)
            (be,[]) -> f xs (Map.findWithDefault Map.empty be pini `Map.union` cm)
        f [] cm = cm
    return (f ss Map.empty)
        




--main = do
--    as <- getArgs
--    is <- mapM parseIniFile as
--    let pi = processIni (foldr (Seq.><) Seq.empty is)
--
--    print "proc"
--    let f (h,rs) = do
--            putStrLn h
--            mapM_ (\x -> putStr "    " >>  print x) (Map.toList rs)
--    mapM_ f (Map.toList pi)






