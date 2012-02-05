{-# OPTIONS_JHC -fno-prelude -funboxed-tuples -fffi #-}
module Jhc.Array where

import Jhc.Basics
import Jhc.IO
import Jhc.Int

data MutArray__ :: * -> #
data Array__ :: * -> #

foreign import primitive newMutArray__      :: Int_ -> a -> UIO (MutArray__ a)
foreign import primitive newBlankMutArray__ :: Int_ -> UIO (MutArray__ a)
foreign import primitive copyArray__        :: Int_ -> Int_ -> Int_ -> Array__ a -> MutArray__ a -> UIO_
foreign import primitive copyMutArray__     :: Int_ -> Int_ -> Int_ -> MutArray__ a -> MutArray__ a -> UIO_
foreign import primitive readArray__        :: MutArray__ a -> Int_ -> UIO a
foreign import primitive writeArray__       :: MutArray__ a -> Int_ -> a -> UIO_
foreign import primitive indexArray__       :: Array__ a -> Int_ -> (# a #)

-- these basically cast from a mutable to an immutable array and back again
foreign import primitive unsafeFreezeArray__ :: MutArray__ a -> UIO (Array__ a)
foreign import primitive unsafeThawArray__ :: Array__ a -> UIO (MutArray__ a)

foreign import primitive newWorld__ :: a -> World__

newArray :: a -> Int -> [(Int,a)] -> Array__ a
newArray init n xs = case unboxInt n of
    n' -> case newWorld__ (init,n,xs) of
     w -> case newMutArray__ n' init w of
      (# w, arr #) -> let
        f :: MutArray__ a -> World__ -> [(Int,a)] -> World__
        f arr w [] = w
        f arr w ((i,v):xs) = case unboxInt i of i' -> case writeArray__ arr i' v w of w -> f arr w xs
            in case f arr w xs of w -> case unsafeFreezeArray__ arr w  of (# _, r #) -> r
