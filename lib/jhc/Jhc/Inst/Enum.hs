{-# OPTIONS_JHC -fno-prelude -fffi -funboxed-values -fm4 #-}
module Jhc.Inst.Enum() where

import Jhc.Enum
import Jhc.Class.Num
import Jhc.Class.Real
import Jhc.Class.Ord
import Jhc.IO(error)
import Jhc.Basics
import Jhc.Type.C

m4_include(Jhc/Enum.m4)

ENUMINST(Word)
ENUMINST(Word8)
ENUMINST(Word16)
ENUMINST(Word32)
ENUMINST(Word64)
ENUMINST(WordPtr)
ENUMINST(WordMax)

UBOUNDED(Word)
UBOUNDED(Word8)
UBOUNDED(Word16)
UBOUNDED(Word32)
UBOUNDED(Word64)
UBOUNDED(WordPtr)
UBOUNDED(WordMax)

ENUMINST(Int8)
ENUMINST(Int16)
ENUMINST(Int32)
ENUMINST(Int64)
ENUMINST(IntPtr)
ENUMINST(IntMax)
ENUMINST(Integer)

BOUNDED(Int8)
BOUNDED(Int16)
BOUNDED(Int32)
BOUNDED(Int64)
BOUNDED(IntPtr)
BOUNDED(IntMax)

ENUMINST(CChar)
BOUNDED(CChar)
ENUMINST(CSChar)
BOUNDED(CSChar)
ENUMINST(CUChar)
UBOUNDED(CUChar)
ENUMINST(CSize)
BOUNDED(CSize)
ENUMINST(CInt)
BOUNDED(CInt)
ENUMINST(CUInt)
UBOUNDED(CUInt)
ENUMINST(CWchar)
UBOUNDED(CWchar)

ENUMINST(CLong)
BOUNDED(CLong)
ENUMINST(CULong)
UBOUNDED(CULong)

instance Enum () where
    succ _      = error "Prelude.Enum.().succ: bad argument"
    pred _      = error "Prelude.Enum.().pred: bad argument"

    toEnum x | x == 0 = ()
             | True    = error "Prelude.Enum.().toEnum: bad argument"

    fromEnum () = 0
    enumFrom () 	= [()]
    enumFromThen () () 	= let many = ():many in many
    enumFromTo () () 	= [()]
    enumFromThenTo () () () = let many = ():many in many
