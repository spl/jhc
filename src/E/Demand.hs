module E.Demand(
    Demand(..),
    DemandSignature(..),
    DemandType(..),
    SubDemand(..),
    analyzeProgram,
    absSig,
    lazy
    ) where

import Control.Monad.Reader
import Control.Monad.Writer hiding(Product(..))
import Data.Binary
import Data.List hiding(union,delete)
import Data.Typeable

--import Debug.Trace
import DataConstructors
import Doc.DocLike
import Doc.PPrint
import E.E
import E.Program
import GenUtil
import Info.Types
import Name.Id
import Util.HasSize
import Util.SetLike
import qualified Info.Info as Info

trace _ x = x

data Demand =
    Bottom             -- always diverges
    | L !SubDemand      -- lazy
    | S !SubDemand      -- strict
    | Error !SubDemand  -- diverges, might use arguments
    | Absent           -- Not used
    deriving(Eq,Ord,Typeable)
        {-! derive: Binary !-}

data SubDemand = None | Product ![Demand]
    deriving(Eq,Ord)
        {-! derive: Binary !-}

data DemandEnv = DemandEnv !(IdMap Demand) !Demand
    deriving(Eq,Ord)
        {-! derive: Binary !-}

data DemandType = (:=>) !DemandEnv ![Demand]
    deriving(Eq,Ord)
        {-! derive: Binary !-}

data DemandSignature = DemandSignature {-# UNPACK #-} !Int !DemandType
    deriving(Eq,Ord,Typeable)
        {-! derive: Binary !-}

idGlb = Absent

absType = (DemandEnv mempty idGlb) :=> []
--botType = (DemandEnv mempty Bottom) :=> []
botType = (DemandEnv mempty Bottom) :=> []

--lazyType = (DemandEnv mempty lazy) :=> []
--lazySig = DemandSignature 0 lazyType
absSig = DemandSignature 0 absType

class Lattice a where
    glb :: a -> a -> a
    lub :: a -> a -> a

-- Sp [L .. L] = S
-- Sp [.. _|_ ..] = _|_

sp [] = S None
sp xs = S (allLazy xs) -- None

l None = L None
l (Product xs) = lp xs

s None = S None
s (Product xs) = sp xs

allLazy xs | all (== lazy) xs = None
allLazy xs = Product xs

lp [] = L None
lp xs = L (allLazy (map f xs)) where
    f (S None) = lazy
    f (S (Product ys)) = lp ys
    f Bottom = Absent
    f (Error None) = lazy
    f (Error (Product xs)) = lp xs
    f x = x

{-
sp s = sp' True s where
    sp' True [] = S None
    sp' False [] = S (Product s)
    sp' allLazy (L _:rs) = sp' allLazy rs
    sp' _ (Bottom:_) = Error (Product s)
    sp' _ (_:rs) = sp' False rs
-}

instance Lattice DemandType where
    lub (env :=> ts) (env' :=> ts') | length ts < length ts' = (env `lub` env') :=> strictList (zipWith lub (ts ++ repeat lazy) ts')
                                    | otherwise = (env `lub` env') :=> strictList (zipWith lub ts (ts' ++ repeat lazy))
    glb (env :=> ts) (env' :=> ts') | length ts < length ts' = (env `glb` env') :=> strictList (zipWith glb (ts ++ repeat lazy) ts')
                                    | otherwise = (env `glb` env') :=> strictList (zipWith glb ts (ts' ++ repeat lazy))

lazy = L None
strict = S None
err = Error None

strictList (x:xs) = x `seq` xs' `seq` (x:xs') where
    xs' = strictList xs
strictList [] = []

comb _ None None = None
comb f None (Product xs) = Product $ zipWith f (repeat lazy) xs
comb f (Product xs) None = Product $ zipWith f xs (repeat lazy)
comb f (Product xs) (Product ys) = Product $ zipWith f xs ys

instance Lattice Demand where
    lub Bottom s = s
    lub s Bottom = s
    lub Absent Absent = Absent
    lub (S x) Absent = l x
    lub Absent (S x) = l x
    lub (L x) Absent = l x
    lub Absent (L x) = l x
    lub Absent sa = lazy
    lub sa Absent = lazy

    lub (S x) (S y) = s (comb lub x y)
    lub (L x) (L y) = l (comb lub x y)
    lub (Error x) (Error y) = Error (comb lub x y)

    lub (S x) (L y) = l (comb lub x y)
    lub (L x) (S y) = l (comb lub x y)

    lub (S x) (Error y) = s (comb lub x y)
    lub (Error x) (S y) = s (comb lub x y)

    lub (L x) (Error y) = lazy
    lub (Error x) (L y) = lazy

    glb Bottom Bottom = Bottom
    glb Absent sa = sa
    glb sa Absent = sa

    glb Bottom _ = err
    glb _ Bottom = err

    glb (S x) (S y) = s (comb glb x y)
    glb (L x) (L y) = l (comb glb x y)
    glb (Error x) (Error y) = Error (comb glb x y)

    glb (S _) (Error _) = err
    glb (Error _) (S _) = err

    glb (S x) (L y) = s (comb glb x y)
    glb (L x) (S y) = s (comb glb x y)

    glb (L _) (Error _) = err
    glb (Error _) (L _) = err

lenv e (DemandEnv m r) = case mlookup e m of
    Nothing -> r
    Just x -> x

demandEnvSingleton :: TVr -> Demand -> DemandEnv
demandEnvSingleton _ Absent = DemandEnv mempty idGlb
demandEnvSingleton t d = DemandEnv (msingleton (tvrIdent t) d) idGlb

demandEnvMinus :: DemandEnv -> TVr -> DemandEnv
demandEnvMinus (DemandEnv m r) x = DemandEnv (delete (tvrIdent x) m) r

instance Lattice DemandEnv where
    lub d1@(DemandEnv m1 r1) d2@(DemandEnv m2 r2) = DemandEnv m (r1 `lub` r2) where
        m = fromList [ (x,lenv x d1 `lub` lenv x d2) | x <- keys (m1 `union` m2)]
    glb d1@(DemandEnv m1 r1) d2@(DemandEnv m2 r2) = DemandEnv m (r1 `glb` r2) where
        m = fromList [ (x,lenv x d1 `glb` lenv x d2) | x <- keys (m1 `union` m2)]

newtype IM a = IM (Reader (Env,DataTable) a)
    deriving(Monad,Functor,MonadReader (Env,DataTable))

type Env = IdMap (Either DemandSignature E)

getEnv :: IM Env
getEnv = asks fst

extEnv TVr { tvrIdent = i } _ | isEmptyId i = id
extEnv t e = local (\ (env,dt) -> (minsert (tvrIdent t) (Left e) env,dt))

extEnvE TVr { tvrIdent = i } _ | isEmptyId i = id
extEnvE t e = local (\ (env,dt) -> (minsert (tvrIdent t) (Right e) env,dt))

instance DataTableMonad IM where
    getDataTable = asks snd

runIM :: Monad m => IM a -> DataTable ->  m a
runIM (IM im) dt = return $ runReader im (mempty,dt)

-- returns the demand type and whether it was found in the local environment or guessed
determineDemandType :: TVr -> Demand -> IM (Either DemandType E)
determineDemandType tvr demand = do
    let g (DemandSignature n dt@(DemandEnv phi _ :=> _)) = f n demand where
            f 0 (S _) = dt
            f n (S (Product [s])) = f (n - 1) s
            f _ _ = lazify (DemandEnv phi Absent) :=> []
    env <- getEnv
    case mlookup (tvrIdent tvr) env of
        Just (Left ds) -> return (Left $ g ds)
        Just (Right e) -> return (Right e)
        Nothing -> case Info.lookup (tvrInfo tvr) of
            Nothing -> return (Left absType)
            Just ds -> return (Left $ g ds)

extendSig (DemandSignature n1 t1) (DemandSignature n2 t2)  = DemandSignature (max n1 n2) (glb t1 t2)

splitSigma [] = (lazy,[])
splitSigma (x:xs) = (x,xs)

analyze :: E -> Demand -> IM (E,DemandType)
analyze e Absent = return (e,absType)
analyze (EVar v) s = do
    ddt <- determineDemandType v s
    (phi :=> sigma) <- case ddt of
        Left dt -> return dt
        Right e -> liftM snd $ analyze e s
    return (EVar v,(phi `glb` (demandEnvSingleton v s)) :=> sigma)
analyze (EAp e1 e2) s = do
    (e1',phi1 :=> sigma1') <- analyze e1 (sp [s])
    let (sa,sigma1) = splitSigma sigma1'
    (e2',phi2 :=> sigma2) <- analyze e2 sa
    return $ (EAp e1' e2',(phi1 `glb` phi2) :=> sigma1)
analyze el@(ELit lc@LitCons { litName = h, litArgs = ts@(_:_) }) (S (Product ss)) | length ss == length ts = do
    dataTable <- getDataTable
    case onlyChild dataTable h of
        True -> do  -- product type
            envs <- flip mapM (zip ts ss) $ \(a,s) -> do
                (_,env :=> _) <- analyze a s
                return env
            return (el,foldr1 glb envs :=> [])
        _ -> do
            rts <- mapM (\e -> analyze e lazy) ts
            return (ELit lc { litArgs = fsts rts }, foldr glb absType (snds rts))

analyze (ELit lc@LitCons { litArgs = ts }) _s = do
    rts <- mapM (\e -> analyze e lazy) ts
    return (ELit lc { litArgs = fsts rts }, foldr glb absType (snds rts))
analyze e s | Just (t1,t2,pt) <- from_dependingOn e = do
    (t1',dt1) <- analyze t1 s
    (t2',dt2) <- analyze t2 lazy
    return (EPrim p_dependingOn [t1',t2'] pt,dt1 `glb` dt2)
analyze (EPrim ap ts pt) _s = do
    rts <- mapM (\e -> analyze e lazy) ts
    return (EPrim ap (fsts rts) pt, foldr glb absType (snds rts))
analyze (EPi tvr@TVr { tvrType = t1 } t2)  _s = do
    (t1',dt1) <- analyze t1 lazy
    (t2',dt2) <- analyze t2 lazy
    return (EPi tvr { tvrType = t1' } t2',dt1 `glb` dt2)

analyze (ELam x@TVr { tvrIdent = eid } e) (S (Product [s])) | eid == emptyId = do
    (e',phi :=> sigma) <- analyze e s
    let sx = Absent
    return (ELam (tvrInfo_u (Info.insert $! sx) x) e',demandEnvMinus phi x :=> (sx:sigma))
analyze (ELam x e) (S (Product [s])) = do
    (e',phi :=> sigma) <- analyze e s
    let sx = lenv (tvrIdent x) phi
    return (ELam (tvrInfo_u (Info.insert $! sx) x) e',demandEnvMinus phi x :=> (sx:sigma))

analyze (ELam x e) (L (Product [s])) = do
    (e',phi :=> sigma) <- analyze e s
    let sx = lenv (tvrIdent x) phi
    return (ELam (tvrInfo_u (Info.insert $! sx) x) e',lazify (demandEnvMinus phi x) :=> (sx:sigma))
analyze (ELam x e) (S None) = analyze (ELam x e) (S (Product [lazy]))  -- simply to ensure binder is annotated
analyze (ELam x e) (L None) = analyze (ELam x e) (L (Product [lazy]))  -- simply to ensure binder is annotated
analyze (ELam x e) (Error None) = analyze (ELam x e) (Error (Product [lazy]))  -- simply to ensure binder is annotated
analyze e@EError {} (S _) = return (e,botType)
analyze e@EError {} (L _) = return (e,absType)
analyze ec@ECase { eCaseBind = b, eCaseAlts = [Alt lc@LitCons { litName = h, litArgs = ts } alt], eCaseDefault = Nothing } s = do
    dataTable <- getDataTable
    case onlyChild dataTable h of
        True -> do  -- product type
            (alt',enva :=> siga) <- extEnvE b (eCaseScrutinee ec) $ analyze alt s
            (e',enve :=> []) <- analyze (eCaseScrutinee ec) (sp [ lenv (tvrIdent t) enva | t <- ts])
            let nenv = enve `glb` foldr denvDelete enva (b:ts)
            return (caseUpdate $ ec { eCaseScrutinee = e', eCaseAlts = [Alt lc alt'] }, nenv :=> siga)
        _ -> analyzeCase ec s
analyze ec@ECase {} s = analyzeCase ec s
analyze ELetRec { eDefs = ds, eBody = b } s = f (decomposeDs ds) [] where
    f [] ds' = do
        (b',phi :=> sig) <- analyze b s
        let g (t,e) = (tvrInfo_u (Info.insert $! (lenv (tvrIdent t) phi)) t,e)
        return (ELetRec (map g ds') b', foldr denvDelete phi (fsts ds) :=> sig)
    f (Left (t,e):rs) fs =
        solveDs' (Just False) [(t,e)] fixupDemandSignature (\nn -> f rs (nn ++ fs))
    f (Right rg:rs) fs = do
        solveDs' (Just True) rg fixupDemandSignature (\nn -> f rs (nn ++ fs))
analyze Unknown _ = return (Unknown,absType)
analyze es@ESort {} _ = return (es,absType)
analyze es@(ELit LitInt {}) _ = return (es,absType)
analyze e x = fail $ "analyze: " ++ show (e,x)

from_dependingOn (EPrim don [t1,t2] pt) | don == p_dependingOn = return (t1,t2,pt)
from_dependingOn _ = fail "not dependingOn"

lazify (DemandEnv x r) = DemandEnv (fmap f x) Absent where
    f (S xs) = l xs
    f Absent = Absent
    f (L xs) = l xs
    f Bottom = Absent
    f (Error xs) = l xs

analyzeCase ec s = do
    (ec',dts) <- extEnvE (eCaseBind ec) (eCaseScrutinee ec) $ runWriterT $ flip caseBodiesMapM ec $ \e -> do
        (ne,dt) <- lift $ analyze e s
        tell [dt]
        return ne
    (ecs,env :=> _) <- analyze (eCaseScrutinee ec') strict
    let enva :=> siga =  foldr1 lub dts
    let nenv = foldr denvDelete (glb enva env) (caseBinds ec')
    return (caseUpdate $ ec' {eCaseScrutinee = ecs},nenv :=> siga)

denvDelete x (DemandEnv m r) = DemandEnv (delete (tvrIdent x) m) r

topAnalyze :: TVr -> E -> IM (E,DemandSignature)
topAnalyze tvr e | getProperty prop_PLACEHOLDER tvr = return (e,DemandSignature 0 absType)
topAnalyze _tvr e = clam e strict 0 where
    clam (ELam _ x) s n = clam x (sp [s]) (n + 1)
    clam _ s n = do
        (e,dt) <- analyze e s
        return (e,DemandSignature n dt)

fixupDemandSignature (DemandSignature n (DemandEnv _ r :=> dt)) = DemandSignature n (DemandEnv mempty r :=> dt)

shouldBind ELit {} = True
shouldBind EVar {} = True
shouldBind EPi {} = True
shouldBind _ = False

solveDs' :: (Maybe Bool) -> [(TVr,E)] -> (DemandSignature -> DemandSignature) -> ([(TVr,E)] -> IM a) -> IM a
solveDs' Nothing ds fixup wdone = do
    let f (Left d:rs) xs = solveDs' (Just False) [d] fixup (\nds -> f rs (nds ++ xs))
        f (Right ds:rs) xs = solveDs' (Just True) ds fixup (\nds -> f rs (nds ++ xs))
        f [] xs = wdone xs
    f (decomposeDs ds) []
solveDs' (Just False) [(t,e)] fixup wdone | shouldBind e = do
    (ne,ds) <- topAnalyze t e
    extEnvE t e $ wdone [(tvrInfo_u (Info.insert (fixup ds)) t,ne)]
solveDs' (Just False) [(t,e)] fixup wdone = do
    (ne,ds) <- topAnalyze t e
    extEnv t ds $ wdone [(tvrInfo_u (Info.insert (fixup ds)) t,ne)]
--solveDs' (Just False) ds fixup wdone = solveDs' Nothing ds fixup wdone
solveDs' (Just False) ds fixup wdone = error "solveDs' (Just False) called with more than one definition"
solveDs' (Just True) ds fixup wdone = trace "solveDs': jt" $ do
    let ds' = [ ((t,e),sig) | (t,e) <- ds, let sig = maybe absSig id (Info.lookup (tvrInfo t))]
        g 0 _ [] ds = trace "gdonetout" $ wdone [ (tvrInfo_u (Info.insert $! (fixup sig)) t,e) | ((t,e),sig) <- ds ]
        g _ False [] ds = trace "gdone1" $ wdone [ (tvrInfo_u (Info.insert $! (fixup sig)) t,e) | ((t,e),sig) <- ds ]
        g n True [] ds = do
            (oe,dt) <- ask
            let nenv = fromList [ (tvrIdent t,Left s) |  ((t,_),s) <- ds, not (isEmptyId (tvrIdent t))] `Util.SetLike.union` oe
            local (const (nenv,dt)) $ trace ("grepeating: " ++ show (length ds)) $ g (n - 1) False ds []
        g n ch (((t,e),sig):rs) fs = do
            (ne,sig') <- topAnalyze t e
            let sig'' = sig `extendSig` sig'
            --(if sig'' /= sig then trace ("signe: " ++ show(tvrIdent t,sig)) else id) $
            g n (ch || (sig'' /= sig)) rs (((t,ne),sig''):fs)
    g (5::Int) True [] ds'

{-# NOINLINE analyzeProgram #-}
analyzeProgram prog = do
    let ds = programDs prog
    nds <- runIM (solveDs' Nothing ds fixupDemandSignature return) (progDataTable prog)
    --flip mapM_ nds $ \ (t,_) ->
    --    putStrLn $ "strictness: " ++ pprint t ++ ": " ++ show (maybe absSig id $ Info.lookup (tvrInfo t))
    return $ programSetDs' nds prog

----------------------------
-- show and pprint instances
----------------------------

instance Show Demand where
    showsPrec _ Bottom = ("_|_" ++)
    showsPrec _ Absent = ('A':)
    showsPrec _ (L None) = ('L':)
    showsPrec _ (L (Product ds)) = showString "L(" . foldr (.) id (map shows ds) . showString ")"
    showsPrec _ (S None) = ('S':)
    showsPrec _ (S (Product ds)) = showString "S(" . foldr (.) id (map shows ds) . showString ")"
    showsPrec _ (Error None) = showString "Err"
    showsPrec _ (Error (Product ds)) = showString "Err(" . foldr (.) id (map shows ds) . showString ")"

instance DocLike d => PPrint d Demand where
    pprint demand = tshow demand

instance Show DemandType where
    showsPrec _ (DemandEnv e Absent :=> d) | isEmpty e = shows d
    showsPrec _ (env :=> ds) = shows env . showString " :=> " .  shows ds

instance Show DemandEnv where
    showsPrec _ (DemandEnv m Absent) = showString "{" . foldr (.) id (intersperse (showString ",") [ showString (pprint t) . showString " -> " . shows v | (t,v) <- idMapToList m]) . showString "}"
    showsPrec _ (DemandEnv _ Bottom) = showString "_|_"
    showsPrec _ (DemandEnv m demand) = showString "{" . shows demand . showString " - " . foldr (.) id (intersperse (showString ",") [ showString (pprint t) . showString " -> " . shows v | (t,v) <- idMapToList m]) . showString "}"

instance Show DemandSignature where
    showsPrec _ (DemandSignature n dt) = showString "<" . shows n . showString "," . shows dt . showString ">"
