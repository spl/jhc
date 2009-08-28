
-- a fast, straightforward points to analysis
-- meant to determine nodes that are always in whnf
-- and find out evals or applys that always
-- apply to a known value

module Grin.NodeAnalyze(nodeAnalyze) where

import Control.Monad(forM, forM_, when)
import Control.Monad.RWS(MonadWriter(..), RWS(..))
import Control.Monad.RWS hiding(join)
import Data.Monoid
import Data.Maybe
import IO
import qualified Data.Map as Map
import qualified Data.Set as Set

import Util.UniqueMonad
import Util.SetLike
import Grin.Grin hiding(V)
import Grin.Noodle
import Grin.Whiz
import StringTable.Atom
import Support.CanType
import Support.FreeVars
import Util.Gen
import Util.UnionSolve





data NodeType
    = WHNF       -- ^ guarenteed to be a WHNF
    | Lazy       -- ^ a suspension, a WHNF, or an indirection to a WHNF
    deriving(Eq,Ord,Show)


data N = N !NodeType (Topped (Set.Set Atom))
    deriving(Eq)

instance Show N where
    show (N nt ts) = show nt ++ "-" ++ f ts  where
        f Top = "[?]"
        f (Only x) = show (Set.toList x)

instance Fixable NodeType where
    isBottom x = x == WHNF
    isTop x = x == Lazy
    join x y = max x y
    meet x y = min x y
    eq = (==)
    lte x y = x <= y


instance Fixable N where
    isBottom (N a b) = isBottom a && isBottom b
    isTop (N a b) = isTop a && isTop b
    join  (N x y) (N x' y') = N (join x x') (join y y')
    meet  (N x y) (N x' y') = N (meet x x') (meet y y')
    lte   (N x y) (N x' y') = lte x x' && lte y y'


data V = V Va Ty | VIgnore
    deriving(Eq,Ord)

data Va =
    Vr !Var
    | Fa !Atom !Int
    | Fr !Atom !Int
    deriving(Eq,Ord)

vr v t = V (Vr v) t
fa n i t = V (Fa n i) t
fr n i t = V (Fr n i) t

class NodeLike a where
    isGood :: a -> Bool

instance NodeLike Ty where
    isGood TyNode = True
    isGood TyINode = True
    isGood _ = False

instance NodeLike Val where
    isGood v = isGood (getType v)

instance NodeLike V where
    isGood (V _ t) = isGood t
    isGood _ = False

instance NodeLike (Either V b) where
    isGood (Left n) = isGood n
    isGood _ = True

instance Show V where
    showsPrec _ (V (Vr v) ty) = shows (Var v ty)
    showsPrec _ (V (Fa a i) _) = shows (a,i)
    showsPrec _ (V (Fr a i) _) = shows (i,a)
    showsPrec _ VIgnore = showString "IGN"

newtype M a = M (RWS TyEnv (C N V) Int a)
    deriving(Monad,Functor,MonadWriter (C N V))

runM :: Grin -> M a -> C N V
runM grin (M w) = case runRWS w (grinTypeEnv grin) 1 of
    (_,_,w) -> w


{-# NOINLINE nodeAnalyze #-}
nodeAnalyze :: Grin -> IO Grin
nodeAnalyze grin' = do
    let cs = runM grin $ do
            mapM_ doFunc (grinFuncs grin)
            mapM_ docaf (grinCafs grin)
        grin = renameUniqueGrin grin'
        docaf (v,tt) | True = tell $ Right top `equals` Left (V (Vr v) TyINode)
                     | otherwise = return ()
    --putStrLn "----------------------------"
    --print cs
    --putStrLn "----------------------------"
    -- putStrLn "-- NodeAnalyze"
    (rm,res) <- solve (const (return ())) cs
    --(rm,res) <- solve putStrLn cs
    let cmap = Map.map (fromJust . flip Map.lookup res) rm
    --putStrLn "----------------------------"
    --mapM_ (\ (x,y) -> putStrLn $ show x ++ " -> " ++ show y) (Map.toList rm)
    --putStrLn "----------------------------"
    --mapM_ print (Map.elems res)
    --putStrLn "----------------------------"
    --hFlush stdout
    --exitWith ExitSuccess
    nfs <- mapM (fixupFunc (grinSuspFunctions grin `Set.union` grinPartFunctions grin) cmap) (grinFuncs grin)
    let grin' = setGrinFunctions nfs grin
    return $ grin' { grinTypeEnv = extendTyEnv (grinFunctions grin') (grinTypeEnv grin') }


data Todo = Todo !Bool [V] | TodoNothing

doFunc :: (Atom,Lam) -> M ()
doFunc (name,arg :-> body) = ans where
    ans = do
        let rts = getType body
        forMn_ rts $ \ (t,i) -> dVar (fr name i t) t
        forMn_ arg $ \ (~(Var v vt),i) -> do
            dVar (vr v vt) vt
            tell $ Left (fa name i vt) `equals` Left (vr v vt)
        fn (Todo True [ fr name i t | i <- naturals | t <- rts ]) body
    -- restrict values of TyNode type to be in WHNF
    dVar v TyNode = do
        tell $ Left v `islte` Right (N WHNF Top)
    dVar _ _ = return ()
    -- set concrete values for vars based on their type only
    -- should only be used in patterns
    zVar v TyNode = tell $ Left (vr v TyNode) `equals` Right (N WHNF Top)
    zVar v t = tell $ Left (vr v t) `equals` Right top
    fn ret body = f body where
        f (x :>>= [Var v vt] :-> rest) = do
            dVar (vr v vt) vt
            gn (Todo True [vr v vt]) x
            f rest
        f (x :>>= vs@(_:_:_) :-> rest) = do
            vs' <- forM vs $ \ (Var v vt) -> do
                dVar (vr v vt) vt
                return $ vr v vt
            gn (if all (== VIgnore) vs' then TodoNothing else Todo True vs') x
            f rest
        f (x :>>= v :-> rest) = do
            forM_ (Set.toList $ freeVars v) $ \ (v,vt) -> zVar v vt
            gn TodoNothing x
            f rest
        f body = gn ret body
    isfn _ x y | not (isGood x) = mempty
    isfn (Todo True  _) x y = Left x `equals` y
    isfn (Todo False _) x y = Left x `isgte` y
    isfn TodoNothing x y =  mempty
    equals x y | isGood x && isGood y = Util.UnionSolve.equals x y
               | otherwise = mempty
    isgte x y | isGood x && isGood y = Util.UnionSolve.isgte x y
              | otherwise = mempty
    islte x y | isGood x && isGood y = Util.UnionSolve.islte x y
              | otherwise = mempty
    gn ret head = f head where
        fl ret (v :-> body) = do
            forM_ (Set.toList $ freeVars v) $ \ (v,vt) -> zVar v vt
            fn ret body
        dunno ty = do
            dres [Right (if TyNode == t then N WHNF Top else top) | t <- ty ]
        dres res = do
            case ret of
                Todo b vs -> forM_ (zip vs res) $ \ (v,r) -> tell (isfn ret v r)
                _ -> return ()
        f (_ :>>= _) = error $ "Grin.NodeAnalyze: :>>="
        f (Case v as)
            | Todo _ n <- ret = mapM_ (fl (Todo False n)) as
            | TodoNothing <- ret = mapM_ (fl TodoNothing) as
        f (BaseOp Eval [x]) = do
            dres [Right (N WHNF Top)]
        f (BaseOp (Apply ty) xs) = do
            mapM_ convertVal xs
            dunno ty
        f (App { expFunction = fn, expArgs = vs, expType = ty }) = do
            vs' <- mapM convertVal vs
            forMn_ (zip vs vs') $ \ ((tv,v),i) -> when (isGood tv) $ do
                tell $ v `islte` Left (fa fn i (getType tv))
            dres [Left $ fr fn i t | i <- [ 0 .. ] | t <- ty ]
        f (Call { expValue = Item fn _, expArgs = vs, expType = ty }) = do
            vs' <- mapM convertVal vs
            forMn_ (zip vs vs') $ \ ((tv,v),i) -> when (isGood tv) $ do
                tell $ v `islte` Left (fa fn i (getType tv))
            dres [Left $ fr fn i t | i <- [ 0 .. ] | t <- ty ]
        f (Return x) = do
            ww' <- mapM convertVal x
            dres ww'
        f (BaseOp (StoreNode _) w) = do
            ww <- mapM convertVal w
            dres ww
        f (BaseOp Demote w) = do
            ww <- mapM convertVal w
            dres ww
--        f (Store w) = do
--            ww <- convertVal w
--            dunno [TyPtr (getType w)]
        f (BaseOp Promote [w]) = do
            ww <- convertVal w
            --dres [ww]
            dres [Right (N WHNF Top)]
        f (BaseOp Demote [w]) = do
            ww <- convertVal w
            --dres [ww]
            dres [Right (N WHNF Top)]
        f (BaseOp PeekVal [w])  = do
            dres [Right top]
        f Error {} = dres []
        f Prim { expArgs = as } = mapM_ convertVal as
        f Alloc { expValue = v } | getType v == TyNode = do
            v' <- convertVal v
            dres [v']
        f Alloc { expValue = v } | getType v == tyINode = do
            convertVal v
            dunno [TyPtr tyINode]
--            dres [v']
        f NewRegion { expLam = _ :-> body } = fn ret body
        f (BaseOp Overwrite [Var vname ty,v]) | ty == TyINode = do
            v' <- convertVal v
            tell $ Left (vr vname ty) `isgte` v'
            dres []
        f (BaseOp Overwrite vs) = do
            mapM_ convertVal vs
            dres []
        f (BaseOp PokeVal vs) = do
            mapM_ convertVal vs
            dres []
        f (BaseOp PeekVal vs) = do
            mapM_ convertVal vs
            dres []
--        f (Update (Var vname ty) v) | ty == TyINode  = do
--            v' <- convertVal v
--            tell $ Left (vr vname ty) `isgte` v'
--            dres []
--        f (Update (Var vname ty) v) | ty == TyPtr TyINode  = do
--            v' <- convertVal v
--            dres []
--        f (Update v1 v)  = do
--            v' <- convertVal v
--            v' <- convertVal v1
--            dres []
        f Let { expDefs = ds, expBody = e } = do
            mapM_ doFunc (map (\x -> (funcDefName x, funcDefBody x)) ds)
            fn ret e
        f exp = error $ "NodeAnalyze.f: " ++ show exp
--        f _ = dres []


    convertVal (Const (NodeC t _)) = return $ Right (N WHNF (Only $ Set.singleton t))
    convertVal (Const _) = return $ Right (N WHNF Top)
    convertVal (NodeC t vs) = case tagUnfunction t of
        Nothing -> return $ Right (N WHNF (Only $ Set.singleton t))
        Just (n,fn) -> do
            vs' <- mapM convertVal vs
            forMn_ (zip vs vs') $ \ ((vt,v),i) -> do
                tell $ v `islte` Left (fa fn i (getType vt))
            forM_ [0 .. n - 1 ] $ \i -> do
               tell $ Right top `islte` Left (fa fn (length vs + i) TyINode)
            return $ Right (N (if n == 0 then Lazy else WHNF) (Only $ Set.singleton t))
    convertVal (Var v t) = return $ Left (vr v t)
    convertVal v | isGood v = return $ Right (N Lazy Top)
    convertVal Lit {} = return $ Left VIgnore
    convertVal ValPrim {} = return $ Left VIgnore
    convertVal Index {} = return $ Left VIgnore
    convertVal Item {} = return $ Left VIgnore
    convertVal ValUnknown {} = return $ Left VIgnore
    convertVal v = error $ "convertVal " ++ show v

--bottom = N WHNF (Only (Set.empty))
top = N Lazy Top

--data WhatToDo
--    = WhatDelete
--    | WhatNothing
--    | WhatSubs (Var -> Exp) (Var -> Exp)


--type TFunc = [()]

--transformFuncs :: (Atom -> (TFunc,TFunc)) -> Grin -> Grin



fixupFunc sfuncs cmap (name,l :-> body) = fmap (\b -> (name, l' :-> b)) (f body >>= g fixups') where
    (l',fixups') | name `Set.member` sfuncs = (l,[])
                 | otherwise = ((map f $ zip l ll),fixups) where
        ll = map lupVar l
        fixups = [ v | (v@(Var _ TyINode),Just (N WHNF _)) <- zip l ll]
        f (Var v _,Just (N WHNF _)) = Var v TyNode
        f (v,_) = v

    lupVar (Var v t) =  case Map.lookup (vr v t) cmap of
        _ | v < v0 -> fail "nocafyet"
        Just (ResultJust _ lb) -> return lb
        Just ResultBounded { resultLB = Just lb } -> return lb
        _ -> fail "lupVar"
    lupArg a (x,i) =  case Map.lookup (fa a i (getType x)) cmap of
        Just (ResultJust _ lb) -> return lb
        Just ResultBounded { resultLB = Just lb } -> return lb
        _ -> fail "lupArg"
    g [] e = return e
    g (Var v TyINode:xs) e = do e' <- g xs e ; return $ BaseOp Demote [Var v TyNode] :>>= [Var v TyINode] :-> e'
    f (App a xs ts)  | a `Set.notMember` sfuncs, not $ null mvars = return res where
        largs = map (lupArg a) (zip xs [0 ..  ])
        largs' =  [ (Var v (getType x),la) | (x,v,la) <- zip3 xs [ v1 .. ] largs ]
        mvars = [ (Var v TyINode) | (Var v TyINode,Just (N WHNF _)) <- largs' ]
        mvars' = [ case (v,la) of (Var v' TyINode,Just (N WHNF _)) -> Var v' TyNode ; _ -> v  | (v,la) <- largs' ]
        res = Return xs :>>= fsts largs' :-> f mvars (App a mvars' ts)
        f (Var v TyINode:rs) e = BaseOp Promote [Var v TyINode] :>>= [Var v TyNode] :-> f rs e
        f [] e = e
    f Let { expDefs = ds, expBody = e } = do
        ds' <- forM ds $ \d -> do
            (_,l) <- fixupFunc sfuncs cmap (funcDefName d, funcDefBody d)
            return $ updateFuncDefProps  d { funcDefBody = l }
        e' <- f e
        return $ grinLet ds' e'

    f a@(BaseOp Eval [arg]) | Just n <- lupVar arg = case n of
        N WHNF _ -> return (BaseOp Promote [arg])
        _ -> return a
    f e = mapExpExp f e

renameUniqueGrin :: Grin -> Grin
renameUniqueGrin grin = res where
    (res,()) = evalRWS (execUniqT 1 ans) ( mempty :: Map.Map Atom Atom) (fromList [ x | (x,_) <- grinFuncs grin ] :: Set.Set Atom)
    ans = do mapGrinFuncsM f grin
    f (l :-> b) = g b >>= return . (l :->)
    g a@App  { expFunction = fn } = do
        m <- lift ask
        case mlookup fn m of
            Just fn' -> return a { expFunction = fn' }
            _ -> return a
    g a@Call { expValue = Item fn t } = do
        m <- lift ask
        case mlookup fn m of
            Just fn' -> return a { expValue = Item fn' t }
            _ -> return a
    g (e@Let { expDefs = defs }) = do
        (defs',rs) <- liftM unzip $ flip mapM defs $ \d -> do
            (nn,rs) <- newName (funcDefName d)
            return (d { funcDefName = nn },rs)
        local (fromList rs `mappend`) $  mapExpExp g e { expDefs = defs' }
    g b = mapExpExp g b
    newName a = do
        m <- lift get
        case member a m of
            False -> do lift $ modify (insert a); return (a,(a,a))
            True -> do
            let cfname = do
                uniq <- newUniq
                let fname = toAtom $ show a  ++ "-" ++ show uniq
                if fname `member` (m :: Set.Set Atom) then cfname else return fname
            nn <- cfname
            lift $ modify (insert nn)
            return (nn,(a,nn))

mapGrinFuncsM :: Monad m => (Lam -> m Lam) -> Grin -> m Grin
mapGrinFuncsM f grin = liftM (`setGrinFunctions` grin) $ mapM  (\x -> do nb <- f (funcDefBody x); return (funcDefName x, nb)) (grinFunctions grin)
