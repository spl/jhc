{-# OPTIONS_GHC -funbox-strict-fields -fallow-overlapping-instances #-}
--
-- (c) The University of Glasgow 2002
--
-- Binary I/O library, with special tweaks for GHC
--
-- Based on the nhc98 Binary library, which is copyright
-- (c) Malcolm Wallace and Colin Runciman, University of York, 1998.
-- Under the terms of the license for that software, we must tell you
-- where you can obtain the original version of the Binary library, namely
--     http://www.cs.york.ac.uk/fp/nhc98/

-- with modifications by John Meacham for jhc

module Binary
  ( {-class-} Binary(..),
    {-type-}  BinHandle,

   openBinIO,

   -- for writing instances:
   putByte,
   getByte,

   getNList,
   putNList,

   getN8List,
   putN8List,

   -- lazy Bin I/O
   lazyGet,
   lazyPut,


  ) where


import Data.Array.IO
import Data.Array.Base
import Data.Bits
import System.Time
import Foreign.Storable
import Data.Int
import Data.Word
import Data.Char		( ord, chr )
import Control.Monad
import System.IO as IO
import System.IO.Unsafe		( unsafeInterleaveIO )
import GHC.Real			( Ratio(..) )
import GHC.Exts
import GHC.IOBase	 	( IO(..) )
import GHC.Word			( Word8(..) )
import PackedString
import Atom
import Time
import Data.Array.IArray



---------------------------------------------------------------
--		BinHandle
---------------------------------------------------------------

data BinHandle = BinHandle {
    off_r :: !FastMutInt,
    target_r :: !IO.Handle
    }


---------------------------------------------------------------
--		Bin
---------------------------------------------------------------

newtype Bin a = BinPtr Int
  deriving (Eq, Ord, Show, Bounded)

castBin :: Bin a -> Bin b
castBin (BinPtr i) = BinPtr i

---------------------------------------------------------------
--		class Binary
---------------------------------------------------------------

class Binary a where
    put_   :: BinHandle -> a -> IO ()
    get    :: BinHandle -> IO a

putAt  :: Binary a => BinHandle -> Bin a -> a -> IO ()
putAt bh p x = do seekBin bh p; put_ bh x; return ()

getAt  :: Binary a => BinHandle -> Bin a -> IO a
getAt bh p = do seekBin bh p; get bh


openBinIO :: IO.Handle -> IO BinHandle
openBinIO h = do
  r <- newFastMutInt
  writeFastMutInt r 0
  hSetBinaryMode h True
  hSetBuffering h (BlockBuffering Nothing)
  return (BinHandle r (h))


tellBin :: BinHandle -> IO (Bin a)
tellBin (BinHandle r _)   = do ix <- readFastMutInt r; return (BinPtr ix)

seekBin :: BinHandle -> Bin a -> IO ()
seekBin (BinHandle ix_r (h)) (BinPtr p) = do
  writeFastMutInt ix_r p
  hSeek h AbsoluteSeek (fromIntegral p)

isEOFBin :: BinHandle -> IO Bool
isEOFBin (BinHandle _ (h)) = hIsEOF h



-- -----------------------------------------------------------------------------
-- Low-level reading/writing of bytes

putWord8 :: BinHandle -> Word8 -> IO ()
putWord8 (BinHandle ix_r (h)) w = do
    hPutChar h (chr (fromIntegral w))	-- XXX not really correct
    ix <- readFastMutInt ix_r
    writeFastMutInt ix_r (ix+1)
    return ()

getWord8 :: BinHandle -> IO Word8
getWord8 (BinHandle ix_r (h)) = do
    ix <- readFastMutInt ix_r
    writeFastMutInt ix_r (ix+1)
    c <- hGetChar h
    return $! (fromIntegral (ord c))	-- XXX not really correct

{-# INLINE putByte #-}
putByte :: BinHandle -> Word8 -> IO ()
putByte bh w = putWord8 bh w

{-# INLINE getByte #-}
getByte :: BinHandle -> IO Word8
getByte = getWord8


-- These do not increment the counter

{-# INLINE putByteIO #-}
putByteIO :: FastMutInt -> Handle -> Word8 -> IO ()
putByteIO ix_r h w = do
    hPutChar h (chr (fromIntegral w))	-- XXX not really correct
    return ()

{-# INLINE getByteIO #-}
getByteIO :: FastMutInt -> Handle -> IO Word8
getByteIO ix_r h = do
    c <- hGetChar h
    return $! (fromIntegral (ord c))	-- XXX not really correct

{-# INLINE increment #-}
increment :: FastMutInt -> Int -> IO ()
increment ix i = do
    v <- readFastMutInt ix
    writeFastMutInt ix (v + i)


-- -----------------------------------------------------------------------------
-- Primitve Word writes

instance Binary Word8 where
  put_ = putWord8
  get  = getWord8

instance Binary Word16 where
  put_ h w = do -- XXX too slow.. inline putWord8?
    w <- return $ fromIntegral w
    putByte h (fromIntegral ((w `unsafeShiftR` 8) .&. 0xff))
    putByte h (fromIntegral (w .&. 0xff))
  get h = do
    w1 <- getWord8 h
    w2 <- getWord8 h
    return $! fromIntegral ((fromIntegral w1 `unsafeShiftL` 8) .|. fromIntegral w2)

unsafeShiftL (W# a) (I# b) = (W# (a `uncheckedShiftL#` b))
unsafeShiftR (W# a) (I# b) = (W# (a `uncheckedShiftRL#` b))

instance Binary Word32 where
  put_ (BinHandle ix (h)) w = do
    w <- return $ fromIntegral w
    putByteIO ix h (fromIntegral ((w `unsafeShiftR` 24) .&. 0xff))
    putByteIO ix h (fromIntegral ((w `unsafeShiftR` 16) .&. 0xff))
    putByteIO ix h (fromIntegral ((w `unsafeShiftR` 8)  .&. 0xff))
    putByteIO ix h (fromIntegral (w .&. 0xff))
    increment ix 4
  get (BinHandle ix (h)) = do
    w1 <- getByteIO ix h
    w2 <- getByteIO ix h
    w3 <- getByteIO ix h
    w4 <- getByteIO ix h
    increment ix 4
    return $! fromIntegral $ ((fromIntegral w1 `unsafeShiftL` 24) .|.
	       (fromIntegral w2 `unsafeShiftL` 16) .|.
	       (fromIntegral w3 `unsafeShiftL`  8) .|.
	       (fromIntegral w4))


{-
instance Binary Word64 where
  put_ h w = do
    putByte h (fromIntegral (w `unsafeShiftR` 56))
    putByte h (fromIntegral ((w `unsafeShiftR` 48) .&. 0xff))
    putByte h (fromIntegral ((w `unsafeShiftR` 40) .&. 0xff))
    putByte h (fromIntegral ((w `unsafeShiftR` 32) .&. 0xff))
    putByte h (fromIntegral ((w `unsafeShiftR` 24) .&. 0xff))
    putByte h (fromIntegral ((w `unsafeShiftR` 16) .&. 0xff))
    putByte h (fromIntegral ((w `unsafeShiftR`  8) .&. 0xff))
    putByte h (fromIntegral (w .&. 0xff))
  get h = do
    w1 <- getWord8 h
    w2 <- getWord8 h
    w3 <- getWord8 h
    w4 <- getWord8 h
    w5 <- getWord8 h
    w6 <- getWord8 h
    w7 <- getWord8 h
    w8 <- getWord8 h
    return $! ((fromIntegral w1 `unsafeShiftL` 56) .|.
	       (fromIntegral w2 `unsafeShiftL` 48) .|.
	       (fromIntegral w3 `unsafeShiftL` 40) .|.
	       (fromIntegral w4 `unsafeShiftL` 32) .|.
	       (fromIntegral w5 `unsafeShiftL` 24) .|.
	       (fromIntegral w6 `unsafeShiftL` 16) .|.
	       (fromIntegral w7 `unsafeShiftL`  8) .|.
	       (fromIntegral w8))
-}

-- -----------------------------------------------------------------------------
-- Primitve Int writes

instance Binary Int8 where
  put_ h w = put_ h (fromIntegral w :: Word8)
  get h    = do w <- get h; return $! (fromIntegral (w::Word8))

instance Binary Int16 where
  put_ h w = put_ h (fromIntegral w :: Word16)
  get h    = do w <- get h; return $! (fromIntegral (w::Word16))

instance Binary Int32 where
  put_ h w = put_ h (fromIntegral w :: Word32)
  get h    = do w <- get h; return $! (fromIntegral (w::Word32))

{-
instance Binary Int64 where
  put_ h w = put_ h (fromIntegral w :: Word64)
  get h    = do w <- get h; return $! (fromIntegral (w::Word64))
-}
-- -----------------------------------------------------------------------------
-- Instances for standard types

instance Binary () where
    put_ bh () = return ()
    get  _     = return ()
--    getF bh p  = case getBitsF bh 0 p of (_,b) -> ((),b)

instance Binary Bool where
    put_ bh b = putByte bh (fromIntegral (fromEnum b))
    get  bh   = do x <- getWord8 bh; return $! (toEnum (fromIntegral x))
--    getF bh p = case getBitsF bh 1 p of (x,b) -> (toEnum x,b)

instance Binary Char where
    put_  bh c = put_ bh (fromIntegral (ord c) :: Word32)
    get  bh   = do x <- get bh; return $! (chr (fromIntegral (x :: Word32)))
--    getF bh p = case getBitsF bh 8 p of (x,b) -> (toEnum x,b)

-- portability demands ints restricted to 32 bits
instance Binary Int where
    put_ bh i = put_ bh (fromIntegral i :: Int32)
    get  bh = do
	x <- get bh
	return $! (fromIntegral (x :: Int32))

instance Binary Word where
    put_ bh i = put_ bh (fromIntegral i :: Word32)
    get  bh = do
	x <- get bh
	return $! (fromIntegral (x :: Word32))

instance Binary ClockTime where
    put_ bh (TOD x y) = put_ bh x >> put_ bh y
    get bh = do
        x <- get bh
        y <- get bh
        return $ TOD x y


instance Binary PackedString where
    put_ bh (PS a) = put_ bh a
    get bh = fmap PS $ get bh


-- | put length prefixed list.
putNList :: Binary a => BinHandle -> [a] -> IO ()
putNList bh xs = do
    put_ bh (length xs)
    mapM_ (put_ bh) xs

-- | get length prefixed list.
getNList :: Binary a => BinHandle -> IO [a]
getNList bh = do
    n <- get bh
    sequence $ replicate n (get bh)

-- | put length prefixed list.
putN8List :: Binary a => BinHandle -> [a] -> IO ()
putN8List bh xs = do
    let len = length xs
    when (length xs > 255) $ fail "putN8List, list is too long"
    putWord8 bh (fromIntegral len)
    mapM_ (put_ bh) xs

-- | get length prefixed list.
getN8List :: Binary a => BinHandle -> IO [a]
getN8List bh = do
    n <- getWord8 bh
    sequence $ replicate (fromIntegral n) (get bh)

instance Binary a => Binary [a] where
    put_ bh []     = putByte bh 0
    put_ bh (x:xs) = do putByte bh 1; put_ bh x; put_ bh xs
    get bh         = do h <- getWord8 bh
                        case h of
                          0 -> return []
                          _ -> do x  <- get bh
                                  xs <- get bh
                                  return (x:xs)

instance (Binary a, Binary b) => Binary (a,b) where
    put_ bh (a,b) = do put_ bh a; put_ bh b
    get bh        = do a <- get bh
                       b <- get bh
                       return (a,b)

instance (Binary a, Binary b, Binary c) => Binary (a,b,c) where
    put_ bh (a,b,c) = do put_ bh a; put_ bh b; put_ bh c
    get bh          = do a <- get bh
                         b <- get bh
                         c <- get bh
                         return (a,b,c)

instance (Binary a, Binary b, Binary c, Binary d) => Binary (a,b,c,d) where
    put_ bh (a,b,c,d) = do put_ bh a; put_ bh b; put_ bh c; put_ bh d
    get bh          = do a <- get bh
                         b <- get bh
                         c <- get bh
                         d <- get bh
                         return (a,b,c,d)

instance Binary a => Binary (Maybe a) where
    put_ bh Nothing  = putByte bh 0
    put_ bh (Just a) = do putByte bh 1; put_ bh a
    get bh           = do
        h <- getWord8 bh
        case h of
            0 -> return Nothing
            _ -> do
                x <- get bh
                return (Just x)

instance (Binary a, Binary b) => Binary (Either a b) where
    put_ bh (Left  a) = do putByte bh 0; put_ bh a
    put_ bh (Right b) = do putByte bh 1; put_ bh b
    get bh            = do h <- getWord8 bh
                           case h of
                             0 -> do a <- get bh ; return (Left a)
                             _ -> do b <- get bh ; return (Right b)



-- these flatten the start element. hope that's okay!
instance Binary (UArray Int Word8) where
    put_ bh@(BinHandle ix_r (h)) ua = do
        let sz = rangeSize (Data.Array.Base.bounds ua)
        put_ bh sz
        ix <- readFastMutInt ix_r
        ua <- unsafeThaw ua
        hPutArray h ua sz
        writeFastMutInt ix_r (ix + sz)
    get bh@(BinHandle ix_r (h)) = do
        sz <- get bh
        ix <- readFastMutInt ix_r
        ba <- newArray_ (0, sz - 1)
        hGetArray h ba sz
        writeFastMutInt ix_r (ix + sz)
        ba <- unsafeFreeze ba
        return ba

instance Binary Integer where
    put_ bh (S# i#) = do putByte bh 0; put_ bh (I# i#)
    put_ bh (J# s# a#) = do
 	p <- putByte bh 1;
	put_ bh (I# s#)
	let sz# = sizeofByteArray# a#  -- in *bytes*
	put_ bh (I# sz#)  -- in *bytes*
	putByteArray bh a# sz#

    get bh = do
	b <- getByte bh
	case b of
	  0 -> do (I# i#) <- get bh
		  return (S# i#)
	  _ -> do (I# s#) <- get bh
		  sz <- get bh
		  (BA a#) <- getByteArray bh sz
		  return (J# s# a#)

putByteArray :: BinHandle -> ByteArray# -> Int# -> IO ()
putByteArray bh a s# = loop 0#
  where loop n#
	   | n# ==# s# = return ()
	   | otherwise = do
	   	putByte bh (indexByteArray a n#)
		loop (n# +# 1#)

getByteArray :: BinHandle -> Int -> IO ByteArray
getByteArray bh (I# sz) = do
  (MBA arr) <- newByteArray sz
  let loop n
	   | n ==# sz = return ()
	   | otherwise = do
		w <- getByte bh
		writeByteArray arr n w
		loop (n +# 1#)
  loop 0#
  freezeByteArray arr


data ByteArray = BA ByteArray#
data MBA = MBA (MutableByteArray# RealWorld)

newByteArray :: Int# -> IO MBA
newByteArray sz = IO $ \s ->
  case newByteArray# sz s of { (# s, arr #) ->
  (# s, MBA arr #) }

freezeByteArray :: MutableByteArray# RealWorld -> IO ByteArray
freezeByteArray arr = IO $ \s ->
  case unsafeFreezeByteArray# arr s of { (# s, arr #) ->
  (# s, BA arr #) }

writeByteArray :: MutableByteArray# RealWorld -> Int# -> Word8 -> IO ()

writeByteArray arr i (W8# w) = IO $ \s ->
  case writeWord8Array# arr i w s of { s ->
  (# s, () #) }

indexByteArray a# n# = W8# (indexWord8Array# a# n#)

instance (Integral a, Binary a) => Binary (Ratio a) where
    put_ bh (a :% b) = do put_ bh a; put_ bh b
    get bh = do a <- get bh; b <- get bh; return (a :% b)
--  #endif

instance Binary (Bin a) where
  put_ bh (BinPtr i) = put_ bh i
  get bh = do i <- get bh; return (BinPtr i)

-- -----------------------------------------------------------------------------
-- Lazy reading/writing

lazyPut :: Binary a => BinHandle -> a -> IO ()
lazyPut bh a = do
	-- output the obj with a ptr to skip over it:
    pre_a <- tellBin bh
    put_ bh pre_a	-- save a slot for the ptr
    put_ bh a		-- dump the object
    q <- tellBin bh 	-- q = ptr to after object
    putAt bh pre_a q 	-- fill in slot before a with ptr to q
    seekBin bh q	-- finally carry on writing at q

lazyGet :: Binary a => BinHandle -> IO a
lazyGet bh = do
    p <- get bh		-- a BinPtr
    p_a <- tellBin bh
    a <- unsafeInterleaveIO (getAt bh p_a)
    seekBin bh p -- skip over the object for now
    return a


instance Binary Atom where
    get bh = do
        ps <- get bh
        a <- fromPackedStringIO ps
        return a
    put_ bh a = put_ bh (toPackedString a)

-- FastMutInt

sSIZEOF_HSINT = sizeOf (undefined :: Int)

data FastMutInt = FastMutInt (MutableByteArray# RealWorld)

newFastMutInt :: IO FastMutInt
newFastMutInt = IO $ \s ->
  case newByteArray# size s of { (# s, arr #) ->
  (# s, FastMutInt arr #) }
  where I# size = sSIZEOF_HSINT

{-# INLINE readFastMutInt  #-}
readFastMutInt :: FastMutInt -> IO Int
readFastMutInt (FastMutInt arr) = IO $ \s ->
  case readIntArray# arr 0# s of { (# s, i #) ->
  (# s, I# i #) }

{-# INLINE writeFastMutInt  #-}
writeFastMutInt :: FastMutInt -> Int -> IO ()
writeFastMutInt (FastMutInt arr) (I# i) = IO $ \s ->
  case writeIntArray# arr 0# i s of { s ->
  (# s, () #) }

