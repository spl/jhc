module FrontEnd.Tc.Main (tiExpr, tiProgram, makeProgram, isTypePlaceholder ) where

import Control.Monad.Reader
import Control.Monad.Writer
import System.IO(hPutStr,stderr)
import Text.Printf
import qualified Data.Map as Map
import qualified Data.Set as Set

import Doc.PPrint as PPrint
import FrontEnd.Class
import FrontEnd.Desugar
import FrontEnd.Diagnostic
import FrontEnd.HsPretty
import FrontEnd.HsSyn
import FrontEnd.KindInfer
import FrontEnd.Syn.Traverse
import FrontEnd.Tc.Class
import FrontEnd.Tc.Kind
import FrontEnd.Tc.Monad hiding(listenPreds)
import FrontEnd.Tc.Type
import FrontEnd.Tc.Unify
import FrontEnd.Warning
import GenUtil
import Name.Names
import Name.VConsts
import Options
import Support.FreeVars
import Util.DocLike
import Util.Graph
import Util.Progress
import qualified FlagDump as FD
import qualified FlagOpts as FO
import qualified Text.PrettyPrint.HughesPJ as P

listenPreds = listenSolvePreds

type Expl = (Sigma, HsDecl)
-- TODO: this is different than the "Typing Haskell in Haskell" paper
-- we do not further sub-divide the implicitly typed declarations in
-- a binding group.
type BindGroup = ([Expl], [Either HsDecl [HsDecl]])

tpretty vv = prettyPrintType vv
tppretty vv = parens (tpretty vv)

tcKnownApp e coerce vname as typ = do
    sc <- lookupName vname
    let (_,_,rt) = fromType sc
    -- fall through if the type isn't arrowy enough (will produce type error)
    if (length . fst $ fromTArrow rt) < length as then tcApps' e as typ else do
    (ts,rt) <- freshInstance Sigma sc
    e' <- if coerce then doCoerce (ctAp ts) e else return e
    --addCoerce nname (ctAp ts)
    let f (TArrow x y) (a:as) = do
            a <- tcExprPoly a x
            y <- evalType y
            (as,fc) <- f y as
            return (a:as,fc)
        f lt [] = do
            fc <- lt `subsumes` typ
            return ([],fc)
        f _ _ = error "Main.tcKnownApp: bad."
    (nas,CTId) <- f rt as
    return (e',nas)

tcApps e@(HsVar v) as typ = do
    let vname = toName Val v
    --let nname = toName Val n
    when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "tcApps: " ++ (show vname)
    rc <- asks tcRecursiveCalls
    -- fall through if this is a recursive call to oneself
    if (vname `Set.member` rc) then tcApps' e as typ else do
    tcKnownApp e True vname as typ

tcApps e@(HsCon v) as typ = do
    (e,nname) <- wrapInAsPat e
    let vname = toName DataConstructor v
    when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "tcApps: " ++ (show nname ++ "@" ++ show vname)
    addToCollectedEnv (Map.singleton nname typ)
    tcKnownApp e False vname as typ

tcApps e as typ = tcApps' e as typ

-- the fall through case
tcApps' e as typ = do
    printRule $ "tcApps': " ++ (show e)
    bs <- sequence [ newBox kindArg | _ <- as ]
    e' <- tcExpr e (foldr fn typ bs)
    as' <- sequence [ tcExprPoly a r | r <- bs | a <- as ]
    return (e',as')

tcApp e1 e2 typ = do
    (e1,[e2]) <- tcApps e1 [e2] typ
    return (e1,e2)

tiExprPoly,tcExprPoly ::  HsExp -> Type ->  Tc HsExp

tcExprPoly e t = do
    t <- evalType t
    printRule $ "tiExprPoly " ++ tppretty t <+> show e
    tiExprPoly e t

tiExprPoly e t@TMetaVar {} = tcExpr e t   -- GEN2
tiExprPoly e t = do                   -- GEN1
    (ts,_,t) <- skolomize t
    e <- tcExpr e t
    doCoerce (ctAbs ts) e

doCoerce :: CoerceTerm -> HsExp -> Tc HsExp
doCoerce CTId e = return e
doCoerce ct e = do
    (e',n) <- wrapInAsPat e
    addCoerce n ct
    return e'

wrapInAsPat :: HsExp -> Tc (HsExp,Name)
wrapInAsPat e = do
    n <- newHsVar "As"
    return (HsAsPat n e, n)

wrapInAsPatEnv :: HsExp -> Type -> Tc HsExp
wrapInAsPatEnv e typ = do
    (ne,ap) <- wrapInAsPat e
    addToCollectedEnv (Map.singleton ap typ)
    return ne

newHsVar ns = do
    nn <- newUniq
    return $ toName Val (ns ++ "@","tmp" ++ show nn)

isTypePlaceholder :: HsName -> Bool
isTypePlaceholder (getModule -> Just m) = m `elem` [toModule "Wild@",toModule "As@"]
isTypePlaceholder _ = False

tiExpr,tcExpr ::  HsExp -> Type ->  Tc HsExp

expMsg s e = simpleMsg (s ++ "\n" ++ render e)

tcExpr e t = do
    pe <- prettyName e
    sl <- getSrcLoc
    if False && sl /= bogusASrcLoc
    then withContext (expMsg "in the expression" (ppHsExp pe)) $ evalType t >>= tiExpr e
    else evalType t >>= tiExpr e

tiExpr (HsVar v) typ = do
    sc <- lookupName (toName Val v)
    f <- sc `subsumes` typ
    rc <- asks tcRecursiveCalls
    if (toName Val v `Set.member` rc) then do
        (e',n) <- wrapInAsPat (HsVar v)
        tell mempty { outKnots = [(n,toName Val v)] }
        return e'
      else do
        doCoerce f (HsVar v)

tiExpr (HsLCase alts) typ = do
    withContext (simpleMsg $ "in a \\case expression") $ do
    case typ of
        (from2Ty -> Just (mv,s1,s2)) -> do
            boxyMatch mv tArrow
            alts' <- mapM (tcAlt s1 s2) alts
            wrapInAsPatEnv (HsLCase alts') typ
        TMetaVar mv -> withMetaVars mv [kindArg,kindFunRet] (\ [a,b] -> a `fn` b) $ \ [s1,s2] -> do
            alts' <- mapM (tcAlt s1 s2) alts
            wrapInAsPatEnv (HsLCase alts') typ
        _ -> fail $ "Expected lambda case expression to be of shape (a -> b) but found: " ++ prettyPrintType typ

tiExpr (HsCase e alts) typ = do
    dn <- getDeName
    withContext (simpleMsg $ "in the case expression\n   case " ++ render (ppHsExp $ dn e) ++ " of ...") $ do
    scrutinee <- newBox kindFunRet
    e' <- tcExpr e scrutinee
    alts' <- mapM (tcAlt scrutinee typ) alts
    wrapInAsPatEnv (HsCase e' alts') typ

tiExpr (HsCon conName) typ = do
    sc <- lookupName (toName DataConstructor conName)
    sc `subsumes` typ
    wrapInAsPatEnv (HsCon conName) typ

tiExpr (HsLit l@(HsIntPrim _)) typ = do
    unBox typ
    ty <- evalType typ
    case ty of
        TCon (Tycon n kh) | kh == kindHash -> return ()
        _ -> ty `boxyMatch` (TCon (Tycon tc_Bits32 kindHash))
    wrapInAsPatEnv (HsLit l) ty

tiExpr (HsLit l@(HsInt _)) typ = do
    t <- tiLit l
    t `subsumes` typ
    wrapInAsPatEnv (HsLit l) typ

tiExpr err@HsError {} typ = do
    unBox typ
    wrapInAsPatEnv err typ

tiExpr (HsLit l) typ = do
    t <- tiLit l
    t `subsumes` typ
    return (HsLit l)

tiExpr (HsAsPat n e) typ = do
    e <- tcExpr e typ
    --typ <- flattenType typ
    addToCollectedEnv (Map.singleton (toName Val n) typ)
    return (HsAsPat n e)

-- comb LET-S and VAR
tiExpr expr@(HsExpTypeSig sloc e qt) typ =
    deNameContext  "in the annotated expression" expr $ do
    kt <- getKindEnv
    s <- hsQualTypeToSigma kt qt
    s `subsumes` typ
    e' <- tcExpr e typ
    return (HsExpTypeSig sloc e' qt)

tiExpr (HsLeftSection e1 e2) typ = do
    (e1,e2) <- tcApp e1 e2 typ
    return (HsLeftSection e1 e2)

-- I know this looks weird but it appears to be correct
-- e1 :: b
-- e2 :: a -> b -> c
-- e1 e2 :: a -> c

-- (: [])  \x -> x : []   `fn`

tiExpr (HsRightSection e1 e2) typ = do
    arg <- newBox kindArg
    arg2 <- newBox kindArg
    ret <- newBox kindFunRet
    e1 <- tcExpr e1 arg2
    e2 <- tcExpr e2 (arg `fn` (arg2 `fn` ret))
    (arg `fn` ret) `subsumes` typ
    return (HsRightSection e1 e2)

tiExpr expr@HsApp {} typ = deNameContext "in the application" (backToApp h as) $ do
    (h,as) <- tcApps h as typ
    return $ backToApp h as
    where
    backToApp h as = foldl HsApp h as
    (h,as) = fromHsApp expr
    fromHsApp t = f t [] where
        f (HsApp a b) rs = f a (b:rs)
        f t rs = (t,rs)

tiExpr expr@(HsInfixApp e1 e2 e3) typ = deNameContext "in the infix application" expr $ do
    (e2',[e1',e3']) <- tcApps e2 [e1,e3] typ
    return (HsInfixApp e1' e2' e3')

-- we need to fix the type to to be in the class
-- cNum, just for cases such as:
-- foo = \x -> -x

tiExpr expr@(HsNegApp e) typ = deNameContext "in the negative expression" expr $ do
        e <- tcExpr e typ
        addPreds [IsIn class_Num typ]
        return (HsNegApp e)

-- ABS1
tiExpr (HsLambda sloc ps e) typ = do
    withSrcLoc sloc $ do
    dn <- getDeName
    withContext (locSimple sloc $ "in the lambda expression\n   \\" ++ show (pprint (dn ps):: P.Doc) ++ " -> ...") $ do
    let f (p:ps) rs | isSimplePat p = f ps (p:rs)
        f (p:ps) rs  = do
            lvar <- newHsVar "Lam"
            (e,rs) <- f ps (HsPVar lvar:rs)
            let a1 =  HsAlt sloc p (HsUnGuardedRhs e) []
                a2 =  HsAlt sloc HsPWildCard (HsUnGuardedRhs (HsError { hsExpSrcLoc = sloc, hsExpErrorType = HsErrorPatternFailure, hsExpString = show sloc ++ " failed pattern match in lambda" })) []
            return $ (HsCase (HsVar lvar) $ if isFailablePat p then [a1, a2] else [a1],rs)
        f [] rs = return (e,reverse rs)
    (ne,nps) <-  f ps []
    tiLambda sloc nps ne typ

--tiExpr (HsList HsComp { .. } typ = deNameContext Nothing "in the list comprehension" expr $ do
--        e <- tcExpr e typ
--        addPreds [IsIn class_Num typ]
--        return (HsNegApp e)

tiExpr (HsIf e e1 e2) typ = do
    dn <- getDeName
    withContext (simpleMsg $ "in the if expression\n   if " ++ render (ppHsExp (dn e)) ++ "...") $ do
    e <- tcExpr e tBool
    e1 <- tcExpr e1 typ
    e2 <- tcExpr e2 typ
    return (HsIf e e1 e2)

tiExpr tuple@(HsTuple exps@(_:_)) typ = deNameContext "in the tuple" tuple $ do
    --(_,exps') <- tcApps (HsCon (toTuple (length exps))) exps typ
    (_,exps') <- tcApps (HsCon (name_TupleConstructor termLevel (length exps))) exps typ
    return (HsTuple exps')

tiExpr t@(HsTuple []) typ = do -- deNameContext Nothing "in the tuple" tuple $ do
    tUnit `subsumes` typ
    return t
--    return (HsTuple [])
    --(_,exps') <- tcApps (HsCon (toTuple (length exps))) exps typ
    --(_,exps') <- tcApps (HsCon (nameTuple TypeConstructor (length exps))) exps typ
    --return (HsTuple exps')

tiExpr tuple@(HsUnboxedTuple exps) typ = deNameContext "in the unboxed tuple" tuple $ do
    (_,exps') <- tcApps (HsCon (name_UnboxedTupleConstructor termLevel (length exps))) exps typ
    return (HsUnboxedTuple exps')

-- special case for the empty list
tiExpr (HsList []) (TAp c v) | c == tList = do
    unBox v
    wrapInAsPatEnv (HsList []) (TAp c v)

-- special case for the empty list
tiExpr (HsList []) typ = do
    v <- newVar kindStar
    let lt = TForAll [v] ([] :=> TAp tList (TVar v))
    lt `subsumes` typ
    wrapInAsPatEnv (HsList []) typ

-- non empty list
tiExpr expr@(HsList exps@(_:_)) (TAp tList' v) | tList == tList' = deNameContext "in the list " expr $ do
        exps' <- mapM (`tcExpr` v) exps
        wrapInAsPatEnv (HsList exps') (TAp tList' v)

-- non empty list
tiExpr expr@(HsList exps@(_:_)) typ = deNameContext "in the list " expr $ do
        v <- newBox kindStar
        exps' <- mapM (`tcExpr` v) exps
        (TAp tList v) `subsumes` typ
        wrapInAsPatEnv (HsList exps') typ

tiExpr expr@(HsLet decls e) typ = deNameContext "in the let binding" expr $ do
    sigEnv <- getSigEnv
    let bgs = getFunDeclsBg sigEnv decls
        f (bg:bgs) rs = do
            (ds,env) <- tcBindGroup bg
            localEnv env $ f bgs (ds ++ rs)
        f [] rs = do
            e' <- tcExpr e typ
            return (HsLet rs e')
    f bgs []

tiExpr (HsDo ss) typ = do
    comp@HsComp { .. } <- doToComp ss
    case typ of
        TAp mon _ -> do
            addPreds [IsIn class_Monad mon]
        TArrow a b -> do
            addPreds  [IsIn class_Monad (tAp tArrow a)]
        _ -> do
            m <- newBox (kindStar `Kfun` kindStar)
            a <- newBox kindStar
            addPreds [IsIn class_Monad m]
            tAp m a `subsumes` typ
            return ()
    tcExpr (doCompToExp v_bind v_bind_ v_fail comp) typ

tiExpr expr@(HsListComp HsComp { .. }) typ = do
    deNameContext "in the list comprehension" expr $ do
    v <- newBox kindStar
    (TAp tList v) `subsumes` typ
    e <- listCompToExp (newHsVar "lc") hsCompBody hsCompStmts
    tcExpr e typ

{-
tiExpr (HsDo ss) typ = do
    HsComp { .. } <- doToComp ss
    let f mt (HsQualifier e:qs) rs = do
            box <- newBox kindStar
            e <- tcExpr e (TAp mt box)
            unBox box -- this is to simulate what a _ binding would do.
            e <- wrapInAsPatEnv e (TAp mt box)
            f mt qs (HsQualifier e:rs)
        f mt (HsLetStmt decls:qs) rs = do
            let g (bg:bgs) rrs = do
                    (ds,env) <- tcBindGroup bg
                    localEnv env $ g bgs (ds ++ rrs)
                g [] rrs = do
                    f mt qs (HsLetStmt rrs:rs)
            sigEnv <- getSigEnv
            g (getFunDeclsBg sigEnv decls) []
        f mt (HsGenerator sl pat exp:qs) rs = withSrcLoc sl $ do
            withSrcLoc sl $ do
            box <- newBox kindStar
            exp <- tcExpr exp (TAp mt box)
            (pat,env) <- tcPat pat box
            localEnv env $ f mt qs (HsGenerator sl pat exp:rs)
        f mt [] rs = do
            hsCompBody <- tcExpr hsCompBody typ
            return $ doCompToExp v_bind v_bind_ v_fail HsComp { hsCompStmts = reverse rs,.. }
--            return $ HsDo (reverse $ HsQualifier hsCompBody:rs)
    case typ of
        TAp mon _ -> do
            addPreds [IsIn class_Monad mon]
            f mon hsCompStmts []
        --TArrow a b ->
        _ -> do
            m <- newBox (kindStar `Kfun` kindStar)
            a <- newBox kindStar
            addPreds [IsIn class_Monad m]
            tAp m a `subsumes` typ
            f m hsCompStmts []
        -- _ -> fail $ "Expected do expression to be of shape Monad m => m a but found: " ++ prettyPrintType typ
-}

tiExpr (HsLocatedExp (Located sl e)) typ = withSrcSpan sl $ tiExpr e typ
tiExpr (HsParen e) typ = tcExpr e typ

tiExpr e typ = fail $ "tiExpr: not implemented for: " ++ show (e,typ)

tcWheres :: [HsDecl] -> Tc ([HsDecl],TypeEnv)
tcWheres decls = do
    sigEnv <- getSigEnv
    let bgs = getFunDeclsBg sigEnv decls
        f (bg:bgs) rs cenv  = do
            (ds,env) <- tcBindGroup bg
            localEnv env $ f bgs (ds ++ rs) (env `mappend` cenv)
        f [] rs cenv = return (rs,cenv)
    f bgs [] mempty

deNameContext :: String -> HsExp -> Tc a -> Tc a
deNameContext desc e action = do
    dn <- prettyName e
    sl <- getSrcLoc
    withContext (locMsg sl desc (render $ ppHsExp dn)) action

-----------------------------------------------------------------------------

-- type check implicitly typed bindings

tcAlt ::  Sigma -> Sigma -> HsAlt -> Tc HsAlt

tcAlt scrutinee typ alt@(HsAlt sloc pat gAlts wheres) = do
    dn <- getDeName
    withContext (locMsg sloc "in the alternative" $ render $ ppHsAlt (dn alt)) $ do
    scrutinee <- evalType scrutinee
    (pat',env) <- tcPat pat scrutinee
    localEnv env $ do
    (wheres', env) <- tcWheres wheres
    localEnv env $ case gAlts of
        HsUnGuardedRhs e -> do
            e' <- tcExpr e typ
            return (HsAlt sloc pat' (HsUnGuardedRhs e') wheres')
        HsGuardedRhss as -> do
            gas <- mapM (tcGuardedAlt typ) as
            return (HsAlt sloc pat' (HsGuardedRhss gas) wheres')

tcGuardedAlt typ gAlt@(HsComp sloc ~[HsQualifier eGuard] e) = withContext (locMsg sloc "in the guarded alternative" $ render $ ppGAlt gAlt) $ do
    typ <- evalType typ
    g' <- tcExpr eGuard tBool
    e' <- tcExpr e typ
    return  (HsComp sloc [HsQualifier g'] e')

tcGuardedRhs = tcGuardedAlt
{-
tcGuardedRhs typ gAlt@(HsGuardedRhs sloc eGuard e) = withContext (locMsg sloc "in the guarded alternative" $ render $ ppHsGuardedRhs gAlt) $ do
    typ <- evalType typ
    g' <- tcExpr eGuard tBool
    e' <- tcExpr e typ
    return  (HsGuardedRhs sloc g' e')
    -}

-- Typing Patterns
--

tiPat,tcPat :: HsPat -> Type -> Tc (HsPat, Map.Map Name Sigma)

tcPat p typ = do
    pn <- prettyName p
    withContext (makeMsg "in the pattern:" (pprint pn)) $ do
        typ <- evalType typ
        tiPat p typ

tiPat (HsPVar i) typ = do
        --v <- newMetaVar Tau Star
        --v `boxyMatch` typ
        --typ `subsumes` v
        typ' <- unBox typ
        addToCollectedEnv (Map.singleton (toName Val i) typ')
        return (HsPVar i, Map.singleton (toName Val i) typ')

tiPat pl@(HsPLit HsChar {}) typ = boxyMatch tChar typ >> return (pl,mempty)
tiPat pl@(HsPLit HsCharPrim {}) typ = boxyMatch tCharzh typ >> return (pl,mempty)
tiPat pl@(HsPLit HsString {}) typ = boxyMatch tString typ >> return (pl,mempty)
tiPat pl@(HsPLit HsInt {}) typ = do
    unBox typ
    addPreds [IsIn class_Num typ]
    return (pl,mempty)
tiPat pl@(HsPLit HsIntPrim {}) typ = do
    unBox typ
    ty <- evalType typ
    case ty of
        TCon (Tycon n kh) | kh == kindHash -> return ()
        _ -> ty `boxyMatch` (TCon (Tycon tc_Bits32 kindHash))
    return (pl,mempty)
tiPat pl@(HsPLit HsFrac {}) typ = do
    unBox typ
    addPreds [IsIn class_Fractional typ]
    return (pl,mempty)

{-
tiPat (HsPLit l) typ = do
    t <- tiLit l
    typ `subsumes` t -- `boxyMatch` typ
    return (HsPLit l,Map.empty)
-}
-- this is for negative literals only
-- so the pat must be a literal
-- it is safe not to make any predicates about
-- the pat, since the type checking of the literal
-- will do this for us
tiPat (HsPNeg (HsPLit (HsInt i))) typ = tiPat (HsPLit $ HsInt (negate i)) typ
tiPat (HsPNeg (HsPLit (HsFrac i))) typ = tiPat (HsPLit $ HsFrac (negate i)) typ
tiPat (HsPNeg (HsPLit (HsIntPrim i))) typ = tiPat (HsPLit $ HsIntPrim (negate i)) typ
tiPat (HsPNeg (HsPLit (HsFloatPrim i))) typ = tiPat (HsPLit $ HsFloatPrim (negate i)) typ
tiPat (HsPNeg (HsPLit (HsDoublePrim i))) typ = tiPat (HsPLit $ HsDoublePrim (negate i)) typ
tiPat (HsPNeg pat) typ = fail $ "non-literal negative patterns are not allowed"
--tiPat (HsPNeg pat) typ = tiPat pat typ

tiPat (HsPIrrPat (Located l p)) typ = do
    (p,ns) <- tiPat p typ
    return (HsPIrrPat (Located l p),ns)
tiPat (HsPBangPat (Located l p@HsPAsPat {})) typ = do
    (p,ns) <- tiPat p typ
    return (HsPBangPat (Located l p),ns)
tiPat (HsPBangPat (Located l p)) typ = do
    v <- newHsVar "Bang"
    tiPat (HsPBangPat (Located l (HsPAsPat v p))) typ
tiPat (HsPParen p) typ = tiPat p typ

-- TODO check that constructors are saturated
tiPat (HsPApp conName pats) typ = do
    s <- lookupName (toName DataConstructor conName)
    nn <- deconstructorInstantiate s
    let f (p:pats) (a `TArrow` rs) (ps,env) = do
            (np,res) <- tiPat p a
            f pats rs (np:ps,env `mappend` res)
        f (p:pats) rs _ = do
            fail $ "constructor applied to too many arguments:" <+> show p <+> prettyPrintType rs
        f [] (_ `TArrow` _) _ = do
            fail "constructor not applied to enough arguments"
        f [] rs (ps,env) = do
            rs `subsumes` typ
            unBox typ
            return (HsPApp conName (reverse ps), env)
    f pats nn mempty
    --bs <- sequence [ newBox Star | _ <- pats ]
    --s `subsumes` (foldr fn typ bs)
    --pats' <- sequence [ tcPat a r | r <- bs | a <- pats ]
    --return (HsPApp conName (fsts pats'), mconcat (snds pats'))

tiPat pl@(HsPList []) (TAp t v) | t == tList = do
    unBox v
    return (delistPats [],mempty)

tiPat pl@(HsPList []) typ = do
    v <- newBox kindStar
    --typ `subsumes` TAp tList v
    typ `boxyMatch` TAp tList v
    return (delistPats [],mempty)

tiPat (HsPList pats@(_:_)) (TAp t v) | t == tList = do
    --v <- newBox kindStar
    --TAp tList v `boxyMatch` typ
    --typ `subsumes` TAp tList v
    ps <- mapM (`tcPat` v) pats
    return (delistPats (fsts ps), mconcat (snds ps))

tiPat (HsPList pats@(_:_)) typ = do
    v <- newBox kindStar
    --TAp tList v `boxyMatch` typ
    ps <- mapM (`tcPat` v) pats
    typ `boxyMatch` TAp tList v
    return (delistPats (fsts ps), mconcat (snds ps))

tiPat HsPWildCard typ = do
    n <- newHsVar "Wild"
    typ' <- unBox typ
    addToCollectedEnv (Map.singleton n typ')
    return (HsPVar n, Map.singleton n typ')

tiPat (HsPAsPat i pat) typ = do
    (pat',env) <- tcPat pat typ
    addToCollectedEnv (Map.singleton (toName Val i) typ)
    return (HsPAsPat i pat', Map.insert (toName Val i) typ env)

tiPat (HsPInfixApp pLeft conName pRight) typ =  tiPat (HsPApp conName [pLeft,pRight]) typ

tiPat (HsPUnboxedTuple ps) typ = tiPat (HsPApp (name_UnboxedTupleConstructor termLevel (length ps)) ps) typ
tiPat (HsPTuple pats) typ = do
    (pt,s) <- tiPat (HsPApp (name_TupleConstructor termLevel (length pats)) pats) typ
    case pt of
        (HsPApp _ pats) -> return $ (HsPTuple pats,s)
        e -> return (e,s)

tiPat (HsPTypeSig _ pat qt)  typ = do
    kt <- getKindEnv
    s <- hsQualTypeToSigma kt qt
    s `boxyMatch` typ
    p <- tcPat pat typ
    return p

tiPat p _ = error $ "tiPat: " ++ show p

delistPats ps = pl ps where
    pl [] = HsPApp (dc_EmptyList) []
    pl (p:xs) = HsPApp (dc_Cons) [p, pl xs]

tcBindGroup :: BindGroup -> Tc ([HsDecl], TypeEnv)
tcBindGroup (es, is) = do
     let env1 = Map.fromList [(getDeclName decl, sc) | (sc,decl) <- es ]
     localEnv env1 $ do
         (impls, implEnv) <- tiImplGroups is
         localEnv implEnv $ do
             expls   <- mapM tiExpl es
             return (impls ++ fsts expls, mconcat (implEnv:env1:snds expls))

tiImplGroups :: [Either HsDecl [HsDecl]] -> Tc ([HsDecl], TypeEnv)
tiImplGroups [] = return ([],mempty)
tiImplGroups (Left x:xs) = do
    (d,te) <- tiNonRecImpl x
    (ds',te') <- localEnv te $ tiImplGroups xs
    return (d:ds', te `mappend` te')
tiImplGroups (Right x:xs) = do
    (ds,te) <- tiImpls x
    (ds',te') <- localEnv te $ tiImplGroups xs
    return (ds ++ ds', te `mappend` te')

tiNonRecImpl :: HsDecl -> Tc (HsDecl, TypeEnv)
tiNonRecImpl decl = withContext (locSimple (srcLoc decl) ("in the implicitly typed: " ++ show (getDeclNames decl))) $ do
    when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "*** tiimpls " ++ show (getDeclNames decl)
    mv <- newMetaVar Sigma kindStar
    (res,ps) <- listenPreds $ tcDecl decl mv
    ps' <- flattenType ps
    mv' <- flattenType mv
    fs <- freeMetaVarsEnv
    let vss = freeMetaVars mv'
        gs = vss Set.\\ fs
    (mvs,ds,rs) <- splitReduce fs vss ps'
    addPreds ds
    mr <- flagOpt FO.MonomorphismRestriction
    when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "*** tinonrecimpls quantify " ++ show (gs,rs,mv')
    sc' <- if restricted mr [decl] then do
        let gs' = gs Set.\\ Set.fromList (freeVars rs)
        ch <- getClassHierarchy
--        liftIO $ print $ genDefaults ch fs rs
        addPreds rs
        quantify (Set.toList gs') [] mv'
     else quantify (Set.toList gs) rs mv'
    let f n s = do
        let (TForAll vs _) = toSigma s
        addCoerce n (ctAbs vs)
        when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "*** " ++ show n ++ " :: " ++ prettyPrintType s
        return (n,s)
    (n,s) <- f (getDeclName decl) sc'
    let nenv = (Map.singleton n s)
    addToCollectedEnv nenv
    return (fst res, nenv)

tiImpls ::  [HsDecl] -> Tc ([HsDecl], TypeEnv)
tiImpls [] = return ([],Map.empty)
tiImpls bs = withContext (locSimple (srcLoc bs) ("in the recursive implicitly typed: " ++ (show (concatMap getDeclNames bs)))) $ do
    let names = concatMap getDeclNames bs
    when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "*** tiimpls " ++ show names
    ts <- sequence [newMetaVar Tau kindStar | _ <- bs]
    (res,ps) <- listenPreds $
        local (tcRecursiveCalls_u (Set.union $ Set.fromList names)) $
            localEnv (Map.fromList [  (d,s) | d <- names | s <- ts]) $
                sequence [ tcDecl d s | d <- bs | s <- ts ]
    ps' <- flattenType ps
    ts' <- flattenType ts
    fs <- freeMetaVarsEnv
    let vss = map (Set.fromList . freeVars) ts'
        gs = (Set.unions vss) Set.\\ fs
    (mvs,ds,rs) <- splitReduce fs (foldr1 Set.intersection vss) ps'
    addPreds ds
    mr <- flagOpt FO.MonomorphismRestriction
    scs' <- if restricted mr bs then do
        let gs' = gs Set.\\ Set.fromList (freeVars rs)
        addPreds rs
        quantify_n (Set.toList gs') [] ts'
     else do
        when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "*** tiimpls quantify " ++ show (gs,rs,ts')
        quantify_n (Set.toList gs) rs ts'
    let f n s = do
        let (TForAll vs _) = toSigma s
        addCoerce n (ctAbs vs)
        when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "*** " ++ show n ++ " :: " ++ prettyPrintType s
        return (n,s)
    nenv <- sequence [ f (getDeclName d) t  | (d,_) <- res | t <- scs' ]
    addToCollectedEnv (Map.fromList nenv)
    return (fsts res, Map.fromList nenv)

tcRhs :: HsRhs -> Sigma -> Tc HsRhs
tcRhs rhs typ = case rhs of
    HsUnGuardedRhs e -> do
        e' <- tcExpr e typ
        return (HsUnGuardedRhs e')
    HsGuardedRhss as -> do
        gas <- mapM (tcGuardedRhs typ) as
        return (HsGuardedRhss gas)

tcMiscDecl d = withContext (locMsg (srcLoc d) "in the declaration" "") $ f d where
    f spec@HsPragmaSpecialize { hsDeclSrcLoc = sloc, hsDeclName = n, hsDeclType = t } = do
        withContext (locMsg sloc "in the SPECIALIZE pragma" $ show n) ans where
        ans = do
            kt <- getKindEnv
            t <- hsTypeToType kt t
            let nn = toName Val n
            sc <- lookupName nn
            listenPreds $ sc `subsumes` t
            addRule RuleSpec { ruleUniq = hsDeclUniq spec, ruleName = nn, ruleType = t, ruleSuper = hsDeclBool spec }
            return [spec]
    f HsInstDecl { .. } = do
	tcClassHead hsDeclClassHead
        ch <- getClassHierarchy
        let as = asksClassRecord ch (hsClassHead hsDeclClassHead) classAssumps
	forM_ hsDeclDecls $ \d -> do
	    case maybeGetDeclName d of
		Just n -> when (n `notElem` fsts as) $ do
                    chn <- prettyNameName $ hsClassHead hsDeclClassHead
                    n <- prettyNameName n
		    addWarn InvalidDecl $ printf "Cannot declare '%s' in instance because it is not a method of class '%s'" (show n) (show chn)
		Nothing -> return ()
	return []

    f i@HsDeclDeriving {} = tcClassHead (hsDeclClassHead i)
    f (HsPragmaRules rs) = do
        rs' <- mapM tcRule rs
        return [HsPragmaRules rs']
    f fd@(HsForeignDecl _ _ n qt) = do
        kt <- getKindEnv
        s <- hsQualTypeToSigma kt qt
        addToCollectedEnv (Map.singleton (toName Val n) s)
        return []
    f fd@(HsForeignExport _ e n qt) = do
        kt <- getKindEnv
        s <- hsQualTypeToSigma kt qt
        addToCollectedEnv (Map.singleton (ffiExportName e) s)
        return []
    f _ = return []
    tcClassHead cHead@HsClassHead { .. } = do
        ch <- getClassHierarchy
        ke <- getKindEnv
        let supers = asksClassRecord ch hsClassHead classSupers
            (ctx,(_,[a])) = chToClassHead ke cHead
        assertEntailment ctx [ IsIn s a | s <- supers]
        return []

tcRule prule@HsRule { hsRuleUniq = uniq, hsRuleFreeVars = vs, hsRuleLeftExpr = e1, hsRuleRightExpr = e2, hsRuleSrcLoc = sloc } =
    withContext (locMsg sloc "in the RULES pragma" $ hsRuleString prule) ans where
        ans = do
            vs' <- mapM dv vs
            tr <- newBox kindStar
            let (vs,envs) = unzip vs'
            ch <- getClassHierarchy
            ((e1,rs1),(e2,rs2)) <- localEnv (mconcat envs) $ do
                    (e1,ps1) <- listenPreds (tcExpr e1 tr)
                    (e2,ps2) <- listenPreds (tcExpr e2 tr)
                    ([],rs1) <- splitPreds ch Set.empty ps1
                    ([],rs2) <- splitPreds ch Set.empty ps2
                    return ((e1,rs1),(e2,rs2))
            mapM_ unBox vs
            vs <- flattenType vs
            tr <- flattenType tr
            let mvs = Set.toList $ Set.unions $ map freeMetaVars (tr:vs)
            nvs <- mapM (newVar . metaKind) mvs
            sequence_ [ varBind mv (TVar v) | v <- nvs |  mv <- mvs ]
            (rs1,rs2) <- flattenType (rs1,rs2)
            ch <- getClassHierarchy
            rs1 <- return $ simplify ch rs1
            rs2 <- return $ simplify ch rs2
            assertEntailment rs1 rs2
            return prule { hsRuleLeftExpr = e1, hsRuleRightExpr = e2 }
        dv (n,Nothing) = do
            v <- newMetaVar Tau kindStar
            let env = (Map.singleton (toName Val n) v)
            addToCollectedEnv env
            return (v,env)
        dv (n,Just t) = do
            kt <- getKindEnv
            tt <- hsTypeToType kt t
            let env = (Map.singleton (toName Val n) tt)
            addToCollectedEnv env
            return (tt,env)

tcDecl ::  HsDecl -> Sigma -> Tc (HsDecl,TypeEnv)
tcDecl decl typ = do
    dndecl <- prettyName decl
    withSrcLoc (srcLoc decl) $ withContext (declDiagnostic dndecl) $ tiDecl decl typ

tiDecl decl@(HsActionDecl srcLoc pat@(HsPVar v) exp) typ = do
    typ <- evalType typ
    (pat',env) <- tcPat pat typ
    let tio = TCon (Tycon tc_IO (Kfun kindStar kindStar))
    e' <- tcExpr exp (TAp tio typ)
    return (decl { hsDeclPat = pat', hsDeclExp = e' }, Map.singleton (toName Val v) typ)

tiDecl (HsPatBind sloc (HsPVar v) rhs wheres) typ = do
    typ <- evalType typ
    mainFunc <- nameOfMainFunc
    when ( v == mainFunc ) $ do
       tMain <- typeOfMainFunc
       typ `subsumes` tMain
       return ()
    (wheres', env) <- tcWheres wheres
    localEnv env $ do
    case rhs of
        HsUnGuardedRhs e -> do
            e' <- tcExpr e typ
            return (HsPatBind sloc (HsPVar v) (HsUnGuardedRhs e') wheres', Map.singleton (toName Val v) typ)
        HsGuardedRhss as -> do
            gas <- mapM (tcGuardedRhs typ) as
            return (HsPatBind sloc (HsPVar v) (HsGuardedRhss gas) wheres', Map.singleton (toName Val v) typ)

tiDecl decl@(HsFunBind matches) typ = do
    typ <- evalType typ
    matches' <- mapM (`tcMatch` typ) matches
    return (HsFunBind matches', Map.singleton (getDeclName decl) typ)

tiDecl _ _ = error "Main.tcDecl: bad."

tcMatch ::  HsMatch -> Sigma -> Tc HsMatch
tcMatch (HsMatch sloc funName pats rhs wheres) typ = withContext (locMsg sloc "in" $ show funName) $ do
    let lam (p:ps) (TMetaVar mv) rs = do -- ABS2
            withMetaVars mv [kindArg,kindFunRet] (\ [a,b] -> a `fn` b) $ \ [a,b] -> lam (p:ps) (a `fn` b) rs
        lam (p:ps) ty@(TArrow s1' s2') rs = do -- ABS1
            (p',env) <- tcPat p s1'
            localEnv env $ do
                s2' <- evalType s2'
                lamPoly ps s2' (p':rs)
        lam [] typ rs = do
            (wheres', env) <- tcWheres wheres
            rhs <- localEnv env $ tcRhs rhs typ
            return (HsMatch sloc funName (reverse rs) rhs wheres')
        lam _ t _ = do
            t <- flattenType t
            fail $ "expected a -> b, found: " ++ prettyPrintType t
        lamPoly ps s@TMetaVar {} rs = lam ps s rs
        lamPoly ps s rs = do
            (_,_,s) <- skolomize s
            lam ps s rs
    typ <- evalType typ
    res <- lam pats typ []
    return res

typeOfMainFunc :: Tc Type
typeOfMainFunc = do
    a <- newMetaVar Tau kindStar
    -- a <- newMetaVar Tau kindStar
    -- a <- Tvar `fmap` newVar kindStar
    return $ tAp (TCon (Tycon tc_IO (Kfun kindStar kindStar))) a

nameOfMainFunc :: Tc Name
nameOfMainFunc = fmap (parseName Val . maybe "Main.main" snd . optMainFunc) getOptions

declDiagnostic ::  HsDecl -> Diagnostic
declDiagnostic decl@(HsPatBind sloc (HsPVar {}) _ _) = locMsg sloc "in the declaration" $ render $ ppHsDecl decl
declDiagnostic decl@(HsPatBind sloc pat _ _) = locMsg sloc "in the pattern binding" $ render $ ppHsDecl decl
declDiagnostic decl@(HsFunBind matches) = locMsg (srcLoc decl) "in the function binding" $ render $ ppHsDecl decl
declDiagnostic _ = error "Main.declDiagnostic: bad."

tiExpl ::  Expl -> Tc (HsDecl,TypeEnv)
tiExpl (sc, decl@HsForeignDecl {}) = do return (decl,Map.empty)
tiExpl (sc, decl@HsForeignExport {}) = do return (decl,Map.empty)
tiExpl (sc, decl) = do
    rndecl <- prettyName decl
    withContext (locSimple (srcLoc decl) ("in the explicitly typed:\n" ++  (render $ ppHsDecl rndecl))) $ do
    when (dump FD.BoxySteps) $ liftIO $ putStrLn $ "** typing expl: " ++ show (getDeclNames decl) ++ " " ++ prettyPrintType sc
    sc <- evalFullType sc
    (vs,qs,typ) <- skolomize sc
    let sc' = (tForAll vs (qs :=> typ))
        mp = (Map.singleton (getDeclName decl) sc')
    addCoerce (getDeclName decl) (ctAbs vs)
    addToCollectedEnv mp
    (ret,ps) <- localEnv mp $ listenPreds (tcDecl decl typ)
    ps <- flattenType ps
    ch <- getClassHierarchy
    env <- freeMetaVarsEnv
    (_,ds,rs) <- splitReduce env (freeMetaVarsPreds qs) ps
    printRule $ "endtiExpl: " <+> show env <+> show ps <+> show qs <+> show ds <+> show rs
    addPreds ds
    assertEntailment qs rs
    return ret

restricted :: Bool -> [HsDecl] -> Bool
restricted monomorphismRestriction bs = any isHsActionDecl bs || (monomorphismRestriction && any isHsPatBind bs)

--getBindGroupName (expl,impls) =  map getDeclName (snds expl ++ concat (rights impls) ++ lefts impls)

tiProgram ::  [BindGroup] -> [HsDecl] -> Tc [HsDecl]
tiProgram bgs es = ans where
    ans = do
        let (pr,is) = progressStep (progressNew (length bgs + 1) 45) '.'
        wdump FD.Progress $ liftIO $ do hPutStr stderr ("(" ++ is)
        (r,ps) <- listenPreds $ f pr bgs []
        ps <- flattenType ps
--        ch <- getClassHierarchy
    --    ([],rs) <- splitPreds ch Set.empty ps
--        liftIO $ print ps
        (_,[],rs) <- splitReduce Set.empty Set.empty ps
 --       liftIO $ print rs
        topDefaults rs
        return r
    f pr (bg:bgs) rs  = do
        (ds,env) <- (tcBindGroup bg)
        let (pr',os) = progressStep pr '.'
        wdump FD.Progress $ liftIO $ do hPutStr stderr os
        localEnv env $ f pr' bgs (ds ++ rs)
    f _ [] rs = do
        ch <- getClassHierarchy
        pdecls <- mapM tcMiscDecl es
        wdump FD.Progress $ liftIO $ do hPutStr stderr ")\n"
        return (rs ++ concat pdecls)

-- Typing Literals

tiLit :: HsLiteral -> Tc Tau
tiLit (HsChar _) = return tChar
tiLit (HsCharPrim _) = return tCharzh
tiLit (HsInt _) = do
    v <- newVar kindStar
    return $ TForAll [v] ([IsIn class_Num (TVar v)] :=> TVar v)
    --(v) <- newBox Star
    --addPreds [IsIn class_Num v]
    --return v

tiLit (HsFrac _) = do
    v <- newVar kindStar
    return $ TForAll [v] ([IsIn class_Fractional (TVar v)] :=> TVar v)
    --    (v) <- newBox Star
    --    addPreds [IsIn class_Fractional v]
    --    return v

tiLit (HsStringPrim _)  = return (TCon (Tycon tc_BitsPtr kindHash))
tiLit (HsString _)  = return tString
tiLit _ = error "Main.tiLit: bad."

tiLambda sloc ps e typ  = do
    let lam (p:ps) e (TMetaVar mv) rs = do -- ABS2
            withMetaVars mv [kindArg,kindFunRet] (\ [a,b] -> a `fn` b) $ \ [a,b] -> lam (p:ps) e (a `fn` b) rs
        lam (p:ps) e (TArrow s1' s2') rs = do -- ABS1
            --box <- newBox Star
            --s1' `boxyMatch` box
            (p',env) <- tcPat p s1'
            localEnv env $ do
                s2' <- evalType s2'
                lamPoly ps e s2' (p':rs)  -- TODO poly
        lam (p:ps) e t@(TAp (TAp (TMetaVar mv) s1') s2') rs = do
            boxyMatch (TMetaVar mv) tArrow
            (p',env) <- tcPat p s1'
            localEnv env $ do
                s2' <- evalType s2'
                lamPoly ps e s2' (p':rs)  -- TODO poly
        lam [] e typ rs = do
            e' <- tcExpr e typ
            return (HsLambda sloc (reverse rs) e')
        lam _ _ t _ = do
            t <- flattenType t
            fail $ "expected a -> b, found: " ++ prettyPrintType t
        lamPoly ps e s rs = do
            (ts,_,s) <- skolomize s
            e <- lam ps e s rs
            doCoerce (ctAbs ts) e
    lam ps e typ []

------------------------------------------
-- Binding analysis and program generation
------------------------------------------

-- create a Program structure from a list of decls and
-- type sigs. Type sigs are associated with corresponding
-- decls if they exist

getFunDeclsBg :: TypeEnv -> [HsDecl] -> [BindGroup]
getFunDeclsBg sigEnv decls = makeProgram sigEnv equationGroups where
   equationGroups :: [[HsDecl]]
   equationGroups = map f $ getBindGroups bindDecls getDeclNames getDeclDeps
   bindDecls = collectBindDecls decls
   f (Left xs) = xs
   f (Right xss) = concat xss

-- | make a program from a set of binding groups
makeProgram :: TypeEnv -> [[HsDecl]] -> [BindGroup]
makeProgram sigEnv groups = map (makeBindGroup sigEnv ) groups

-- | reunite decls with their signatures, if ever they had one

makeBindGroup :: TypeEnv -> [HsDecl] -> BindGroup
makeBindGroup sigEnv decls = (exps, f impls) where
    (exps, impls) = makeBindGroup' sigEnv decls
    enames = map (getDeclName . snd) exps
    f xs = map g $ getBindGroups xs getDeclNames  (\x -> [ d | d <- getDeclDeps x, d `notElem` enames])
    g (Left ~[x]) = Left x
    g (Right xss) = Right $ concat xss
--    f xs = map g $ stronglyConnComp [ (x, getDeclName x,[ d | d <- getDeclDeps x, d `notElem` enames]) |  x <- xs]
--    g (AcyclicSCC x) = Left x
--    g (CyclicSCC xs) = Right xs

makeBindGroup' _ [] = ([], [])
makeBindGroup' sigEnv (d:ds) = case Map.lookup funName sigEnv of
        Nothing -> (restExpls, d:restImpls)
        Just scheme -> ((scheme, d):restExpls, restImpls)
   where
   funName = getDeclName d
   (restExpls, restImpls) = makeBindGroup' sigEnv ds

collectBindDecls :: [HsDecl] ->  [HsDecl]
collectBindDecls = filter isBindDecl where
    isBindDecl :: HsDecl -> Bool
    isBindDecl HsActionDecl {} = True
    isBindDecl HsPatBind {} = True
    isBindDecl HsFunBind {} = True
    isBindDecl _ = False

from2Ty (TArrow a b) = Just (tArrow,a,b)
from2Ty (TAp (TAp mv a) b) = Just (mv,a,b)
from2Ty _ = Nothing
