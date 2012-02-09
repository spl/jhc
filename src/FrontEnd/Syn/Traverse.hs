module FrontEnd.Syn.Traverse where

import Control.Monad.Writer
import qualified Data.Set as Set
import qualified Data.Traversable as T

import FrontEnd.HsSyn
import FrontEnd.SrcLoc
import Name.Name
import Support.FreeVars

--instance FreeVars HsType (Set.Set HsName) where
--    freeVars t = execWriter (f t) where
--        f (HsTyVar v) = tell (Set.singleton v)
--        f t = traverseHsType_ f t

instance FreeVars HsType (Set.Set Name) where
    freeVars t = execWriter (f t) where
        f (HsTyVar v) = tell (Set.singleton $ toName TypeVal v)
        f (HsTyCon v) = tell (Set.singleton $ toName TypeConstructor v)
        f t = traverseHsType_ f t

traverse_ :: Monad m => (a -> m b) -> a -> m a
traverse_ fn x = fn x >> return x

traverseHsExp_ :: MonadSetSrcLoc m => (HsExp -> m ()) -> HsExp -> m ()
traverseHsExp_ fn e = traverseHsExp (traverse_ fn) e >> return ()

traverseHsExp :: MonadSetSrcLoc m => (HsExp -> m HsExp) -> HsExp -> m HsExp
traverseHsExp fn e = f e where
    fns = mapM fn
    f e@HsVar {} = return e
    f e@HsCon {} = return e
    f e@HsLit {} = return e
    f e@HsError {} = return e
    f (HsInfixApp hsExp1 hsExp2 hsExp3) = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        hsExp3' <- fn hsExp3
        return (HsInfixApp hsExp1' hsExp2' hsExp3')
    f (HsApp hsExp1 hsExp2)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        return (HsApp hsExp1' hsExp2')
    f (HsNegApp hsExp)  = do
        hsExp' <- fn hsExp
        return (HsNegApp hsExp')
    f (HsLambda srcLoc hsPats hsExp) = withSrcLoc srcLoc $ do
        hsExp' <- fn hsExp
        return (HsLambda srcLoc hsPats hsExp')
    f (HsIf hsExp1 hsExp2 hsExp3)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        hsExp3' <- fn hsExp3
        return (HsIf hsExp1' hsExp2' hsExp3')
    f (HsTuple hsExps)  = do
        hsExps' <- fns hsExps
        return (HsTuple hsExps')
    f (HsUnboxedTuple hsExps)  = do
        hsExps' <- fns hsExps
        return (HsUnboxedTuple hsExps')
    f (HsList hsExps)  = do
        hsExps' <- fns hsExps
        return (HsList hsExps')
    f (HsParen hsExp)  = do
        hsExp' <- fn hsExp
        return (HsParen hsExp')
    f (HsLeftSection hsExp1 hsExp2)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        return (HsLeftSection hsExp1' hsExp2')
    f (HsRightSection hsExp1 hsExp2)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        return (HsRightSection hsExp1' hsExp2')
    f (HsEnumFrom hsExp)  = do
        hsExp' <- fn hsExp
        return (HsEnumFrom hsExp')
    f (HsEnumFromTo hsExp1 hsExp2)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        return (HsEnumFromTo hsExp1' hsExp2')
    f (HsEnumFromThen hsExp1 hsExp2)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        return (HsEnumFromThen hsExp1' hsExp2')
    f (HsEnumFromThenTo hsExp1 hsExp2 hsExp3)  = do
        hsExp1' <- fn hsExp1
        hsExp2' <- fn hsExp2
        hsExp3' <- fn hsExp3
        return (HsEnumFromThenTo hsExp1' hsExp2' hsExp3')
    f (HsExpTypeSig srcLoc hsExp hsQualType)  = withSrcLoc srcLoc $ do
        hsExp' <- fn hsExp
        return (HsExpTypeSig srcLoc hsExp' hsQualType)
    f (HsAsPat hsName hsExp)  = do
        hsExp' <- fn hsExp
        return (HsAsPat hsName hsExp')
    f (HsWildCard x) = do return (HsWildCard x)
    f (HsIrrPat hsExp)  = do
        hsExp' <- fnl hsExp
        return (HsIrrPat hsExp')
    f (HsBangPat hsExp)  = do
        hsExp' <- fnl hsExp
        return (HsBangPat hsExp')
    f (HsRecConstr n fus) = do
        fus' <- mapM fFieldUpdate fus
        return $ HsRecConstr n fus'
    f (HsRecUpdate e fus) = do
        fus' <- mapM fFieldUpdate fus
        e' <- fn e
        return $ HsRecUpdate e' fus'
    f (HsLocatedExp le) = HsLocatedExp `liftM` fnl le
    f (HsLet hsDecls hsExp)  = do
        ds <- mapM (traverseHsDeclHsExp fn) hsDecls
        e <- fn hsExp
        return $ HsLet ds e
    f (HsDo hsStmts)  = HsDo `liftM` mapM (traverseHsStmtHsExp fn) hsStmts
    f _ = error "FrontEnd.Syn.Traverse.traverseHsExp f unrecognized construct"
    fFieldUpdate (HsFieldUpdate n e) = do
        e' <- fn e
        return $ HsFieldUpdate n e'
    fnl (Located l e) = withSrcSpan l $ Located l `liftM` fn e

    {-
-- not done
    f (HsRecUpdate hsExp hsFieldUpdates)  = do
        hsExp' <- fn hsExp
        hsFieldUpdates' <- renameHsFieldUpdates hsFieldUpdates
        return (HsRecUpdate hsExp' hsFieldUpdates')
    fn (HsRecConstr hsName hsFieldUpdates)  = do
        hsName' <- renameHsName hsName   -- do I need to change this name?
        hsFieldUpdates' <- renameHsFieldUpdates hsFieldUpdates
        return (HsRecConstr hsName' hsFieldUpdates')
--    fn (HsCase hsExp hsAlts)  = do
--        hsExp' <- fn hsExp
--        hsAlts' <- renameHsAlts hsAlts
--        return (HsCase hsExp' hsAlts')
--    fn (HsDo hsStmts)  = do
--        let e = doToExp hsStmts
--        fn e
        --(hsStmts',_) <- renameHsStmts hsStmts
        --return (doToExp hsStmts')
    fn (HsListComp hsExp hsStmts)  = do
        (hsStmts',') <- renameHsStmts hsStmts
        hsExp' <- fn hsExp '
        return (HsListComp hsExp' hsStmts')
    fn (HsLet hsDecls hsExp)  = do
        ' <- updateSubTableWithHsDecls  hsDecls LetFun
        hsDecls' <- renameHsDecls hsDecls '
        hsExp' <- fn hsExp '
        return (HsLet hsDecls' hsExp')

-}

traverseHsType_ :: Monad m => (HsType -> m b) -> HsType -> m ()
traverseHsType_ fn p = traverseHsType (traverse_ fn) p >> return ()

traverseHsType :: Monad m => (HsType -> m HsType) -> HsType -> m HsType
traverseHsType f (HsTyFun a b) = return HsTyFun `ap` f a `ap` f b
traverseHsType f (HsTyTuple xs) = do
    xs <- mapM f xs
    return $ HsTyTuple xs
traverseHsType f (HsTyUnboxedTuple xs) = do
    xs <- mapM f xs
    return $ HsTyUnboxedTuple xs
traverseHsType f (HsTyApp a b) = return HsTyApp `ap` f a `ap` f b
traverseHsType f (HsTyForall vs qt) = doQual HsTyForall f vs qt
traverseHsType f (HsTyExists vs qt) = doQual HsTyExists f vs qt
traverseHsType _ x@HsTyVar {} = return x
traverseHsType _ x@HsTyCon {} = return x
traverseHsType f HsTyExpKind { .. } = do
    hsTyLType <- T.mapM f hsTyLType
    return HsTyExpKind { .. }
traverseHsType f (HsTyEq a b) = return HsTyEq `ap` f a `ap` f b
traverseHsType f (HsTyStrictType a b ) = return HsTyStrictType `ap` return a `ap` T.mapM f b
traverseHsType _ HsTyAssoc = return HsTyAssoc

doQual :: Monad m => (a -> HsQualType -> b) -> (HsType -> m HsType) -> a -> HsQualType -> m b
doQual hsTyForall f vs qt = do
    x <- f $ hsQualTypeType qt
    cntx <- flip mapM (hsQualTypeContext qt) $ \v -> case v of
        x@HsAsst {} -> return x
        HsAsstEq a b -> return HsAsstEq `ap` f a `ap` f b
    return $ hsTyForall vs qt { hsQualTypeContext = cntx, hsQualTypeType = x }

traverseHsPat_ :: MonadSetSrcLoc m => (HsPat -> m b) -> HsPat -> m ()
traverseHsPat_ fn p = traverseHsPat (traverse_ fn) p >> return ()

traverseHsPat :: MonadSetSrcLoc m => (HsPat -> m HsPat) -> HsPat -> m HsPat
traverseHsPat fn p = f p where
    f p@HsPVar {} = return p
    f p@HsPLit {} = return p
    f (HsPNeg hsPat)  = do
          hsPat' <- fn hsPat
          return (HsPNeg hsPat')
    f (HsPInfixApp hsPat1 hsName hsPat2)  = do
          hsPat1' <- fn hsPat1
          hsPat2' <- fn hsPat2
          return (HsPInfixApp hsPat1' hsName hsPat2')
    f (HsPApp hsName hsPats)  = do
          hsPats' <- mapM fn hsPats
          return (HsPApp hsName hsPats')
    f (HsPTuple hsPats)  = do
          hsPats' <- mapM fn hsPats
          return (HsPTuple hsPats')
    f (HsPUnboxedTuple hsPats)  = do
          hsPats' <- mapM fn hsPats
          return (HsPUnboxedTuple hsPats')
    f (HsPList hsPats)  = do
          hsPats' <- mapM fn hsPats
          return (HsPList hsPats')
    f (HsPParen hsPat)  = do
          hsPat' <- fn hsPat
          return (HsPParen hsPat')
    f (HsPAsPat hsName hsPat)  = do
          hsPat' <- fn hsPat
          return (HsPAsPat hsName hsPat')
    f HsPWildCard  = do return HsPWildCard
    f (HsPIrrPat hsPat)  = do
          hsPat' <- fnl hsPat
          return (HsPIrrPat hsPat')
    f (HsPBangPat hsPat)  = do
          hsPat' <- fnl hsPat
          return (HsPBangPat hsPat')
    f (HsPTypeSig srcLoc hsPat qt) = withSrcLoc srcLoc $ do
          hsPat' <- fn hsPat
          return (HsPTypeSig srcLoc hsPat' qt)
    f (HsPRec hsName hsPatFields)  = do
          hsPatFields' <- mapM fField hsPatFields
          return (HsPRec hsName hsPatFields')
    fField (HsPFieldPat n p) = fn p >>= return . HsPFieldPat n
    fnl (Located l e) = withSrcSpan l (Located l `liftM` fn e)

traverseHsRhsHsExp :: MonadSetSrcLoc m => (HsExp -> m HsExp) -> HsRhs -> m HsRhs
traverseHsRhsHsExp fn d = f d where
    f (HsUnGuardedRhs e) = fn e >>= return . HsUnGuardedRhs
    f (HsGuardedRhss rs) = return HsGuardedRhss `ap` mapM g rs
    g (HsGuardedRhs sl e1 e2) = return (HsGuardedRhs sl) `ap` fn e1 `ap` fn e2

traverseHsStmtHsExp :: MonadSetSrcLoc m => (HsExp -> m HsExp) -> HsStmt -> m HsStmt
traverseHsStmtHsExp fn d = f d where
    f (HsGenerator sl p e) = withSrcLoc sl $ HsGenerator sl p `liftM` fn e
    f (HsQualifier e) = HsQualifier `liftM` fn e
    f (HsLetStmt ds) = HsLetStmt `liftM` mapM (traverseHsDeclHsExp fn) ds

traverseHsDeclHsExp :: MonadSetSrcLoc m => (HsExp -> m HsExp) -> HsDecl -> m HsDecl
traverseHsDeclHsExp fn d = f d where
    f (HsPatBind srcLoc hsPat hsRhs {-where-} hsDecls) = withSrcLoc srcLoc $ do
        hsDecls'  <- mapM (traverseHsDeclHsExp fn) hsDecls
        hsRhs'    <- traverseHsRhsHsExp fn hsRhs
        return (HsPatBind srcLoc hsPat hsRhs' {-where-} hsDecls')
    f (HsActionDecl sl p e) = withSrcLoc sl $ do
        e <- fn e
        return $ HsActionDecl sl p e
--    f (HsFunBind hsMatches)  = do
--        hsMatches'     <- mapM (traverseHsMatchHsExp fn) hsMatches
--        return (HsFunBind hsMatches')
    f (HsClassDecl srcLoc hsQualType hsDecls)  = withSrcLoc srcLoc $ do
        hsDecls'  <- mapM (traverseHsDeclHsExp fn) hsDecls
        return (HsClassDecl srcLoc hsQualType hsDecls')
    f decl@(HsClassAliasDecl { hsDeclSrcLoc = sl})  = withSrcLoc sl $ do
        hsDecls'  <- mapM (traverseHsDeclHsExp fn) (hsDeclDecls decl)
        return (decl { hsDeclDecls = hsDecls' })
    f (HsInstDecl srcLoc hsQualType hsDecls)  = withSrcLoc srcLoc $ do
        hsDecls'  <- mapM (traverseHsDeclHsExp fn) hsDecls
        return (HsInstDecl srcLoc hsQualType hsDecls')
--    f prules@HsPragmaRules { hsDeclSrcLoc = srcLoc, hsDeclFreeVars = fvs, hsDeclLeftExpr = e1, hsDeclRightExpr = e2 }  = withSrcLoc srcLoc $ do
--        fvs' <- sequence [ fmapM (`renameHsType` ) t  >>= return . (,) n | (n,t) <- fvs]
--        e1' <- renameHsExp e1
--        e2' <- renameHsExp e2
--        return prules {  hsDeclFreeVars = fvs', hsDeclLeftExpr = e1', hsDeclRightExpr = e2' }
    f otherHsDecl = return otherHsDecl

getNamesFromHsPat :: HsPat -> [HsName]
getNamesFromHsPat p = execWriter (getNamesFromPat p) where
    getNamesFromPat (HsPVar hsName) = tell [toName Val hsName]
    getNamesFromPat (HsPAsPat hsName hsPat) = do
        tell [toName Val hsName]
        getNamesFromPat hsPat
    getNamesFromPat p = traverseHsPat_ getNamesFromPat p
