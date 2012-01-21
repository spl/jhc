{-# OPTIONS_JHC -fno-prelude -fffi -fm4   #-}

module System.Mem.StableName(StableName(),makeStableName,hashStableName) where


import Jhc.IO
import Jhc.Order
import Jhc.Basics

m4_include(Jhc/Order.m4)

data StableName a = StableName HeapAddr_

makeStableName :: a -> IO (StableName a)
makeStableName x = returnIO $ StableName (toHeapAddr x)

hashStableName :: StableName a -> Int
hashStableName (StableName a) = heapAddrToInt a

foreign import primitive toHeapAddr :: a -> HeapAddr_
foreign import primitive "U2I" heapAddrToInt :: HeapAddr_ -> Int

INST_EQORDER((StableName a),StableName,HeapAddr_,U)
