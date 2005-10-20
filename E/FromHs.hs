module E.FromHs(matchesConv,altConv,guardConv,convertDecls,getMainFunction,createMethods,createInstanceRules,theMainName,deNewtype,methodNames) where

import Control.Monad.Identity
import Control.Monad.State
import Data.FunctorM
import Data.Generics
import List(isPrefixOf)
import Prelude hiding((&&),(||),not,and,or,any,all)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Text.PrettyPrint.HughesPJ as PPrint

import Atom
import Boolean.Algebra
import CanType
import Char
import Class
import C.Prims
import DataConstructors
import Doc.DocLike
import Doc.PPrint
import E.E
import E.Rules
import E.Subst
import E.Traverse
import E.TypeCheck
import E.Values
import FreeVars
import GenUtil
import HsSyn
import Info.Types
import Name
import NameMonad
import Options
import qualified FlagOpts as FO
import qualified Util.Seq as Seq
import Representation
import Utils
import VConsts

localVars = [10,12..]
theMainName = toName Name.Val (UnQual $ HsIdent "theMain")
ump sl e = EError  (srcLocShow sl ++ ": Unmatched pattern") e
srcLocShow sl = concat [srcLocFileName sl, ":",show $ srcLocLine sl,":", show $ srcLocColumn sl ]
nameToInt n = atomIndex $ toAtom n


--newVars :: MonadState Int m => [E] -> m [TVr]
newVars xs = f xs [] where
    f [] xs = return $ reverse xs
    f (x:xs) ys = do
        s <- get
        put $! s + 2
        f xs (tVr ( s) x:ys)

lt n =  atomIndex $ toAtom $ toName TypeVal n

tipe (TAp t1 t2) = eAp (tipe t1) (tipe t2)
tipe (TArrow t1 t2) =  EPi (tVr 0 (tipe t1)) (tipe t2)
tipe (TCon (Tycon n k)) =  ELit (LitCons (toName TypeConstructor n) [] (kind k))
tipe (TVar (Tyvar _ n k _)) = EVar (tVr (lt n) (kind k))
tipe (TGen _ (Tyvar _ n k _)) = EVar (tVr (lt n) (kind k))

kind Star = eStar
kind (Kfun k1 k2) = EPi (tVr 0 (kind k1)) (kind k2)
kind (KVar _) = error "Kind variable still existing."


simplifyDecl (HsPatBind sl (HsPVar n)  rhs wh) = HsFunBind [HsMatch sl n [] rhs wh]
simplifyDecl x = x

simplifyHsPat (HsPInfixApp p1 n p2) = HsPApp n [simplifyHsPat p1, simplifyHsPat p2]
simplifyHsPat (HsPParen p) = simplifyHsPat p
simplifyHsPat (HsPTuple ps) = HsPApp (toTuple (length ps)) (map simplifyHsPat ps)
simplifyHsPat (HsPNeg p)
    | HsPLit (HsInt i) <- p' = HsPLit $ HsInt (negate i)
    | HsPLit (HsFrac i) <- p' = HsPLit $ HsFrac (negate i)
    | otherwise = HsPNeg p'
    where p' = (simplifyHsPat p)
simplifyHsPat (HsPLit (HsString s)) = simplifyHsPat (HsPList (map f s)) where
    f c = HsPLit (HsChar c)
simplifyHsPat (HsPAsPat n p) = HsPAsPat n (simplifyHsPat p)
simplifyHsPat (HsPTypeSig _ p _) = simplifyHsPat p
simplifyHsPat (HsPList ps) = pl ps where
    pl [] = HsPApp (Qual prelude_mod (HsIdent "[]")) []
    pl (p:xs) = HsPApp (Qual prelude_mod (HsIdent ":")) [simplifyHsPat p, pl xs]
simplifyHsPat (HsPApp n xs) = HsPApp n (map simplifyHsPat xs)
simplifyHsPat (HsPIrrPat p) = simplifyHsPat p -- TODO irrefutable patterns!
simplifyHsPat p@HsPVar {} = p
simplifyHsPat p@HsPLit {} = p
simplifyHsPat p = error $ "simplifyHsPat: " ++ show p

convertVal assumps n = (mp EPi ts (tipe t), mp eLam ts) where
    Just (Forall _ (_ :=> t)) = Map.lookup n assumps -- getAssump n
    mp fn (((Tyvar _ n k _)):rs) t = fn (tVr (lt n) (kind k)) (mp fn rs t)
    mp _ [] t = t
    ts = ctgen t
    lt n =  nameToInt (fromTypishHsName  n)

convertOneVal (Forall _ (_ :=> t)) = (mp EPi ts (tipe t)) where
    mp fn (((Tyvar _ n k _)):rs) t = fn (tVr (lt n) (kind k)) (mp fn rs t)
    mp _ [] t = t
    ts = ctgen t
    lt n =  nameToInt (fromTypishHsName  n)

Identity nameFuncNames = fmapM (return . toName Val) sFuncNames
toTVr assumps n = tVr ( nameToInt n) (typeOfName n) where
    typeOfName n = fst $ convertVal assumps n

matchesConv ms = map v ms where
    v (HsMatch _ _ ps rhs wh) = (map simplifyHsPat ps,rhs,wh)

altConv as = map v as where
    v (HsAlt _ p rhs wh) = ([simplifyHsPat p],guardConv rhs,wh)

guardConv (HsUnGuardedAlt e) = HsUnGuardedRhs e
guardConv (HsGuardedAlts gs) = HsGuardedRhss (map (\(HsGuardedAlt s e1 e2) -> HsGuardedRhs s e1 e2) gs)

argTypes e = span ((== eBox) . getType) (map tvrType xs) where
    (_,xs) = fromPi e
argTypes' :: E -> ([E],E)
argTypes' e = let (x,y) = fromPi e in (map tvrType y,x)


getMainFunction :: Monad m => Name -> (Map.Map Name (TVr,E)) -> m (Name,TVr,E)
getMainFunction name ds = ans where
    ans = do
        main <- findName name
        runMain <- findName (func_runMain nameFuncNames)
        runExpr <- findName (func_runExpr nameFuncNames)
        let e | not (fopts FO.Wrapper) = maine
              | otherwise = case ioLike (getType maine) of
                Just x ->  EAp (EAp (EVar runMain)  x ) maine
                Nothing ->  EAp (EAp (EVar runExpr) ty) maine
            theMain = (theMainName,theMainTvr,e)
            theMainTvr =  tVr (nameToInt theMainName) (getType e)
            tvm@(TVr { tvrType =  ty}) =  main
            maine = foldl EAp (EVar tvm) [ tAbsurd k |  TVr { tvrType = k } <- xs ]
            (ty',xs) = fromPi ty
        return theMain
    ioLike ty = case smplE ty of
        ELit (LitCons n [x] _) -> if show n ==  "Jhc.IO.IO" then Just x else Nothing
        _ -> Nothing
    smplE = id

        {-
    lco = ELetRec [ (_,x,y) hoEs ds]
    main = toTVr (hoAssumps ho) (parseName Val wt)
    -}
    --nameMap = Map.fromList [ (n,t) |  (n,t,_) <- ds]
    findName name = case Map.lookup name ds of
        Nothing -> fail $ "Cannot find: " ++ show name
        Just (n,_) -> return n

createInstanceRules :: Monad m => ClassHierarchy -> (Map.Map Name (TVr,E)) -> m Rules
createInstanceRules classHierarchy funcs = return $ fromRules ans where
    ans = concatMap cClass (classRecords classHierarchy)
    --cClass ClassRecord { className = name, classInsts = is, classAssumps = as } =  concat [ method n | n :>: _ <- as ]
    cClass classRecord =  concat [ method classRecord n | n :>: Forall _ (_ :=> t) <- classAssumps classRecord ]

    method classRecord n = as where
        methodVar = tVr ( nameToInt methodName) ty
        methodName = toName Name.Val n
        Identity (deftvr@(TVr { tvrType = ty}),_) = findName defaultName
        defaultName =  (toName Name.Val (defaultInstanceName n))
        valToPat' (ELit (LitCons x ts t)) = ELit $ LitCons x [ EVar (tVr ( j) (getType z)) | z <- ts | j <- [2,4 ..]]  t
        valToPat' (EPi (TVr { tvrType =  a}) b)  = ELit $ LitCons tArrow [ EVar (tVr ( j) (getType z)) | z <- [a,b] | j <- [2,4 ..]]  eStar
        valToPat' x = error $ "FromHs.valToPat': " ++ show x
        as = [ rule  t | (_ :=> IsIn _ t ) <- snub (classInsts classRecord) ]
        rule t = emptyRule { ruleHead = methodVar, ruleArgs = [valToPat' (tipe t)], ruleBody = body, ruleName = toAtom $ "Rule.{" ++ show name ++ "}"}  where
            name = (toName Name.Val (instanceName n (getTypeCons t)))
            ELit (LitCons _ vs _) = valToPat' (tipe t)
            body = case findName name of Just (n,_) -> foldl EAp (EVar n) vs  ; Nothing -> EAp (EVar deftvr) (valToPat' (tipe t))
    findName name = case Map.lookup name funcs of
        Nothing -> fail $ "Cannot find: " ++ show name
        Just n -> return n

createMethods :: Monad m => DataTable -> ClassHierarchy -> (Map.Map Name (TVr,E))  -> m [(Name,TVr,E)]
createMethods dataTable classHierarchy funcs = return ans where
    ans = concatMap cClass (classRecords classHierarchy)
    cClass classRecord =  [ method classRecord n | n :>: _ <- classAssumps classRecord ]
    method classRecord n = (methodName ,setProperty prop_METHOD (tVr ( nameToInt methodName) ty),v) where
        methodName = toName Name.Val n
        Just (deftvr@(TVr { tvrType = ty}),defe) = findName (toName Name.Val (defaultInstanceName n))
        (EPi tvr t) = ty
        --els = eAp (EVar deftvr) (EVar tvr)
        els = EError ("Bad: " ++ show methodName) t -- eAp (EVar deftvr) (EVar tvr)
        v = eLam tvr (eCase (EVar tvr) as els)
        as = concatMap cinst [ t | (_ :=> IsIn _ t ) <- classInsts classRecord]
        cinst t | Nothing <- getConstructor x dataTable = fail "skip un-imported primitives"
                | Just (tvr,_) <- findName name = return $ calt (foldl EAp (EVar tvr) vs)
                | EError "Bad" _ <- defe = return $ calt $  EError ( show n ++ ": undefined at type " ++  PPrint.render (pprint  t) ) (getType els)
                | otherwise = return $ calt $ ELetRec [(tvr,tipe t)] (EAp (EVar deftvr) (EVar tvr))
                | ELam x e <- defe, not (isAtomic (tipe t)) = return $ calt $ substLet [(x,tipe t)] e
                | ELam x e <- defe, isAtomic (tipe t) = return $ calt $ subst x (tipe t) e -- [(x,tipe t)] e
                | not (isAtomic (tipe t)) = return $ calt $  (EAp (EVar deftvr) (EVar tvr))
                | otherwise = return $ calt $ EAp (EVar deftvr) (tipe t) where -- fail "Instance does not exist" where
            name = toName Name.Val (instanceName n (getTypeCons t))
            -- calt  tvr =  Alt (LitCons x [ tvr | ~(EVar tvr) <- vs ]  ct) (foldl EAp (EVar tvr) vs)
            calt e =  Alt (LitCons x [ tvr | ~(EVar tvr) <- vs ]  ct)  e
            (x,vs,ct) = case tipe t of
                (ELit (LitCons x' vs' ct')) -> (x',vs',ct')
                (EPi (TVr { tvrType = a}) b) -> (tArrow,[a,b],eStar)
                e -> error $ "FromHs.createMethods: " ++ show e
    findName name = case Map.lookup name funcs of
        Nothing -> fail $ "Cannot find: " ++ show name
        Just n -> return n

methodNames ::  ClassHierarchy ->  [TVr]
methodNames  classHierarchy =  ans where
    ans = concatMap cClass (classRecords classHierarchy)
    cClass classRecord =  [ setProperty prop_METHOD $ tVr (nameToInt $ toName Name.Val n) (convertOneVal t) | n :>: t <- classAssumps classRecord ]

unbox :: DataTable -> E -> Int -> (TVr -> E) -> E
unbox dataTable e vn wtd = ECase e (tVr 0 te) [Alt (LitCons cna [tvra] te) (wtd tvra)] Nothing where
    te = getType e
    tvra = tVr vn sta
    Just (cna,sta,ta) = lookupCType' dataTable te

createFunc :: DataTable -> [Int] -> [E] -> ([(TVr,String)] -> (E -> E,E)) -> E
createFunc dataTable ns es ee = foldr ELam eee tvrs where
    xs = [(tVr n te,n',runIdentity $ lookupCType' dataTable te) | te <- es | n <- ns | n' <- drop (length es) ns ]
    tvrs' = [ (tVr n' sta,rt) | (_,n',(_,sta,rt)) <- xs ]
    tvrs = [ t | (t,_,_) <- xs]
    (me,innerE) = ee tvrs'
    eee = me $ foldr esr innerE xs
    esr (tvr,n',(cn,st,_)) e = ECase (EVar tvr) (tVr 0 te) [Alt (LitCons cn [tVr n' st] te) e] Nothing  where
        te = getType $ EVar tvr




convertDecls :: Monad m => ClassHierarchy -> Map.Map Name Scheme -> DataTable -> [HsDecl] -> m [(Name,TVr,E)]
convertDecls classHierarchy assumps dataTable hsDecls = return (map anninst $ concatMap cDecl hsDecls) where
    doNegate e = eAp (eAp (func_negate funcs) (getType e)) e
    Identity funcs = fmapM (return . EVar . toTVr assumps) nameFuncNames
    anninst (a,b,c)
        | "Instance@" `isPrefixOf` show a = (a,setProperty prop_INSTANCE b, c)
        | otherwise = (a,b,c)
    pval = convertVal assumps
    cDecl :: HsDecl -> [(Name,TVr,E)]
    cDecl (HsForeignDecl _ ForeignPrimitive s n _) = [(name,var, lamt (foldr ($) (EPrim (primPrim s) (map EVar es) rt) (map ELam es)))]  where
        name = toName Name.Val n
        var = tVr (nameToInt name) ty
        (ty,lamt) = pval name
        (ts,rt) = argTypes' ty
        es = [ (tVr ( n) t) |  t <- ts, not (sortStarLike t) | n <- localVars ]
    cDecl (HsForeignDecl _ ForeignCCall s n _)
        | Func _ s _ _ <- p, not isIO =  expr $ createFunc dataTable [4,6..] (map tvrType es) $ \rs -> (,) id $ eStrictLet rtVar' (EPrim (APrim (Func False s (snds rs) rtt) req) [ EVar t | (t,_) <- rs ] rtt') (ELit $ LitCons cn [EVar rtVar'] rt')
        | Func _ s _ _ <- p, "void" <- toExtType rt' =
                expr $ (createFunc dataTable [4,6..] (map tvrType es) $ \rs -> (,) (ELam tvrWorld) $
                    eStrictLet tvrWorld2 (EPrim (APrim (Func True s (snds rs) "void") req) (EVar tvrWorld:[EVar t | (t,_) <- rs ]) tWorld__) (eJustIO (EVar tvrWorld2) vUnit))
        | Func _ s _ _ <- p =
                expr $ (createFunc dataTable [4,6..] (map tvrType es) $ \rs -> (,) (ELam tvrWorld) $
                    eCaseTup' (EPrim (APrim (Func True s (snds rs) rtt) req) (EVar tvrWorld:[EVar t | (t,_) <- rs ]) rttIO')  [tvrWorld2,rtVar'] (eLet rtVar (ELit $ LitCons cn [EVar rtVar'] rt') (eJustIO (EVar tvrWorld2) (EVar rtVar))))
        | AddrOf _ <- p = let
            (cn,st,ct) = runIdentity (lookupCType' dataTable rt)
            (var:_) = freeNames (freeVars rt)
            vr = tVr var st
          in expr $ eStrictLet vr (EPrim (APrim p req) [] st) (ELit (LitCons cn [EVar vr] rt))
        where
        expr x = [(name,var,lamt x)]
        Just (APrim p req) = parsePrimString s
        name = toName Name.Val n
        tvrWorld = tVr 256 tWorld__
        tvrWorld2 = tVr 258 tWorld__
        rtVar = tVr 260 rt'
        rtVar' = tVr 262 rtt'
        rttIO = ltTuple [tWorld__, rt']
        rttIO' = ltTuple' [tWorld__, rtt']
        (isIO,rt') = case  rt of
            ELit (LitCons c [x] _) | show c == "Jhc.IO.IO" -> (True,x)
            _ -> (False,rt)
        toExtType e | Just (_,pt) <-  lookupCType dataTable e = pt
        toExtType e = error $ "toExtType: " ++ show e
        var = tVr (nameToInt name) ty
        (ty,lamt) = pval name
        (ts,rt) = argTypes' ty
        es = [ (tVr ( n) t) |  t <- ts, not (sortStarLike t) | n <- localVars ]
        (cn,rtt',rtt) = case lookupCType' dataTable rt' of
            Right x -> x
            Left err -> error $ "Odd RetType foreign: " ++ err
        {-
        p' = case p of
            --AddrOf _ -> EPrim (APrim p req) (map EVar es) rt
            Func _ s _ _ -> let ep = EPrim (APrim (Func isIO s (map (toExtType . tvrType) es) (toExtType rt')) req)  in case isIO of
                False -> error "false"
                --False -> ep (map EVar es) rt
                --True | toExtType rt' /= "void" -> prim_unsafeCoerce (ELam tvrWorld $  eCaseTup  (ep (map EVar (tvrWorld:es))  rttIO) [tvrWorld2,rtVar] (eJustIO (EVar tvrWorld2) (EVar rtVar))) rt
                --     | otherwise -> prim_unsafeCoerce (ELam tvrWorld $ eStrictLet tvrWorld2 (ep (map EVar (tvrWorld:es))  tWorld__) (eJustIO (EVar tvrWorld2) vUnit)) rt
                True | toExtType rt' /= "void" -> ELam tvrWorld $  eCaseTup  (ep (map EVar (tvrWorld:es))  rttIO) [tvrWorld2,rtVar] (eJustIO (EVar tvrWorld2) (EVar rtVar))
                     | otherwise -> ELam tvrWorld $ eStrictLet tvrWorld2 (ep (map EVar (tvrWorld:es))  tWorld__) (eJustIO (EVar tvrWorld2) vUnit)
                 --    | otherwise -> eStrictLet tvrWorld2 (ep (map EVar (tvrWorld:es))  tWorld__) (prim_unsafeCoerce (ELam tvrWorld $  eJustIO (EVar tvrWorld2) vUnit) rt)
        -}
    cDecl (HsPatBind sl p rhs wh) | (HsPVar n) <- simplifyHsPat p = let
        name = toName Name.Val n
        var = tVr (nameToInt name) ty -- lp ps (hsLet wh e)
        (ty,lamt) = pval name
        in [(name,var,lamt $ hsLetE wh (cRhs sl rhs))]
    cDecl (HsFunBind [(HsMatch sl n ps rhs wh)]) | ps' <- map simplifyHsPat ps, all isHsPVar ps' = [(name,var,lamt $ lp  ps' (hsLetE wh (cRhs sl rhs))) ] where
        name = toName Name.Val n
        var = tVr ( nameToInt name) ty -- lp ps (hsLet wh e)
        (ty,lamt) = pval name
    cDecl (HsFunBind ms@((HsMatch sl n ps _ _):_)) = [(name,v,lamt $ z $ cMatchs bs (matchesConv ms) (ump sl rt))] where
        name = toName Name.Val n
        v = tVr (nameToInt name) t -- lp ps (hsLet wh e)
        (t,lamt) = pval name
        (targs,eargs) = argTypes t
        bs' = [(tVr (n) t) | n <- localVars | t <- take numberPatterns eargs]
        bs  = map EVar bs'
        rt = discardArgs (length targs + numberPatterns) t
        numberPatterns = length ps
        z e = foldr (eLam) e bs'
    cDecl HsNewTypeDecl {  hsDeclName = dname, hsDeclArgs = dargs, hsDeclCon = dcon, hsDeclDerives = derives } = makeDerives dname dargs [dcon] derives
    cDecl HsDataDecl {  hsDeclName = dname, hsDeclArgs = dargs, hsDeclCons = dcons, hsDeclDerives = derives } = makeDerives dname dargs dcons derives
    cDecl cd@(HsClassDecl {}) = cClassDecl cd
    cDecl _ = []
    makeDerives dname dargs dcons derives  = concatMap f derives where
        f n | n == classBounded, all (null . hsConDeclArgs) dcons  = []
        f _ = []
    cExpr (HsAsPat n' (HsVar n)) = spec t t' $ EVar (tv n) where
        (Forall _ (_ :=> t)) = getAssump n
        Forall [] ((_ :=> t')) = getAssump n'
--    cExpr (HsAsPat n' (HsCon n)) =  (ELit (LitCons (getName n) [] (ty t'))) where
--        Forall [] ((_ :=> t')) = getAssump n'
--    cExpr (HsAsPat n' (HsCon n v)) =  foldr ($)  (ELit (LitCons (getName n) (map EVar es) rt)) (map ELam es) where -- (spec t t' (cType n))) where
--        (Forall _ (_ :=> t)) = gFalse n
--        Forall [] ((_ :=> t')) = getAssump n'
--        (ts,rt) = argTypes' (ty t')
--        es = [ (TVr (Just n) t) |  t <- ts | n <- localVars ]
    cExpr (HsAsPat n' (HsCon n)) =  foldr ($)  (ELit (LitCons (toName DataConstructor n) (map EVar es) rt)) (map ELam es) where -- (spec t t' (cType n))) where
        (Forall _ (_ :=> t)) = getAssumpCon n
        Forall [] ((_ :=> t')) = getAssump n'
        (ts,rt) = argTypes' (ty t')
        es = [ (tVr ( n) t) |  t <- ts | n <- localVars ]
    cExpr (HsLit (HsString s)) = E.Values.toE s
    cExpr (HsLit (HsInt i)) = intConvert i
    --cExpr (HsLit (HsInt i)) | abs i > integer_cutoff  =  ELit (LitCons (toName DataConstructor ("Prelude","Integer")) [ELit $ LitInt (fromInteger i) (ELit (LitCons (toName RawType "intmax_t") [] eStar))] tInteger)
    --cExpr (HsLit (HsInt i))  =  ELit (LitCons (toName DataConstructor ("Prelude","Int")) [ELit $ LitInt (fromInteger i) (ELit (LitCons (toName RawType "int") [] eStar))] tInt)
    cExpr (HsLit (HsChar ch))  =  toE ch -- ELit (LitCons (toName DataConstructor ("Prelude","Char")) [ELit $ LitInt (fromIntegral $ ord i) (ELit (LitCons (toName RawType "uint32_t") [] eStar))] tChar)
    cExpr (HsLit (HsFrac i))  =  toE i -- ELit $ LitInt (fromRational i) tRational -- LitFrac i (error "litfrac?")
    cExpr (HsLambda sl ps e)
        | all isHsPVar ps' =  lp ps' (cExpr e)
        | otherwise = error $ "Invalid HSLambda at: " ++ show sl
        where
        ps' = map simplifyHsPat ps
    cExpr (HsInfixApp e1 v e2) = eAp (eAp (cExpr v) (cExpr e1)) (cExpr e2)
    cExpr (HsLeftSection op e) = eAp (cExpr op) (cExpr e)
    cExpr (HsApp (HsRightSection e op) e') = eAp (eAp (cExpr op) (cExpr e')) (cExpr e)
    cExpr (HsRightSection e op) = eLam var (eAp (eAp cop (EVar var)) ce)  where
        (_,TVr { tvrType = ty}:_) = fromPi (getType cop)
        var = (tVr ( nv) ty)
        cop = cExpr op
        ce = cExpr e
        fvSet = (freeVars cop `Set.union` freeVars ce)
        (nv:_) = [ v  | v <- localVars, not $  v `Set.member` fvSet  ]
    cExpr (HsApp e1 e2) = eAp (cExpr e1) (cExpr e2)
    cExpr (HsParen e) = cExpr e
    cExpr (HsExpTypeSig _ e _) = cExpr e
    cExpr (HsNegApp e) = (doNegate (cExpr e))
    cExpr (HsLet dl e) = hsLet dl e
    cExpr (HsIf e a b) = eIf (cExpr e) (cExpr a) (cExpr b)
    cExpr (HsCase _ []) = error "empty case"
    cExpr hs@(HsCase e alts) = z where
        z = cMatchs [cExpr e] (altConv alts) (EError ("No Match in Case expression at " ++ show (srcLoc hs))  (getType z))
    cExpr (HsTuple es) = eTuple (map cExpr es)
    cExpr (HsAsPat n (HsList xs)) = cl xs where
        cl (x:xs) = eCons (cExpr x) (cl xs)
        cl [] = eNil (cType n)
    --cExpr (HsAsPat _ e) = cExpr e
    cExpr e = error ("Cannot convert: " ++ show e)
    hsLetE [] e =  e
    hsLetE dl e =  ELetRec [ (b,c) | (_,b,c) <- (concatMap cDecl dl)] e
    hsLet dl e = hsLetE dl (cExpr e)

    ty x = tipe x
    kd x = kind x
    cMatchs :: [E] -> [([HsPat],HsRhs,[HsDecl])] -> E -> E
    cMatchs bs ms els = convertMatches funcs dataTable tv cType bs (processGuards ms) els

    cGuard (HsUnGuardedRhs e) _ = cExpr e
    cGuard (HsGuardedRhss (HsGuardedRhs _ g e:gs)) els = eIf (cExpr g) (cExpr e) (cGuard (HsGuardedRhss gs) els)
    cGuard (HsGuardedRhss []) e = e

    getAssumpCon n = case Map.lookup (toName Name.DataConstructor n) assumps of
        Just z -> z
        Nothing -> error $ "Lookup failed: " ++ (show n)
    getAssump n = case Map.lookup (toName Name.Val n) assumps of
        Just z -> z
        Nothing -> error $ "Lookup failed: " ++ (show n)
    tv n = toTVr assumps (toName Name.Val n)
    lp  [] e = e
    lp  (HsPVar n:ps) e = eLam (tv n) $ lp  ps e
    lp  p e  =  error $ "unsupported pattern:" <+> tshow p  <+> tshow e
    --cRhs sl rhs = g where g = cGuard rhs (ump sl $ getType g) --deliciously lazy
    cRhs sl (HsUnGuardedRhs e) = cExpr e
    cRhs sl (HsGuardedRhss []) = error "HsGuardedRhss: empty"
    cRhs sl (HsGuardedRhss gs@(HsGuardedRhs _ _ e:_)) = f gs where
        f (HsGuardedRhs _ g e:gs) = eIf (cExpr g) (cExpr e) (f gs)
        f [] = ump sl $ getType (cExpr e)
    processGuards xs = [ (map simplifyHsPat ps,hsLetE wh . cGuard e) | (ps,e,wh) <- xs ]
    spec g s e = ct (gg g s)  e  where
        ct ts e = foldl eAp e $ map ty $ snds ts
        gg a b = snubFst $ gg' a b
        gg' (TAp t1 t2) (TAp ta tb) = gg' t1 ta ++ gg' t2 tb
        gg' (TArrow t1 t2) (TArrow ta tb) = gg' t1 ta ++ gg' t2 tb
        gg' (TCon a) (TCon b) = if a /= b then error "constructors don't match." else []
        gg' _ (TGen _ _) = error "Something impossible happened!"
        gg' (TGen n _) t = [(n,t)]
        gg' (TVar a) (TVar b) | a == b = []
        gg' a b = error $ "specialization: " <> parens  (show a) <+> parens (show b) <+> "in spec" <+> hsep (map parens [show g, show s, show e])
    cType (n::HsName) = fst $ pval (toName Name.Val n)

    cClassDecl (HsClassDecl _ (HsQualType _ (HsTyApp (HsTyCon name) _)) decls) = ans where
        ds = map simplifyDecl decls
        cr = findClassRecord classHierarchy name
        ans = concatMap method [  n | n :>: _ <- classAssumps cr]
        method n = return (defaultName,tVr ( nameToInt defaultName) ty,els) where
            defaultName = toName Name.Val $ defaultInstanceName n
            (TVr { tvrType = ty}) = tv n
            els = case [ d | d <- ds, maybeGetDeclName d == Just n] of
                [d] | [(_,_,v)] <- cDecl d -> v
                -- []  -> EError ((show n) ++ ": no instance or default.") ty
                []  -> EError "Bad" ty
                _ -> error "This shouldn't happen"
    cClassDecl _ = error "cClassDecl"


ctgen t = map snd $ snubFst $ Seq.toList $ everything (Seq.<>) (mkQ Seq.empty gg) t where
    gg (TGen n g) = Seq.single (n,g)
    gg _ =  Seq.empty

integer_cutoff = 500000000

intConvert i | abs i > integer_cutoff  =  ELit (LitCons dc_Integer [ELit $ LitInt (fromInteger i) (rawType "intmax_t")] tInteger)
intConvert i =  ELit (LitCons dc_Int [ELit $ LitInt (fromInteger i) (rawType "int")] tInt)

--litconvert (HsInt i) t  =  LitInt (fromInteger i) t
litconvert (HsChar i) t | t == tChar =  LitInt (fromIntegral $ ord i) tCharzh
--litconvert (HsFrac i) t =  LitInt (fromRational i) t -- LitFrac i t
litconvert e t = error $ "litconvert: shouldn't happen: " ++ show (e,t)


fromHsPLitInt (HsPLit l@(HsInt _)) = return l
fromHsPLitInt (HsPLit l@(HsFrac _)) = return l
fromHsPLitInt x = fail $ "fromHsPLitInt: " ++ show x

convertMatches funcs dataTable tv cType bs ms err = evalState (match bs ms err) (20 + 2*length bs)  where
    doNegate e = eAp (eAp (func_negate funcs) (getType e)) e
    fromInt = func_fromInt funcs
    fromInteger = func_fromInteger funcs
    fromRational = func_fromRational funcs
    match :: [E] -> [([HsPat],E->E)] -> E -> State Int E
    match  [] ps err = f ps where
        f (([],e):ps) = do
            r <- f ps
            return (e r)
        f [] = return err
        f _ = error "FromHs.convertMatches.match"
    match _ [] err = return err
    match (b:bs) ps err = f patternGroups err where
        f  [] err = return err
        f (ps:pss) err = do
            err' <- f pss err
            if isEVar err' || isEError err' then
               g ps err'
               else do
                [ev] <- newVars [getType err']
                nm <- g ps (EVar ev)
                return $ eLetRec [(ev,err')] nm
        g ps err
            | all (not . isStrictPat) patternHeads = match bs [(ps',eLetRec (toBinding p) . e)  | (p:ps',e) <- ps] err
            | any (isHsPAsPat || isHsPNeg || isHsPIrrPat) patternHeads = g (map (procAs b) ps) err
            | Just () <- mapM_ fromHsPLitInt patternHeads = do
                let tb = getType b
                [bv] <- newVars [tb]
                let gps = [ (p,[ (ps,e) |  (_:ps,e) <- xs ]) | (p,xs) <- sortGroupUnderF (head . fst) ps]
                    eq = EAp (func_equals funcs) tb
                    f els (HsPLit (HsInt i),ps) = do
                        --let ip = (EAp (EAp fromInt tb) (ELit (LitInt (fromIntegral i) tInt)))
                        let ip | abs i > integer_cutoff  = (EAp (EAp fromInteger tb) (intConvert i))
                               | otherwise =  (EAp (EAp fromInt tb) (intConvert i))
                        m <- match bs ps err
                        return $ eIf (EAp (EAp eq (EVar bv)) ip) m els
                    f els (HsPLit (HsFrac i),ps) = do
                        --let ip = (EAp (EAp fromInt tb) (ELit (LitInt (fromIntegral i) tInt)))
                        let ip = (EAp (EAp fromRational tb) (toE i))
                        m <- match bs ps err
                        return $ eIf (EAp (EAp eq (EVar bv)) ip) m els
                e <- foldlM f err gps
                return $ eLetRec [(bv,b)] e
            | all isHsPLit patternHeads = do
                let gps = [ (p,[ (ps,e) |  (_:ps,e) <- xs ]) | (p,xs) <- sortGroupUnderF (head . fst) ps]
                    f (HsPLit l,ps) = do
                        m <- match bs ps err
                        return (Alt  (litconvert l (getType b)) m)
                as@(_:_) <- mapM f gps
                [TVr { tvrIdent = vr }] <- newVars [Unknown]
                return $ unbox dataTable b vr $ \tvr -> eCase (EVar tvr) as err
                --return $ eCase b as err
            | all isHsPApp patternHeads = do
                let gps =  sortGroupUnderF (hsPatName . head . fst) ps
                    f (name,ps) = do
                        let spats = hsPatPats $ head $ fst (head ps)
                            nargs = length spats
                        vs <- newVars (slotTypes dataTable (toName DataConstructor name) (getType b))
                        ps' <- mapM pp ps
                        m <- match (map EVar vs ++ bs) ps' err
                        return (Alt (LitCons (toName DataConstructor name) vs (getType b))  m)
                    --pp :: Monad m =>  ([HsPat], E->E) -> m ([HsPat], E->E)
                    pp (HsPApp n ps:rps,e)  = do
                        return $ (ps ++ rps , e)
                as@(_:_) <- mapM f gps
                return $ eCase b as err
            | otherwise = error $ "Heterogenious list: " ++ show patternHeads
            where
            patternHeads = map (head . fst) ps
        patternGroups = groupUnder (isStrictPat . head . fst) ps
        procAs b (HsPNeg p:ps, ef) =  (p:ps,ef)  -- TODO, negative patterns
        procAs b (HsPAsPat n p:ps, ef) =  (p:ps,eLetRec [((tv n),b)] . ef)
        procAs b (HsPIrrPat p:ps, ef) =  (p:ps, ef) -- TODO, irrefutable patterns
        procAs _ x = x
        toBinding (HsPVar v) = [(tv v,b)]
        toBinding (HsPNeg (HsPVar v)) = [(tv v,doNegate b)]
        toBinding (HsPIrrPat p) = toBinding p
        toBinding (HsPAsPat n p) = (tv n,b):toBinding p
        toBinding p = error $ "toBinding: " ++ show p



isStrictPat HsPVar {} = False
isStrictPat (HsPNeg p) = isStrictPat p
isStrictPat (HsPAsPat _ p) = isStrictPat p
isStrictPat (HsPIrrPat p) = isStrictPat p  -- TODO irrefutable patterns
isStrictPat _ = True


--convertVMap vmap = Map.fromList [ (y,x) |  (x,y) <- Map.toList vmap]

deNewtype :: DataTable -> E -> E
deNewtype dataTable e = f e where
    f (ELit (LitCons n [x] t)) | alias =  (f x)  where
        alias = case getConstructor n dataTable of
                 Just v -> conAlias v
                 x      -> error ("deNewtype for "++show n++": "++show x)
    f ECase { eCaseScrutinee = e, eCaseAlts =  ((Alt (LitCons n [v] t) z):_) } | alias = eLet v (f e)  (f z) where
        Just Constructor { conAlias = alias } = getConstructor n dataTable
    f e = runIdentity $ emapE (return . f) e

{-
deNewtype :: DataTable -> E -> E
deNewtype dataTable e = f e where
    f (ELit (LitCons n [x] t)) | alias =  prim_unsafeCoerce (f x) t where
        Just Constructor { conAlias = alias } = getConstructor n dataTable
    f ECase { eCaseScrutinee = e, eCaseAlts =  ((Alt (LitCons n [v] t) z):_) } | alias = eLet v (prim_unsafeCoerce (f e) (getType v)) (f z) where
        Just Constructor { conAlias = alias } = getConstructor n dataTable
        --((nt:_),_) = argTypes' (typ z)
    f e = runIdentity $ emapE (return . f) e
--    f (ECase e ((PatLit ((LitCons n [_] t)),z):_)) | alias = EAp (f z) (EPrim "unsafeCoerce" [f e] nt) where
--        Just Constructor { conAlias = alias } = getConstructor n dataTable
--        ((nt:_),_) = argTypes' (typ z)

-}

{-

toLC' :: Monad m => DataTable -> NameAssoc ->  ModEnv -> String -> m E
toLC' dataTable nameAssoc mi wt = return $  eLetRec (theMain : (concatMap cClass (classRecords $ modEnvClassHierarchy mi)  ++ concatMap cDecl  decls)) (EVar theMainTvr)  where
    decls = concat [ hsModuleDecls $ modInfoHsModule m | m <- Map.elems (modEnvModules mi) ] ++ Map.elems (modEnvLiftedInstances mi)
    assumps = modEnvAllAssumptions mi -- `plusFM` modEnvDConsAssumptions mi
    theMainTvr =  TVr (Just $ nameToInt theMainName) (typ (snd theMain))
    --theMain = (theMainTvr,case ioLike  of Just x ->  EAp (EAp runMain  x ) (EVar tvm) ; Nothing -> EVar tvm)  where
    theMain = (theMainTvr,case ioLike  of Just x ->  EAp (EAp runMain  x ) (EVar tvm) ; Nothing ->  EAp (EAp runExpr ty) (EVar tvm))  where
        tvm@(TVr _ ty ) =  main
        ioLike = case smplE ty of
            ELit (LitCons n [x] _) -> if show n ==  "Jhc.IO.IO" then Just x else Nothing
            _ -> Nothing
    --nameToInt n = case Map.lookup n nameAssoc of
    --    Nothing -> error $ "Not found: " ++ show n
    --    Just z -> z

    main = toTVr (parseName Val wt)
    negate  = EVar $ toTVr (toName Val ("Prelude","negate"))
    runMain = EVar $ toTVr (toName Val ("Prelude.IO","runMain"))
    runExpr = EVar $ toTVr (toName Val ("Prelude.IO","runExpr"))


    --tv n = TVr (zm (Left n)) (cType n)
    --cClass :: (HsName,([Class], [Qual Pred], [Assump])) -> [(TVr,E)]
    cClass :: ClassRecord -> [(TVr,E)]
    cClass ClassRecord { className = name, classInsts = is, classAssumps = as } =  concat [ method n | n :>: _ <- as ] where
        method n = return (tv n, v) where
            els = case [ d | d <- ds, maybeGetDeclName d == Just n] of
                [d] | [(_,v)] <- cDecl d -> eAp v (EVar tvr)
                []  -> EError ((show n) ++ ": no instance or default.") t
                _ -> error "This shouldn't happen"
            --v = if null as then
            --     snd $ head $ head [ cDecl d | d <- ds, maybeGetDeclName d == Just n]
            --            else eLam tvr (eCase (EVar tvr) as els)
            v = eLam tvr (eCase (EVar tvr) as els)
            as = [(valToPat [] ( ty t), (EVar $ toTVr name)) | (_ :=> IsIn _ t ) <- is, let name =(toName Name.Val (instanceName n (getTypeCons t))), isJust $ Map.lookup name  assumps ] -- ++ [(valToPat [] ( ty t), (EVar $ toTVr name)) | (_ :=> IsIn _ t ) <- is, let name =(toName Name.Val (instanceName n (getTypeCons t))), isJust $ Map.lookup name  assumps ]
            (EPi tvr@(TVr _ _) t) = cType n
            valToPat xs (ELit (LitCons x ts t)) = PatLit $ LitCons x (replicate (length ts) Unknown)  (foldr EPi t xs)
            valToPat _ e = errorDoc $ text "valToPat:" <+> ePretty e
            --valToPat xs (ELam tvr e) = valToPat (tvr:xs) e
            --valToPat xs (EAp (ELam tvr b) e) = valToPat xs (subst tvr e b)
        [ds] = [ map simplifyDecl decls | (HsClassDecl _ (HsQualType _ (HsTyApp (HsTyCon n) _)) decls)  <- decls, n == name]


    --pvalCache =   Map.fromList $ map (\x -> let y = toName Name.Val x in (y,pval' y)) $ lefts vars
    --pval n = case Map.lookup  (toName Name.Val n) pvalCache of
    --    Just z -> z
     --   Nothing -> error $ "pval Lookup failed: " ++ (show n)
    ft n = snd $ pval (toName Name.Val n)
    --specialize a quantified type to a specific one by applying the expression to types
    ty (TAp t1 t2) = eAp (ty t1) (ty t2)
    ty (TArrow t1 t2) =  EPi (TVr Nothing (ty t1)) (ty t2)
    ty (TCon (Tycon n k)) =  ELit (LitCons (toName TypeConstructor n) [] (kd k))
--    ty (TCon (Tycon n k)) = foldr ($) (ELit (LitCons (getName n) (map EVar es) rt)) (map ELam es) where
--        (ts,rt) = argTypes' (kd k)
--        es = [ (TVr (Just n) t) |  t <- ts | n <- localVars ]
    ty (TVar (Tyvar _ n k)) = EVar (TVr (lt n) (kd k))
    ty (TGen _ (Tyvar _ n k)) = EVar (TVr (lt n) (kd k))


        --gg' _ _ = []

createMethods :: Monad m => ClassHierarchy -> (Map.Map Name (TVr,E))  -> m [(Name,TVr,E)]
createMethods classHierarchy funcs = return ans where
    ans = concatMap cClass (classRecords classHierarchy)
    --cClass ClassRecord { className = name, classInsts = is, classAssumps = as } =  concat [ method n | n :>: _ <- as ]
    cClass classRecord =  [ method classRecord n | n :>: _ <- classAssumps classRecord ]

    method classRecord n = (methodName ,TVr ( nameToInt methodName) ty,v) where
        methodName = toName Name.Val n
        Just (deftvr@(TVr _ ty),_) = findName (toName Name.Val (defaultInstanceName n))
        els = eAp (EVar deftvr) (EVar tvr)
        --els = case [ d | d <- ds, maybeGetDeclName d == Just n] of
        --    [d] | [(_,v)] <- cDecl d -> eAp v (EVar tvr)
        --    []  -> EError ((show n) ++ ": no instance or default.") t
        --    _ -> error "This shouldn't happen"
        --v = if null as then
        --     snd $ head $ head [ cDecl d | d <- ds, maybeGetDeclName d == Just n]
        --            else eLam tvr (eCase (EVar tvr) as els)
        v = eLam tvr (eCase (EVar tvr) as els)
        --as = [Alt (valToPat [] (tipe t)) ((EVar $ fst $ runIdentity $ findName name)) | (_ :=> IsIn _ t ) <- classInsts classRecord, let name =(toName Name.Val (instanceName n (getTypeCons t))), isJust $ findName name ] -- ++ [(valToPat [] ( ty t), (EVar $ toTVr name)) | (_ :=> IsIn _ t ) <- is, let name =(toName Name.Val (instanceName n (getTypeCons t))), isJust $ Map.lookup name  assumps ]
        as = [calt (tipe t) (fst $ runIdentity $ findName name) | (_ :=> IsIn _ t ) <- classInsts classRecord, let name =(toName Name.Val (instanceName n (getTypeCons t))), isJust $ findName name ] -- ++ [(valToPat [] ( ty t), (EVar $ toTVr name)) | (_ :=> IsIn _ t ) <- is, let name =(toName Name.Val (instanceName n (getTypeCons t))), isJust $ Map.lookup name  assumps ]
        (EPi tvr@(TVr _ _) t) = ty
        calt (ELit (LitCons x vs t)) tvr =  Alt (LitCons x [ tvr | ~(EVar tvr) <- vs ]  t) (foldl EAp (EVar tvr) vs)
        --valToPat xs (ELit (LitCons x ts t)) = PatLit $ LitCons x (replicate (length ts) Unknown)  (foldr EPi t xs)
        valToPat [] (ELit (LitCons x [] t)) =  LitCons x []  t
        valToPat [] (ELit (LitCons x vs t)) =  LitCons x [ tvr | ~(EVar tvr) <- vs ]  t
        --valToPat xs (ELit (LitCons x ts t)) =  LitCons x (replicate (length ts) Unknown)  (foldr EPi t xs)
        valToPat [] e = errorDoc $ text "valToPat:" <+> ePretty e
        --valToPat xs (ELam tvr e) = valToPat (tvr:xs) e
        --valToPat xs (EAp (ELam tvr b) e) = valToPat xs (subst tvr e b)
    --nameMap = Map.fromList [ (n,(t,e)) |  (n,t,e) <- funcs]
    findName name = case Map.lookup name funcs of
        Nothing -> fail $ "Cannot find: " ++ show name
        Just n -> return n
-}


