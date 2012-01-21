-- | some useful types to use in Info's that don't really fit anywhere else
module Info.Types(module Info.Types, module Info.Properties) where

import Data.Dynamic
import Data.Monoid
import Info.Properties

import Util.BitSet
import Util.HasSize
import Util.SetLike
import qualified Info.Info as Info

-- | how many arguments a function my be applied to before it performs work and whether it bottoms out after that many arguments
data Arity = Arity Int Bool
    deriving(Typeable,Show,Ord,Eq)

-- | how the variable is bound
--data BindType = CaseDefault | CasePattern | LetBound | LambdaBound | PiBound
--    deriving(Show,Ord,Eq)

instance Show Properties where
    showsPrec _ props = shows (toList props)

-- | list of properties of a function, such as specified by use pragmas or options
newtype Properties = Properties (EnumBitSet Property)
    deriving(Typeable,Eq,Collection,SetLike,HasSize,Monoid,Unionize,IsEmpty)

type instance Elem Properties = Property
type instance Key Properties = Property

class HasProperties a where
    modifyProperties :: (Properties -> Properties) -> a -> a
    getProperties :: a -> Properties
    putProperties :: Properties -> a -> a

    setProperty :: Property -> a -> a
    unsetProperty :: Property -> a -> a
    getProperty :: Property -> a -> Bool
    setProperties :: [Property] -> a -> a

    unsetProperty prop = modifyProperties (delete prop)
    setProperty prop = modifyProperties (insert prop)
    setProperties xs = modifyProperties (`mappend` fromList xs)
    getProperty atom = member atom . getProperties

instance HasProperties Properties where
    getProperties prop = prop
    putProperties prop _ = prop
    modifyProperties f = f

fetchProperties :: Info.Info -> Maybe Properties
fetchProperties = Info.lookupTyp (undefined :: Properties)

instance HasProperties Info.Info where
    modifyProperties f info = case fetchProperties info of
        Just x -> Info.insert (f x) info
        Nothing -> Info.insert (f mempty) info
    getProperties info = case fetchProperties info of
        Just p -> p
        Nothing -> mempty
    putProperties prop info = Info.insert prop info
