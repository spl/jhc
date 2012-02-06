{-# OPTIONS_JHC -fno-prelude -funboxed-tuples -fffi #-}

module Jhc.IO(
    IO(..),
    thenIO,
    thenIO_,
    returnIO,
    fromUIO,
    fromUIO_,

    UIO(),
    UIO_(),

    World__(),
    catch,
    unIO,
    etaIO,
    dependingOn,
    fixIO,
    ioError,
    runMain,
    exitFailure,
    strictReturn,
    unsafeInterleaveIO,
    error,
    IOError(),
    userError,
    unsafePerformIO,
    unsafePerformIO'
    ) where

import Jhc.Basics
import Jhc.Prim
import Jhc.Type.Handle
import qualified Jhc.Options

unIO :: IO a -> UIO a
unIO (IO (ST x)) = x

fromUIO :: UIO a -> IO a
fromUIO x = IO (ST x)

fromUIO_ :: UIO_ -> IO ()
fromUIO_ f = IO $ ST (\w -> (# f w, () #))

-- | this ensures the world parameter is eta expanded out
{-# INLINE etaIO #-}
etaIO :: IO a -> IO a
etaIO x = fromUIO (\w -> unIO x w)

-- unsafe operations

unsafePerformIO :: IO a -> a
unsafePerformIO x = case newWorld__ x of
    world -> case unIO (errorContinuation x) world of
            (# _, a #) -> a

-- | same as unsafePerformIO, but doesn't set up error handler
unsafePerformIO' :: IO a -> a
unsafePerformIO' x = case newWorld__ x of
    world -> case (unIO x) world of
            (# _, a #) -> a

-- we have to replace the error handler because the context might have quit by the time the value is evaluated.
unsafeInterleaveIO :: IO a -> IO a
unsafeInterleaveIO action = fromUIO $ \w -> (# w , case action' w of (# _,  a #) -> a #)
    where action' = unIO $ errorContinuation action

showError :: IOError -> IO b
--showError (IOError z) = putErrLn z `thenIO_` exitFailure
showError ioe = putErrLn (ioeGetErrorString ioe) `thenIO_` exitFailure

userError x = IOError User x Nothing Nothing

errorContinuation :: IO a -> IO a
errorContinuation x = catch x showError

ioError :: IOError -> IO a
ioError e = case Jhc.Options.target of
    Jhc.Options.GhcHs -> fromUIO $
        \w -> (case raiseIO__ e w of w' -> (# w', raiseError #))
    _ -> showError e

catch :: IO a -> (IOError -> IO a) -> IO a
catch a k =  case Jhc.Options.target of
    Jhc.Options.GhcHs -> fromUIO $ \s -> catch__ (unIO a) (\ex -> unIO (k ex)) s
    _ -> a  -- no catching on other targets just yet

-- IO fixpoint operation

data FixIO a = FixIO World__ a

fixIO :: (a -> IO a) -> IO a
fixIO k = fromUIO $ \w -> let r = case k ans of
                               IO (ST z) -> case z w of
                                         (# w', r' #) -> FixIO w' r'
                              ans = case r of
                                 FixIO _ z -> z
                     in case r of
                          FixIO w' z -> (# w', z #)

-- some primitives

-- | this creates a new world object that artificially depends on its argument to avoid CSE.
foreign import primitive newWorld__ :: a -> World__
foreign import primitive "dependingOn" worldDep__ :: forall b. b -> World__ -> b

-- | this will return a value making it artificially depend on the state of the world. any uses of this value are guarenteed not to float before this point in the IO monad.
strictReturn :: a -> IO a
strictReturn a = IO $ ST $ \w -> (# w, worldDep__ a w #)

{-# INLINE runMain #-}
-- | this is wrapped around 'main' when compiling programs. it catches any exceptions and prints them to the screen and dies appropriatly.
runMain :: IO a -> World__ -> World__
runMain main w = case run w of
        (# w,  _ #) -> w
    where
    IO (ST run) = catch main $ \e ->
            putErrLn "\nUncaught Exception:" `thenIO_`
            putErrLn (ioeGetErrorString e)   `thenIO_`
            exitFailure

exitFailure :: IO a
exitFailure = IO $ ST $ \w -> exitFailure__ w

foreign import primitive exitFailure__ :: World__ -> (# World__, a #)

thenIO_ :: IO a -> IO b -> IO b
IO (ST a) `thenIO_` IO (ST b) = IO $ ST $ \w -> case a w of
    (# w', _ #) -> b w'

IO (ST a) `thenIO` b = IO $ ST $ \w -> case a w of
    (# w', v #) -> unIO (b v) w'

returnIO :: a -> IO a
returnIO x = IO $ ST (\w -> (# w, x #))

{-# NOINLINE error #-}
error s = unsafePerformIO' $
    putErrLn "error:"  `thenIO_`
    putErrLn s         `thenIO_`
    exitFailure

putErrLn :: [Char] -> IO ()
putErrLn [] = putChar '\n'
putErrLn (c:cs) = putChar c `thenIO_` putErrLn cs
putChar :: Char -> IO ()
putChar c = c_putwchar (charToInt c)

foreign import primitive "U2U" charToInt :: Char -> Int
foreign import ccall "stdio.h jhc_utf8_putchar" c_putwchar :: Int -> IO ()
foreign import primitive "error.raiseIO__" raiseError :: a
