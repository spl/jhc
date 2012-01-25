module FrontEnd.Tc.Type(
    Kind(..),
    KBase(..),
    MetaVar(..),
    MetaVarType(..),
    Pred(..),
    Preds(),
    Qual(..),
    Tycon(..),
    Type(..),
    Tyvar(..),
    kindStar,
    kindFunRet,
    kindUTuple,
    unfoldKind,
    fn,
    followTaus,
    fromTAp,
    fromTArrow,
    module FrontEnd.Tc.Type,
    prettyPrintType,
    readMetaVar,
    tForAll,
    tList,
    Constraint(..),
    applyTyvarMap,
    Class(),
    Kindvar(..),
    tTTuple,
    tTTuple',
    tAp,
    tArrow,
    tyvar
    ) where

import Control.Monad.Identity
import Control.Monad.Writer
import Data.IORef
import Data.List
import Data.Monoid
import qualified Data.Map as Map
import qualified Data.Set as S

import Doc.DocLike
import Doc.PPrint
import FrontEnd.Representation
import FrontEnd.SrcLoc
import FrontEnd.Tc.Kind
import Name.Name
import Name.Names
import Name.VConsts
import Support.CanType
import Support.FreeVars
import Support.Tickle

type Sigma' = Sigma
type Tau' = Tau
type Rho' = Rho
type Sigma = Type
type Rho = Type
type Tau = Type

type SkolemTV = Tyvar
type BoundTV = Tyvar

type Preds = [Pred]

data Constraint = Equality {
    constraintSrcLoc :: SrcLoc,
    constraintType1  :: Type,
    constraintType2  :: Type
    }

instance HasLocation Constraint where
    srcLoc Equality { constraintSrcLoc = sl } = sl

applyTyvarMap :: [(Tyvar,Type)] -> Type -> Type
applyTyvarMap ts t = f initMp t where
    initMp = Map.fromList [ (tyvarName v,t) | (v,t) <- ts ]
    -- XXX name capture!
    f mp (TForAll as qt) = TForAll as (fq (foldr Map.delete mp (map tyvarName as)) qt)
    f mp (TExists as qt) = TExists as (fq (foldr Map.delete mp (map tyvarName as)) qt)
    f mp (TVar tv) = case Map.lookup (tyvarName tv) mp of
            Just t'  -> t'
            Nothing -> (TVar tv)
    f mp t = tickle (f mp) t
    fq mp (ps :=> t) = map (tickle (f mp)) ps :=> f mp t

applyTyvarMapQT :: [(Tyvar,Type)] -> Qual Type -> Qual Type
applyTyvarMapQT ts qt = qt' where
    (TForAll [] qt') = applyTyvarMap ts (TForAll [] qt)

typeOfType :: Type -> (MetaVarType,Bool)
typeOfType TForAll { typeArgs = as, typeBody = _ :=> t } = (Sigma,isBoxy t)
typeOfType t | isTau' t = (Tau,isBoxy t)
typeOfType t = (Rho,isBoxy t)

fromType :: Sigma -> ([Tyvar],[Pred],Type)
fromType s = case s of
    TForAll as (ps :=> r) -> (as,ps,r)
    r -> ([],[],r)

isTau :: Type -> Bool
isTau TForAll {} = False
isTau (TMetaVar MetaVar { metaType = t })
    | t == Tau = True
    | otherwise = False
isTau t = getAll $ tickleCollect (All . isTau) t

isTau' :: Type -> Bool
isTau' TForAll {} = False
isTau' t = getAll $ tickleCollect (All . isTau') t

isBoxy :: Type -> Bool
isBoxy (TMetaVar MetaVar { metaType = t }) | t > Tau = True
isBoxy t = getAny $ tickleCollect (Any . isBoxy) t

isRho' :: Type -> Bool
isRho' TForAll {} = False
isRho' _ = True

isRho :: Type -> Bool
isRho r = isRho' r && not (isBoxy r)

isBoxyMetaVar :: MetaVar -> Bool
isBoxyMetaVar MetaVar { metaType = t } = t > Tau

extractTyVar ::  Monad m => Type -> m Tyvar
extractTyVar (TVar tv) = return tv
extractTyVar t = fail $ "not a Var:" ++ show t

extractMetaVar :: Monad m => Type -> m MetaVar
extractMetaVar (TMetaVar t)  = return t
extractMetaVar t = fail $ "not a metaTyVar:" ++ show t

extractBox :: Monad m => Type -> m MetaVar
extractBox (TMetaVar mv) | metaType mv > Tau  = return mv
extractBox t = fail $ "not a metaTyVar:" ++ show t

newtype UnVarOpt = UnVarOpt {
    failEmptyMetaVar :: Bool
    }

{-# SPECIALIZE flattenType :: MonadIO m => Type -> m Type #-}
flattenType :: (MonadIO m, UnVar t) => t -> m t
flattenType t = liftIO $ unVar' t

class UnVar t where
    unVar' ::   t -> IO t

instance UnVar t => UnVar [t] where
   unVar' xs = mapM unVar' xs

instance UnVar Pred where
    unVar' (IsIn c t) = IsIn c `liftM` unVar' t
    unVar' (IsEq t1 t2) = liftM2 IsEq (unVar' t1) (unVar' t2)

instance (UnVar a,UnVar b) => UnVar (a,b) where
    unVar' (a,b) = do
        a <- unVar' a
        b <- unVar' b
        return (a,b)

instance UnVar t => UnVar (Qual t) where
    unVar' (ps :=> t) = liftM2 (:=>) (unVar' ps) (unVar' t)

instance UnVar Type where
    unVar' tv =  do
        let ft (TForAll vs qt) = do
                qt' <- unVar' qt
                return $ TForAll vs qt'
            ft (TExists vs qt) = do
                qt' <- unVar' qt
                return $ TExists vs qt'
            ft (TAp (TAp (TCon arr) a1) a2) | tyconName arr == tc_Arrow = ft (TArrow a1 a2)
            ft t@(TMetaVar _) = return t
            ft t = tickleM (unVar' . (id :: Type -> Type)) t
        tv' <- findType tv
        ft tv'

followTaus :: MonadIO m => Type -> m Type
followTaus tv@(TMetaVar mv@MetaVar {metaRef = r }) | not (isBoxyMetaVar mv) = liftIO $ do
    rt <- readIORef r
    case rt of
        Nothing -> return tv
        Just t -> do
            t' <- followTaus t
            writeIORef r (Just t')
            return t'
followTaus tv = return tv

findType :: MonadIO m => Type -> m Type
findType tv@(TMetaVar MetaVar {metaRef = r }) = liftIO $ do
    rt <- readIORef r
    case rt of
        Nothing -> return tv
        Just t -> do
            t' <- findType t
            writeIORef r (Just t')
            return t'
findType tv = return tv

readMetaVar :: MonadIO m => MetaVar -> m (Maybe Type)
readMetaVar MetaVar { metaRef = r }  = liftIO $ do
    rt <- readIORef r
    case rt of
        Nothing -> return Nothing
        Just t -> do
            t' <- findType t
            writeIORef r (Just t')
            return (Just t')

{-
freeMetaVars :: Type -> S.Set MetaVar
freeMetaVars (TMetaVar mv) = S.singleton mv
freeMetaVars t = tickleCollect freeMetaVars t
freeMetaVars :: Type -> S.Set MetaVar
freeMetaVars t = worker t S.empty
    where worker :: Type -> (S.Set MetaVar -> S.Set MetaVar)
          worker (TMetaVar mv) = S.insert mv
          worker (TAp l r) = worker l . worker r
          worker (TArrow l r) = worker l . worker r
          worker (TAssoc c cas eas) = foldr (.) id (map worker cas) . foldr (.) id (map worker eas)
          worker (TForAll ta (ps :=> t)) = foldr (.) id (map worker2 ps) . worker t
          worker (TExists ta (ps :=> t)) = foldr (.) id (map worker2 ps) . worker t
          worker _ = id
          worker2 :: Pred -> (S.Set MetaVar -> S.Set MetaVar)
          worker2 (IsIn c t) = worker t
          worker2 (IsEq t1 t2) = worker t1 . worker t2
-}

freeMetaVars :: Type -> S.Set MetaVar
freeMetaVars t = f t where
    f (TMetaVar mv) = S.singleton mv
    f (TAp l r) = f l `S.union` f r
    f (TArrow l r) = f l `S.union` f r
    f (TAssoc c cas eas) = S.unions (map f cas ++ map f eas)
    f (TForAll ta (ps :=> t)) = S.unions (f t:map f2 ps)
    f (TExists ta (ps :=> t)) = S.unions (f t:map f2 ps)
    f _ = S.empty
    f2 (IsIn c t) = f t
    f2 (IsEq t1 t2) = f t1 `S.union` f t2

instance FreeVars Type [Tyvar] where
    freeVars (TVar u)      = [u]
    freeVars (TForAll vs qt) = freeVars qt Data.List.\\ vs
    freeVars (TExists vs qt) = freeVars qt Data.List.\\ vs
    freeVars t = foldr union [] $ tickleCollect ((:[]) . (freeVars :: Type -> [Tyvar])) t

instance FreeVars Type [MetaVar] where
    freeVars t = S.toList $ freeMetaVars t

instance FreeVars Type (S.Set MetaVar) where
    freeVars t = freeMetaVars t

instance (FreeVars t b,FreeVars Pred b) => FreeVars (Qual t) b where
    freeVars (ps :=> t)  = freeVars t `mappend` freeVars ps

instance FreeVars Type b =>  FreeVars Pred b where
    freeVars (IsIn _c t)  = freeVars t
    freeVars (IsEq t1 t2)  = freeVars (t1,t2)

instance Tickleable Type Pred where
    tickleM f (IsIn c t) = liftM (IsIn c) (f t)
    tickleM f (IsEq t1 t2) = liftM2 IsEq (f t1) (f t2)

instance Tickleable Type Type where
    tickleM f (TAp l r) = liftM2 tAp (f l) (f r)
    tickleM f (TArrow l r) = liftM2 TArrow (f l) (f r)
    tickleM f (TAssoc c cas eas) = liftM2 (TAssoc c) (mapM f cas) (mapM f eas)
    tickleM f (TForAll ta (ps :=> t)) = do
        ps <- mapM (tickleM f) ps
        liftM (TForAll ta . (ps :=>)) (f t)
    tickleM f (TExists ta (ps :=> t)) = do
        ps <- mapM (tickleM f) ps
        liftM (TExists ta . (ps :=>)) (f t)
    tickleM _ t = return t

data Rule = RuleSpec {
    ruleUniq :: (Module,Int),
    ruleName :: Name,
    ruleSuper :: Bool,
    ruleType :: Type
    } |
    RuleUser {
    ruleUniq :: (Module,Int),
    ruleFreeTVars :: [(Name,Kind)]
    }

-- CTFun f => \g . \y -> f (g y)
data CoerceTerm = CTId | CTAp [Type] | CTAbs [Tyvar] | CTFun CoerceTerm | CTCompose CoerceTerm CoerceTerm

instance Show CoerceTerm where
    showsPrec _ CTId = showString "id"
    showsPrec n (CTAp ts) = ptrans (n > 10) parens $ char '@' <+> hsep (map (parens . prettyPrintType) ts)
    showsPrec n (CTAbs ts) = ptrans (n > 10) parens $ char '\\' <+> hsep (map pprint ts)
    showsPrec n (CTFun ct) = ptrans (n > 10) parens $ text "->" <+> showsPrec 11 ct
    showsPrec n (CTCompose ct1 ct2) = ptrans (n > 10) parens $ (showsPrec 11 ct1) <+> char '.' <+> (showsPrec 11 ct2)

-- | Apply the function if the 'Bool' is 'True'.
ptrans :: Bool -> (a -> a) -> (a -> a)
ptrans b f = if b then f else id

instance Monoid CoerceTerm where
    mempty = CTId
    mappend = composeCoerce

ctFun :: CoerceTerm -> CoerceTerm
ctFun CTId = CTId
ctFun x = CTFun x

ctAbs :: [Tyvar] -> CoerceTerm
ctAbs [] = CTId
ctAbs xs = CTAbs xs

ctAp :: [Type] -> CoerceTerm
ctAp [] = CTId
ctAp xs = CTAp xs

ctId :: CoerceTerm
ctId = CTId

composeCoerce :: CoerceTerm -> CoerceTerm -> CoerceTerm
--composeCoerce (CTFun a) (CTFun b) = ctFun (a `composeCoerce` b)
composeCoerce CTId x = x
composeCoerce x CTId = x
--composeCoerce (CTAbs ts) (CTAbs ts') = CTAbs (ts ++ ts')
--composeCoerce (CTAp ts) (CTAp ts') = CTAp (ts ++ ts')
--composeCoerce (CTAbs ts) (CTAp ts') = f ts ts' where
--    f (t:ts) (TVar t':ts') | t == t' = f ts ts'
--    f [] [] = CTId
--    f _ _ = CTCompose (CTAbs ts) (CTAp ts')
composeCoerce x y = CTCompose x y

instance UnVar Type => UnVar CoerceTerm where
    unVar' (CTAp ts) = CTAp `liftM` unVar' ts
    unVar' (CTFun ct) = CTFun `liftM` unVar' ct
    unVar' (CTCompose c1 c2) = liftM2 CTCompose (unVar' c1) (unVar' c2)
    unVar' x = return x
