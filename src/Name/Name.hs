{-# LANGUAGE OverloadedStrings #-}
module Name.Name(
    Module(..),
    Name,
    Class,
    NameType(..),
    ToName(..),
    ffiExportName,
    fromModule,
    fromTypishHsName,
    fromValishHsName,
    getIdent,
    getModule,
    isConstructorLike,
    isTypeNamespace,
    isValNamespace,
    mainModule,
    preludeModule,
    mapName,
    mapName',
    nameName,
    nameParts,
    nameType,
    parseName,
    primModule,
    qualifyName,
    setModule,
    quoteName,
    fromQuotedName,
    toModule,
    toUnqualified
    ) where

import Data.Char
import Data.Data

import C.FFI
import Data.Binary
import Doc.DocLike
import Doc.PPrint
import GenUtil
import StringTable.Atom

-------------
-- Name types
-------------

data NameType
    = TypeConstructor
    | DataConstructor
    | ClassName
    | TypeVal
    | Val
    | SortName
    | FieldLabel
    | RawType
    | UnknownType
    | QuotedName
    deriving(Ord,Eq,Enum,Read,Show)

isTypeNamespace TypeConstructor = True
isTypeNamespace ClassName = True
isTypeNamespace TypeVal = True
isTypeNamespace _ = False

isValNamespace DataConstructor = True
isValNamespace Val = True
isValNamespace _ = False

-----------------
-- name definiton
-----------------

newtype Name = Name Atom
    deriving(Ord,Eq,Typeable,Binary,Data,ToAtom,FromAtom)

isConstructorLike n =  isUpper x || x `elem` ":("  || xs == "->" || xs == "[]" where
    (_,_,xs@(x:_)) = nameParts n

fromTypishHsName, fromValishHsName :: Name -> Name
fromTypishHsName name
    | nameType name == QuotedName = name
    | isConstructorLike name = toName TypeConstructor name
    | otherwise = toName TypeVal name
fromValishHsName name
    | nameType name == QuotedName = name
    | isConstructorLike name = toName DataConstructor name
    | otherwise = toName Val name

createName :: NameType -> Module -> String -> Name
createName _ (Module "") i = error $ "createName: empty module " ++ i
createName _ m "" = error $ "createName: empty ident " ++ show m
createName t m i = Name $ toAtom $ (chr $ ord '1' + fromEnum t):show m ++ ";" ++ i

createUName :: NameType -> String -> Name
createUName _ "" = error $ "createUName: empty ident"
createUName t i =  Name $ toAtom $ (chr $ fromEnum t + ord '1'):";" ++ i

class ToName a where
    toName :: NameType -> a -> Name
    fromName :: Name -> (NameType, a)

instance ToName (String,String) where
    toName nt (m,i) = createName nt (Module $ toAtom m) i
    fromName n = case nameParts n of
            (nt,Just (Module m),i) -> (nt,(show m,i))
            (nt,Nothing,i) -> (nt,("",i))

instance ToName (Module,String) where
    toName nt (m,i) = createName nt m i
    fromName n = case nameParts n of
            (nt,Just m,i) -> (nt,(m,i))
            (nt,Nothing,i) -> (nt,(Module "",i))

instance ToName (Maybe Module,String) where
    toName nt (Just m,i) = createName nt m i
    toName nt (Nothing,i) = createUName nt i
    fromName n = case nameParts n of
        (nt,a,b) -> (nt,(a,b))

instance ToName Name where
    toName nt i = toName nt (x,y) where
        (_,x,y) = nameParts i
    fromName n = (nameType n,n)

instance ToName String where
    toName nt i = createUName nt i
    fromName n = (nameType n, mi ) where
        mi = case snd $ fromName n of
            (Just (Module m),i) -> show m ++ "." ++ i
            (Nothing,i) -> i

getModule :: Monad m => Name -> m Module
getModule n = case nameParts n of
    (_,Just m,_) -> return m
    _ -> fail "Name is unqualified."

getIdent :: Name -> String
getIdent n = case nameParts n of
    (_,_,s)  -> s

toUnqualified :: Name -> Name
toUnqualified n = case nameParts n of
    (_,Nothing,_) -> n
    (t,Just _,i) -> toName t (Nothing :: Maybe Module,i)

qualifyName :: Module -> Name -> Name
qualifyName m n = case nameParts n of
    (t,Nothing,n) -> toName t (Just m, n)
    _ -> n

setModule :: Module -> Name -> Name
setModule m n = qualifyName m  $ toUnqualified n

parseName :: NameType -> String -> Name
parseName t name = toName t (intercalate "." ms, intercalate "." (ns ++ [last sn])) where
    sn = (split (== '.') name)
    (ms,ns) = span validMod (init sn)
    validMod (c:cs) = isUpper c && all (\c -> isAlphaNum c || c `elem` "_'") cs
    validMod _ = False

nameType :: Name -> NameType
nameType (Name a) = toEnum $ fromIntegral ( a `unsafeByteIndex` 0) - ord '1'

nameName :: Name -> Name
nameName n = n

nameParts :: Name -> (NameType,Maybe Module,String)
nameParts n@(Name a) = f $ tail (fromAtom a) where
    f (';':xs) = (nameType n,Nothing,xs)
    f xs = (nameType n,Just $ Module (toAtom a),b) where
        (a,_:b) = span (/= ';') xs

instance Show Name where
    showsPrec _ n = case nameParts n of
        (QuotedName,Nothing,b) -> showChar '`' . showString b
        (_,Just a,b) -> shows a . showChar '.' . showString b
        (_,Nothing,b) -> showString b

instance DocLike d => PPrint d Name  where
    pprint n = text (show n)

mapName :: (Module -> Module,String -> String) -> Name -> Name
mapName (f,g) n = case nameParts n of
    (nt,Nothing,i) -> toName nt (g i)
    (nt,Just m,i) -> toName nt (Just (f m :: Module),g i)
mapName' :: (Maybe Module -> Maybe Module) -> (String -> String) -> Name -> Name
mapName' f g n = case nameParts n of
    (nt,m,i) -> toName nt (f m,g i)

ffiExportName :: FfiExport -> Name
ffiExportName (FfiExport cn _ cc _ _) = toName Val (Module "FE@", show cc ++ "." ++ cn)
type Class = Name

-------------
-- Quoting
-------------

quoteName :: Name -> Name
quoteName (Name n) = createUName QuotedName (fromAtom n)
fromQuotedName :: Name -> Maybe Name
fromQuotedName n = case nameParts n of
    (QuotedName,Nothing,s) -> Just $ Name (toAtom s)
    _ -> Nothing

--------------
-- Modules
--------------

newtype Module = Module Atom
  deriving(Eq,Data,Typeable,ToAtom,FromAtom)

instance Ord Module where
    compare x y = show x `compare` show y

instance Show Module where
    showsPrec _ (Module n) = shows n

fromModule (Module s) = fromAtom s

mainModule = Module "Main@"
primModule = Module "Prim@"
preludeModule = Module "Prelude"

toModule :: String -> Module
toModule s = Module $ toAtom s
