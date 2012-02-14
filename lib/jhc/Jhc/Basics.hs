{-# OPTIONS_JHC -fno-prelude -fffi #-}
module Jhc.Basics(module Jhc.Basics, module Jhc.Prim.Prim, module Jhc.Type.Basic, IO()) where

import Jhc.Type.Basic
import Jhc.Prim.Prim
import Jhc.Prim.IO
import Jhc.Int

------------------------
-- the basic combinators
------------------------

{-# SUPERINLINE id, const, (.), ($), ($!), flip #-}

infixr 9  .
infixr 0  $, $!, `seq`

id x = x
const x _ = x
f . g = \x -> f (g x)
f $ x = f x
f $! x = x `seq` f x
flip f x y = f y x

-- asTypeOf is a type-restricted version of const.  It is usually used
-- as an infix operator, and its typing forces its first argument
-- (which is usually overloaded) to have the same type as the second.

{-# SUPERINLINE asTypeOf #-}
asTypeOf         :: a -> a -> a
asTypeOf         =  const

{-# INLINE seq #-}
foreign import primitive seq :: a -> b -> b

--------------------
-- some tuple things
--------------------

{-# INLINE fst, snd #-}
fst (a,b) = a
snd (a,b) = b

uncurry f (x,y) = f x y
curry f x y = f (x,y)

----------------------
-- Basic list routines
----------------------

-- iterate f x returns an infinite list of repeated applications of f to x:
-- iterate f x == [x, f x, f (f x), ...]

iterate          :: (a -> a) -> a -> [a]
iterate f x      =  x : iterate f (f x)

-- repeat x is an infinite list, with x the value of every element.

repeat           :: a -> [a]
repeat x         =  xs where xs = x:xs

-- Map and append

map :: (a -> b) -> [a] -> [b]
map f xs = go xs where
    go [] = []
    go (x:xs) = f x : go xs

infixr 5  ++

(++) :: [a] -> [a] -> [a]
[]     ++ ys = ys
(x:xs) ++ ys = x : (xs ++ ys)

foldl            :: (a -> b -> a) -> a -> [b] -> a
foldl f z []     =  z
foldl f z (x:xs) =  foldl f (f z x) xs

scanl            :: (a -> b -> a) -> a -> [b] -> [a]
scanl f q xs     =  q : (case xs of
                            []   -> []
                            x:xs -> scanl f (f q x) xs)

reverse          :: [a] -> [a]
--reverse          =  foldl (flip (:)) []
reverse l =  rev l [] where
    rev []     a = a
    rev (x:xs) a = rev xs (x:a)

-- zip takes two lists and returns a list of corresponding pairs.  If one
-- input list is short, excess elements of the longer list are discarded.
-- zip3 takes three lists and returns a list of triples.  Zips for larger
-- tuples are in the List library

zip :: [a] -> [b] -> [(a,b)]
zip (a:as) (b:bs) = (a,b) : zip as bs
zip _      _      = []

-- The zipWith family generalises the zip family by zipping with the
-- function given as the first argument, instead of a tupling function.
-- For example, zipWith (+) is applied to two lists to produce the list
-- of corresponding sums.

zipWith          :: (a->b->c) -> [a]->[b]->[c]
zipWith z (a:as) (b:bs) =  z a b : zipWith z as bs
zipWith _ _ _    =  []

concat :: [[a]] -> [a]
concat [] = []
concat (x:xs) = case x of
    [] -> concat xs
    (y:ys) -> y:concat (ys:xs)

concatMap :: (a -> [b]) -> [a] -> [b]
concatMap f xs = g xs where
    g [] = []
    g (x:xs) = f x ++ g xs

foldr :: (a -> b -> b) -> b -> [a] -> b
foldr k z [] = z
foldr k z (x:xs) = k x (foldr k z xs)

drop :: Int -> [a] -> [a]
drop n xs = f n xs where
    f n xs | n `leq` zero =  xs
    f _ [] = []
    f n (_:xs) = f (n `minus` one) xs

foreign import primitive "Lte" leq :: Int -> Int -> Bool

foreign import primitive "error.Prelude.undefined" undefined :: a

unsafeChr :: Int -> Char
unsafeChr = chr

{-
ord :: Char -> Int
ord (Char (Char_ c)) = boxInt c

chr :: Int -> Char
chr i = Char (Char_ (unboxInt i))

foreign import primitive "ULte" bits32ULte  :: Bits32_ -> Bits32_ -> Bool__
foreign import primitive "error.Prelude.chr: value out of range" chr_error :: a

chr :: Int -> Char
chr i = case unboxInt i of
    i' -> case i' `bits32ULTE` 0x10FFFF# of
        1# -> Char i'
        0# -> chr_error

unsafeChr :: Int -> Char
unsafeChr i = Char (unboxInt i)
-}

foreign import primitive "B2B" ord :: Char -> Int
foreign import primitive "B2B" chr :: Int -> Char
