module Foo() where

-- check various type synonym expansions.

type XChar = Char
xc :: XChar
xc = 'x'

type Foo = Int
type Bar = Foo
type Bug x = Char
type App f x = f (Bug x)
type Fun = App Bug (Bug Char)
f :: Foo -> Int
f = id
--(x :: Foo) = 4
y = (1 + 4 :: Bar) `div` 3

z = 'z' :: Fun
w = let f = 'z' :: App Bug Foo in 4

class Baz a where
    g :: a -> Bar

instance Baz (Bug (Bug String)) where
    g = fromEnum

data Bob = Fred String
data Rob = Frod { frodString :: String }
