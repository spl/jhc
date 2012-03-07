{-# OPTIONS_JHC -fno-prelude #-}
module Data.Ix ( Ix(range, index, inRange, rangeSize) ) where

import Jhc.Int
import Jhc.Enum
import Jhc.Order
import Jhc.Basics
import Jhc.Num
import Jhc.Tuples
import Jhc.IO

class  Ord a => Ix a  where
    range     :: (a,a) -> [a]
    index     :: (a,a) -> a -> Int
    inRange   :: (a,a) -> a -> Bool
    rangeSize :: (a,a) -> Int

    rangeSize b@(l,h) = case range b of
        [] -> zero
        _  -> index b h `plus` one
	-- NB: replacing "null (range b)" by  "not (l <= h)"
	-- fails if the bounds are tuples.  For example,
	-- 	(1,2) <= (2,1)
	-- but the range is nevertheless empty
	--	range ((1,2),(2,1)) = []

instance  Ix Char  where
    range (m,n)		= [m..n]
    index b@(c,c') ci
        | inRange b ci  =  fromEnum ci `minus` fromEnum c
        | otherwise     =  error "Ix.index: Index out of range."
    inRange (c,c') i    =  c <= i && i <= c'

instance  Ix Int  where
    range (m,n)		= [m..n]
    index b@(m,n) i
        | inRange b i   =  i `minus` m
        | otherwise     =  error "Ix.index: Index out of range."
    inRange (m,n) i     =  m <= i && i <= n

instance  (Ix a, Ix b)  => Ix (a,b) where
        range   ((l,l'),(u,u')) = [(i,i') | i <- range (l,u), i' <- range (l',u')]
        index   ((l,l'),(u,u')) (i,i') =  index (l,u) i * rangeSize (l',u') + index (l',u') i'
        inRange ((l,l'),(u,u')) (i,i') = inRange (l,u) i && inRange (l',u') i'

--instance  Ix Integer  where
--    range (m,n)		= [m..n]
--    index b@(m,n) i
--        | inRange b i   =  fromInteger (i - m)
--        | otherwise     =  error "Ix.index: Index out of range."
--    inRange (m,n) i     =  m <= i && i <= n

instance  Ix Bool  where
    range (m,n)		= [m..n]
    index b@(c,c') ci
        | inRange b ci  =  fromEnum ci `minus` fromEnum c
        | otherwise     =  error "Ix.index: 'Bool' Index out of range."
    inRange (c,c') i    =  c <= i && i <= c'

instance  Ix Ordering  where
    range (m,n)		= [m..n]
    index b@(c,c') ci
        | inRange b ci  =  fromEnum ci `minus` fromEnum c
        | otherwise     =  error "Ix.index: 'Ordering' Index out of range."
    inRange (c,c') i    =  c <= i && i <= c'

-- instance (Ix a,Ix b) => Ix (a, b) -- as derived, for all tuples
-- instance Ix Bool                  -- as derived
-- instance Ix Ordering              -- as derived
-- instance Ix ()                    -- as derived
