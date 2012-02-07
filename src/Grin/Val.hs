module Grin.Val(
    FromVal(..),
    ToVal(..),
    tn_2Tup,
    valToList,
    cChar,
    cWord,
    cInt,
    convertName,
    region_heap,
    region_atomic_heap,
    region_stack,
    region_block
    ) where

import Char

import Cmm.Number
import Grin.Grin
import Name.Name
import Name.Names
import Name.VConsts
import StringTable.Atom

nil      = convertName dc_EmptyList
cons     = convertName dc_Cons
cChar    = convertName dc_Char
cWord    = convertName dc_Word
cInt     = convertName dc_Int
tn_2Tup  = convertName $ nameTuple DataConstructor 2
tn_Boolzh = convertName dc_Boolzh
tn_unit  = convertName dc_Unit

-- This allocates data on the heap.
region_heap  = Item (toAtom "heap") TyRegion
-- This allocates data on the atomic heap.
region_atomic_heap  = Item (toAtom "atomicHeap") TyRegion
-- This allocates data in the innermost enclosing region, including implicit regions.
region_block = Item (toAtom "block") TyRegion
-- This allocates data on the stack, generally equivalent to 'block' for most back ends.
region_stack = Item (toAtom "stack") TyRegion

instance ConNames Val where
    vTrue  = NodeC tn_Boolzh [toUnVal (1 :: Int)]
    vFalse = NodeC tn_Boolzh [toUnVal (0 :: Int)]
    vUnit  = NodeC tn_unit []

class ToVal a where
    toVal :: a -> Val
    toUnVal :: a -> Val
    toUnVal x = toVal x

class FromVal a where
    fromVal :: Monad m => Val -> m a
    fromUnVal :: Monad m => Val -> m a
    fromUnVal x = fromVal x

instance ToVal Bool where
    toVal True = vTrue
    toVal False = vFalse

instance ToVal a => ToVal [a] where
    toVal [] = NodeC nil []
    toVal (x:xs) =  NodeC cons [Const (toVal x),Const (toVal xs)]
instance  ToVal (Val,Val) where
    toVal (x,y) = NodeC tn_2Tup [x,y]

instance ToVal Char where
    toVal c = NodeC cChar [toUnVal c]
    toUnVal c =   Lit (fromIntegral $ ord c) tIntzh
instance ToVal Int where
    toVal c = NodeC cInt [toUnVal c]
    toUnVal c =  Lit (fromIntegral c) tIntzh

instance ToVal Val where
    toVal x = x

instance FromVal Int where
    fromVal (NodeC _ [Lit i _]) | Just x <- toIntegral i = return x
    fromVal n = fail $ "Val is not Int: " ++ show n
    fromUnVal (Lit i _) | Just x <- toIntegral i = return x
    fromUnVal n = fail $ "Val is not UnInt: " ++ show n
instance FromVal Char where
    fromVal (NodeC _ [Lit i _]) | Just x <- toIntegral i, x >= ord minBound && x <= ord maxBound = return (chr x)
    fromVal n = fail $ "Val is not Char: " ++ show n
    fromUnVal (Lit i _) | Just x <- toIntegral i, x >= ord minBound && x <= ord maxBound = return (chr x)
    fromUnVal n = fail $ "Val is not UnChar: " ++ show n

instance FromVal a => FromVal [a] where
    fromVal (NodeC n [])  | n == nil = return []
    fromVal (NodeC n [Const a,Const b]) | n == cons = do
        x <- fromVal a
        xs <- fromVal b
        return (x:xs)
    fromVal n = fail $ "Val is not [a]: " ++ show n

instance FromVal Bool  where
    fromVal n
        | n == toVal True = return True
        | n == toVal False = return False
    fromVal n = fail $ "Val is not Bool: " ++ show n
instance FromVal Val where
    fromVal n = return n

valToList (NodeC n []) | n == nil = return []
valToList (NodeC n [a,Const b]) | n == cons = do
        xs <- valToList b
        return (a:xs)
valToList n = fail $ "Val is not [a]: " ++ show n

convertName n = toAtom (t':s) where
    (t,s) = fromName n
    t' | t == TypeConstructor = 'T'
       | t == DataConstructor = 'C'
       | t == Val = 'f'
       | otherwise = error $ "convertName: " ++ show (t,s)
