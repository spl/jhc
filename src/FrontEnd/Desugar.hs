    -- various desugaring routines
--
-- The general desugaring routine creates selectors for data
-- constructors with named fields, changes all pattern bindings
-- into 'simple' pattern bindings, and adds failure cases to lambda
-- expressions which have failable patterns

module FrontEnd.Desugar (desugarHsModule, desugarHsStmt,listCompToExp, doToExp) where

import FrontEnd.Syn.Traverse
import Name.Names
import Ty.Level
import Util.Std
import Util.UniqueMonad

type PatSM = Uniq

instance MonadSrcLoc PatSM where
instance MonadSetSrcLoc PatSM where
    withSrcLoc' _ a = a

-- a new (unique) name introduced in pattern selector functions
newPatVarName :: HsName
newPatVarName = toName Val ("pv@"::String)

desugarHsModule :: HsModule -> HsModule
--desugarHsModule m = m
desugarHsModule m = hsModuleDecls_s ds' m where
    (ds', _) = runUniq 0 (dsm (hsModuleDecls m)) -- (0::Int)
    dsm ds = fmap concat $ mapM desugarDecl ds

desugarHsStmt :: Monad m => HsStmt -> m HsStmt
desugarHsStmt s = return $ fst $ runUniq 0 (desugarStmt s)

desugarDecl :: HsDecl -> PatSM [HsDecl]
desugarDecl (HsFunBind matches) = do
    newMatches <- mapM desugarMatch matches
    return [HsFunBind newMatches]

--variable pattern bindings remain unchanged
desugarDecl HsPatBind { hsDeclPat = hsDeclPat@HsPVar {}, .. } = do
    hsDeclRhs <- desugarRhs hsDeclRhs
    hsDeclDecls <- concat <$> mapM desugarDecl hsDeclDecls
    return [HsPatBind { .. }]
--desugarDecl (HsPatBind sloc pat rhs wheres) = do
desugarDecl HsPatBind { .. } = do
    hsDeclRhs <- desugarRhs hsDeclRhs
    hsDeclDecls <- concat <$> mapM desugarDecl hsDeclDecls
    unique <- newUniq
    let newRhsName = toName Val ("rhs@" ++ show unique)
    let newBinds = genBindsForPat hsDeclPat hsDeclSrcLoc newRhsName
    newBinds <- concat <$> mapM desugarDecl newBinds
    let newTopDeclForRhs = HsPatBind { hsDeclPat = HsPVar newRhsName, .. }
    return (newTopDeclForRhs : newBinds)
desugarDecl HsInstDecl { .. } = do
    hsDeclDecls <- concat <$> mapM desugarDecl hsDeclDecls
    return [HsInstDecl { .. }]
desugarDecl HsClassDecl { .. } = do
    hsDeclDecls <- concat <$> mapM desugarDecl hsDeclDecls
    return [HsClassDecl { .. }]
-- XXX we currently discard instance specializations
desugarDecl HsPragmaSpecialize { hsDeclName = n } | n == u_instance = return []
desugarDecl anyOtherDecl = return [anyOtherDecl]

desugarMatch :: (HsMatch) -> PatSM (HsMatch)
desugarMatch (HsMatch sloc funName pats rhs wheres) = do
        newWheres <- mapM desugarDecl wheres
        newRhs <- desugarRhs rhs
        return (HsMatch sloc funName pats newRhs (concat newWheres))

-- generate the pattern bindings for each variable in a pattern

genBindsForPat :: HsPat -> SrcLoc -> HsName -> [HsDecl]
genBindsForPat pat sloc rhs = ans where
    ans = [HsPatBind sloc (HsPVar pn) (HsUnGuardedRhs selector) [] | (pn, selector) <- selFuns]
    selFuns = getPatSelFuns sloc pat rhs

-- generate selector functions for each of the variables that
-- are bound in a pattern

getPatSelFuns :: SrcLoc -> HsPat -> Name -> [(Name, HsExp)]
getPatSelFuns sloc pat rhsvar = ans where
    ans = [(v, kase (replaceVarNamesInPat v pat)) | v <- getNamesFromHsPat pat, nameType v == Val]
    kase p =  HsCase (HsVar rhsvar) [a1, a2 ] where
       a1 =  HsAlt sloc p (HsUnGuardedRhs (HsVar newPatVarName)) []
       a2 =  HsAlt sloc HsPWildCard (HsUnGuardedRhs (HsError { hsExpSrcLoc = sloc, hsExpErrorType = HsErrorPatternFailure, hsExpString = show sloc ++ " failed pattern match" })) []

-- replaces all occurrences of a name with a new variable
-- and every other name with underscore

replaceVarNamesInPat :: HsName -> HsPat -> HsPat
replaceVarNamesInPat name p = f p where
    f (HsPVar name2)
       | name == name2 = HsPVar newPatVarName
       | getTyLevel name2 == Just termLevel = HsPWildCard
    f (HsPAsPat asName pat)
       | name == asName = HsPAsPat newPatVarName (f pat)
       | getTyLevel asName == Just termLevel = f pat
    f p = runIdentity $ traverseHsPat (return . f) p

--    f name p = error $ "replaceVarNamesInPat: " ++ show (name,p)

desugarRhs :: HsRhs -> PatSM HsRhs
desugarRhs  = traverseHsExp desugarExp

desugarExp :: HsExp -> PatSM HsExp
desugarExp (HsLambda sloc pats e)
    | all isSimplePat pats  = do
        newE <- desugarExp e
        return (HsLambda sloc pats newE)
desugarExp (HsLambda sloc pats e) = do
        ps <- mapM f pats
        let (xs,zs) = unzip ps
        e' <- (ne e $ concat zs)
        return (HsLambda sloc (map HsPVar xs) e')
    where
    ne e [] = desugarExp e
    ne e ((n,p):zs) =  do
        e' <- ne e zs
        let a1 =  HsAlt sloc p (HsUnGuardedRhs e') []
            a2 =  HsAlt sloc HsPWildCard (HsUnGuardedRhs (HsError { hsExpSrcLoc = sloc, hsExpErrorType = HsErrorPatternFailure, hsExpString = show sloc ++ " failed pattern match in lambda" })) []
        return $ HsCase (HsVar n) [a1, a2 ]

    f (HsPVar x) = return (x,[])
    f (HsPAsPat n p) = return (n,[(n,p)])
    f p = do
        unique <- newUniq
        let n = toName Val ("lambind@" ++ show unique)
        return (n,[(n,p)])
desugarExp (HsLet decls e) = do
    newDecls <- mapM desugarDecl decls
    HsLet (concat newDecls) <$> desugarExp e
desugarExp (HsCase e alts) = do
    newE <- desugarExp e
    newAlts <- mapM desugarAlt alts
    return (HsCase newE newAlts)
desugarExp (HsDo stmts) = HsDo `liftM` mapM desugarStmt stmts
desugarExp e = traverseHsExp desugarExp e

desugarAlt :: (HsAlt) -> PatSM (HsAlt)
desugarAlt (HsAlt sloc pat gAlts wheres) = do
    newGAlts <- desugarRhs gAlts
    newWheres <- mapM desugarDecl wheres
    return (HsAlt sloc pat newGAlts (concat newWheres))

desugarStmt :: (HsStmt) -> PatSM (HsStmt)
desugarStmt (HsLetStmt decls) = do
    newDecls <- mapM desugarDecl decls
    return (HsLetStmt $ concat newDecls)
desugarStmt (HsGenerator srcLoc pat e) = HsGenerator srcLoc pat <$> desugarExp e
desugarStmt (HsQualifier e) = HsQualifier <$> desugarExp e

listCompToExp :: Monad m => m HsName -> HsExp -> [HsStmt] -> m HsExp
listCompToExp newName exp ss = hsParen `liftM` f ss where
    f [] = return $ HsList [exp]
    f (gen:HsQualifier q1:HsQualifier q2:ss)  = f (gen:HsQualifier (hsApp (HsVar v_and) [q1,q2]):ss)
    f ((HsLetStmt ds):ss) = do ss' <- f ss; return $ hsParen (HsLet ds ss')
    f (HsQualifier e:ss) = do ss' <- f ss; return $ hsParen (HsIf e ss' (HsList []))
    f ((HsGenerator srcLoc pat e):ss) | isLazyPat pat, Just exp' <- g ss = do
        return $ hsParen $ HsVar v_map `app` HsLambda srcLoc [pat] exp' `app` e
    f ((HsGenerator srcLoc pat e):HsQualifier q:ss) | isLazyPat pat, Just exp' <- g ss = do
        npvar <- newName
        return $ hsApp (HsVar v_foldr)  [HsLambda srcLoc [pat,HsPVar npvar] $
            hsIf q (hsApp (HsCon dc_Cons) [exp',HsVar npvar]) (HsVar npvar), HsList [],e]
    f ((HsGenerator srcLoc pat e):ss) | isLazyPat pat = do
        ss' <- f ss
        return $ hsParen $ HsVar v_concatMap `app`  HsLambda srcLoc [pat] ss' `app` e
    f ((HsGenerator srcLoc pat e):HsQualifier q:ss) | isFailablePat pat || Nothing == g ss = do
        ss' <- f ss
        let kase = HsLCase  [a1, a2 ]
            a1 =  HsAlt srcLoc pat (HsGuardedRhss [HsComp srcLoc [HsQualifier q] ss']) []
            a2 =  HsAlt srcLoc HsPWildCard (HsUnGuardedRhs $ HsList []) []
        return $ hsParen $ HsVar v_concatMap `app` kase `app`  e
    f ((HsGenerator srcLoc pat e):ss) | isFailablePat pat || Nothing == g ss = do
        ss' <- f ss
        let kase = HsLCase [a1, a2 ]
            a1 =  HsAlt srcLoc pat (HsUnGuardedRhs ss') []
            a2 =  HsAlt srcLoc HsPWildCard (HsUnGuardedRhs $ HsList []) []
        return $ hsParen $ HsVar v_concatMap `app` kase `app` e
    f ((HsGenerator srcLoc pat e):ss) = do
        let Just exp' = g ss
            kase = HsLCase [a1]
            a1 =  HsAlt srcLoc pat (HsUnGuardedRhs exp') []
        return $ hsParen $ HsVar v_map `app` kase `app` e
    -- f ((HsGenerator srcLoc pat e):HsQualifier q:ss) | isFailablePat pat || Nothing == g ss = do
    --     npvar <- newName
    --     ss' <- f ss
    --     let kase = HsCase (HsVar npvar) [a1, a2 ]
    --         a1 =  HsAlt srcLoc pat (HsGuardedRhss [HsComp srcLoc [HsQualifier q] ss']) []
    --         a2 =  HsAlt srcLoc HsPWildCard (HsUnGuardedRhs $ HsList []) []
    --     return $ hsParen $ HsVar v_concatMap `app`  HsLambda srcLoc [HsPVar npvar] kase `app`  e
    -- f ((HsGenerator srcLoc pat e):ss) | isFailablePat pat || Nothing == g ss = do
    --     npvar <- newName
    --     ss' <- f ss
    --     let kase = HsCase (HsVar npvar) [a1, a2 ]
    --         a1 =  HsAlt srcLoc pat (HsUnGuardedRhs ss') []
    --         a2 =  HsAlt srcLoc HsPWildCard (HsUnGuardedRhs $ HsList []) []
    --     return $ hsParen $ HsVar v_concatMap `app` HsLambda srcLoc [HsPVar npvar] kase `app` e
    -- f ((HsGenerator srcLoc pat e):ss) = do
    --     npvar <- newName
    --     let Just exp' = g ss
    --         kase = HsCase (HsVar npvar) [a1 ]
    --         a1 =  HsAlt srcLoc pat (HsUnGuardedRhs exp') []
    --     return $ hsParen $ HsVar v_map `app` HsLambda srcLoc [HsPVar npvar] kase `app` e
    g [] = return exp
    g (HsLetStmt ds:ss) = do
        e <- g ss
        return (hsParen (HsLet ds e))
    g _ = Nothing
    app x y = HsApp x (hsParen y)

-- patterns are
-- failable - strict and may fail to match
-- refutable or strict - may bottom out
-- irrefutable or lazy - match no matter what
-- simple, a wildcard or variable
-- failable is a subset of refutable

isFailablePat p | isStrictPat p = f (openPat p) where
    f (HsPTuple ps) = any isFailablePat ps
    f (HsPUnboxedTuple ps) = any isFailablePat ps
    f (HsPBangPat (Located _ p)) = isFailablePat p
    f _ = True
isFailablePat _ = False

isSimplePat p = f (openPat p) where
    f HsPVar {} = True
    f HsPWildCard = True
    f _ = False

isLazyPat pat = not (isStrictPat pat)
isStrictPat p = f (openPat p) where
    f HsPVar {} = False
    f HsPWildCard = False
    f (HsPAsPat _ p) = isStrictPat p
    f (HsPParen p) = isStrictPat p
    f (HsPIrrPat p) = False -- isStrictPat p  -- TODO irrefutable patterns
    f _ = True

openPat (HsPParen p) = openPat p
openPat (HsPNeg p) = openPat p
openPat (HsPAsPat _ p) = openPat p
openPat (HsPTypeSig _ p _) = openPat p
openPat (HsPInfixApp a n b) = HsPApp n [a,b]
openPat p = p

hsApp e es = hsParen $ foldl HsApp (hsParen e) (map hsParen es)
hsIf e a b = hsParen $ HsIf e a b

doToExp :: Monad m
    => m HsName    -- ^ name generator
    -> HsName      -- ^ bind (>>=) to use
    -> HsName      -- ^ bind_ (>>) to use
    -> HsName      -- ^ fail to use
    -> [HsStmt]
    -> m HsExp
doToExp newName f_bind f_bind_ f_fail ss = hsParen `liftM` f ss where
    f [] = fail "doToExp: empty statements in do notation"
    f [HsQualifier e] = return e
    f [gen@(HsGenerator srcLoc _pat _e)] = fail $ "doToExp: last expression n do notation is a generator (srcLoc):" ++ show srcLoc
    f [letst@(HsLetStmt _decls)] = fail $ "doToExp: last expression n do notation is a let statement"
    f (HsQualifier e:ss) = do
        ss <- f ss
        return $ HsInfixApp (hsParen e) (HsVar f_bind_) (hsParen ss)
    f ((HsGenerator _srcLoc pat e):ss) | isSimplePat pat = do
        ss <- f ss
        return $ HsInfixApp (hsParen e) (HsVar f_bind) (HsLambda _srcLoc [pat] ss)
    f ((HsGenerator srcLoc pat e):ss) = do
        ss <- f ss
        let kase = HsLCase [a1, a2 ]
            a1 =  HsAlt srcLoc pat (HsUnGuardedRhs ss) []
            a2 =  HsAlt srcLoc HsPWildCard (HsUnGuardedRhs (HsApp (HsVar f_fail) (HsLit $ HsString $ show srcLoc ++ " failed pattern match in do"))) []
        return $ HsInfixApp (hsParen e) (HsVar f_bind) kase  where
    f (HsLetStmt decls:ss) = do
        ss <- f ss
        return $ HsLet decls ss
