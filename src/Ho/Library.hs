module Ho.Library(
    LibDesc(..),
    collectLibraries,
    libModMap,
    libHash,
    libMgHash,
    libProvides,
    libName,
    libBaseName,
    libHoLib,
    preprocess,
    listLibraries
    ) where

import Util.Std
import Data.Version
import System.Directory
import Text.Printf
import qualified Data.Map as Map
import qualified Data.Set as Set

import Ho.Binary
import Ho.ReadSource
import Ho.Type
import Name.Name(Module)
import Options
import PackedString(PackedString,packString,unpackPS)
import Util.Gen
import Util.YAML
import qualified Support.MD5 as MD5

libModMap = hoModuleMap . libHoLib
libHash  = hohHash . libHoHeader
libMgHash mg lib = MD5.md5String $ show (libHash lib,mg)
libProvides mg lib = [ m | (m,mg') <- Map.toList (libModMap lib), mg == mg']
libName lib = let HoHeader { hohName = ~(Right (name,vers)) } = libHoHeader lib in unpackPS name ++ "-" ++ showVersion vers
libVersion lib = let HoHeader { hohName = ~(Right (_name,vers)) } = libHoHeader lib in vers
libBaseName lib = let HoHeader { hohName = ~(Right (name,_vers)) } = libHoHeader lib in name
libModules l = let lib = libHoLib l in ([ m | (m,_) <- Map.toList (hoModuleMap lib)],Map.toList (hoReexports lib))

libVersionCompare l1 l2 = compare (libVersion l1) (libVersion l2)

--------------------------------
-- finding and listing libraries
--------------------------------

instance ToNode Module where
    toNode m = toNode $ show m
instance ToNode HoHash where
    toNode m = toNode $ show m
instance ToNode PackedString where
    toNode m = toNode $ unpackPS m

listLibraries :: IO ()
listLibraries = do
    (_,byhashes) <- fetchAllLibraries
    let libs = Map.toList byhashes
    if not verbose then putStr $ showYAML (sort $ map (libName . snd) libs) else do
    let f (h,l) = (show h,[
            ("Name",toNode (libName l)),
            ("BaseName",toNode (libBaseName l)),
            ("Version",toNode (showVersion $ libVersion l)),
            ("FilePath",toNode (libFileName l)),
            ("LibDeps",toNode [ h | (_,h) <- hohLibDeps (libHoHeader l)]),
            ("Exported-Modules",toNode $ mod ++ fsts rmod)
            ]) where
          (mod,rmod) = libModules l
    putStr $ showYAML (map f libs)

-- Collect all libraries and return those which are explicitly and implicitly imported.
--
-- The basic process is:
--    - Find all libraries and create two indexes, a map of named libraries to
--      the newest version of them, and a map of library hashes to the libraries
--      themselves.
--
--    - For all the libraries listed on the command line, find the newest
--      version of each of them, flag these as the explicitly imported libraries.
--
--    - recursively find the dependencies by the hash's listed in the library deps. if the names
--      match a library already loaded, ensure the hash matches up. flag these libraries as 'implicit' unless
--      already flaged 'explicit'
--
--    - perform sanity checks on final lists of implicit and explicit libraries.
--
-- Library Checks needed:
--    - We have found versions of all libraries listed on the command line
--    - We have all dependencies of all libraries and the hash matches the proper library name
--    - no libraries directly export the same modules, (but re-exporting the same module is fine)
--    - conflicting versions of any particular library are not required due to dependencies

fetchAllLibraries :: IO (Map.Map PackedString [Library],Map.Map HoHash Library)
fetchAllLibraries = ans where
    ans = do
        (bynames',byhashes') <- unzip `fmap` concatMapM f (optHlPath options)
        let bynames = Map.map (reverse . sortBy libVersionCompare) $ Map.unionsWith (++) bynames'
            byhashes = Map.unions byhashes'
        return (bynames,byhashes)
    f fp = do
        fs <- flip iocatch (\_ -> return [] ) $ getDirectoryContents fp
        forM fs $ \e -> case reverse e of
            ('l':'h':'.':r)  -> flip iocatch (\_ -> return mempty) $ do
                lib <- readHlFile  (fp ++ "/" ++ e)
                return (Map.singleton (libBaseName lib) [lib], Map.singleton (libHash lib) lib)
            _               -> return mempty

splitOn' :: (a -> Bool) -> [a] -> [[a]]
splitOn' f xs = split xs
  where split xs = case break f xs of
          (chunk,[])     -> [chunk]
          (chunk,_:rest) -> chunk : split rest

splitVersion :: String -> (String,Data.Version.Version)
splitVersion s = ans where
    ans = case reverse (splitOn' ('-' ==) s) of
        (vrs:bs@(_:_)) | Just vrs <- runReadP parseVersion vrs -> (intercalate "-" (reverse bs),vrs)
        _ -> (s,Data.Version.Version [] [])

-- returns (explicitly imported libraries, implicitly imported libraries, full library map)
collectLibraries :: [String] -> IO ([Library],[Library],Map.Map PackedString [Library])
collectLibraries libs = ans where
    ans = do
        (bynames,byhashes) <- fetchAllLibraries
        let f (pn,vrs) = lname pn vrs `mplus` lhash pn vrs where
                lname pn vrs = do
                    xs <- Map.lookup (packString pn) bynames
                    (x:_) <- return $ filter isGood xs
                    return x
                isGood lib = versionBranch vrs `isPrefixOf` versionBranch (libVersion lib)
                lhash pn vrs = do
                    [] <- return $ versionBranch vrs
                    Map.lookup pn byhashes'
            byhashes' = Map.fromList [ (show x,y) | (x,y) <- Map.toList byhashes]
        let es' = [ (x,f $ splitVersion x) | x <- libs ]
            es = [ l | (_,Just l) <- es' ]
            bad = [ n | (n,Nothing) <- es' ]
        unless (null bad) $ do
            putErrLn "Libraries not found:"
            forM_ bad $ \b -> putErrLn ("    " ++ b)
            exitFailure
        checkForModuleConficts es

        let f lmap _ [] = return lmap
            f lmap lset ((ei,l):ls)
                | libHash l `Set.member` lset = f lmap lset ls
                | otherwise = case Map.lookup (libBaseName l) lmap of
                    Nothing -> f (Map.insert (libBaseName l) (ei,l) lmap) (Set.insert (libHash l) lset) (ls ++ newdeps)
                    Just (ei',l') | libHash l == libHash l' -> f  (Map.insert (libBaseName l) (ei || ei',l) lmap) lset ls
                    Just (_,l')  -> putErrDie $ printf  "Conflicting versions of library '%s' are required. [%s]\n" (libName l) (show (libHash l,libHash l'))
              where newdeps = [ (False,fromMaybe (error $ printf "Dependency '%s' with hash '%s' needed by '%s' was not found" (unpackPS p) (show h) (libName l)) (Map.lookup h byhashes)) | let HoHeader { hohLibDeps = ldeps } = libHoHeader l , (p,h) <- ldeps ]
        finalmap <- f Map.empty Set.empty [ (True,l) | l <- es ]
        checkForModuleConficts [ l | (_,l) <- Map.elems finalmap ]
        when verbose $ forM_ (Map.toList finalmap) $ \ (n,(e,l)) ->
            printf "-- Base: %s Exported: %s Hash: %s Name: %s\n" (unpackPS n) (show e) (show $ libHash l) (libName l)

        return ([ l | (True,l) <- Map.elems finalmap ],[ l | (False,l) <- Map.elems finalmap ],bynames)

    checkForModuleConficts ms = do
        let mbad = Map.toList $ Map.filter (\c -> case c of [_] -> False; _ -> True)  $ Map.fromListWith (++) [ (m,[l]) | l <- ms, m <- fst $ libModules l]
        forM_ mbad $ \ (m,l) -> putErrLn $ printf "Module '%s' is exported by multiple libraries: %s" (show m) (show $ map libName l)
        unless (null mbad) $ putErrDie "There were conflicting modules!"
