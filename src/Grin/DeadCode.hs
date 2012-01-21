{-# OPTIONS -XNoMonoLocalBinds #-}
module Grin.DeadCode(deadCode) where

import Control.Monad
import Data.Monoid
import qualified Data.Set as Set

import Fixer.Fixer
import Fixer.Supply
import Grin.Grin
import Grin.Noodle
import Grin.Whiz
import Stats hiding(print, singleton)
import StringTable.Atom
import Support.CanType
import Support.FreeVars
import Util.Gen
import Util.SetLike hiding(Value)

implies :: Value Bool -> Value Bool -> Rule
implies x y = y `isSuperSetOf` x

-- | Remove dead code from Grin.
deadCode ::
    Stats.Stats   -- ^ stats to update with what was done
    -> [Atom]  -- ^ roots
    -> Grin    -- ^ input
    -> IO Grin -- ^ output
deadCode stats roots grin = do
    fixer <- newFixer
    usedFuncs <- newSupply fixer
    usedArgs <- newSupply fixer
    usedCafs <- newSupply fixer
    pappFuncs <- newValue fixer bottom
    suspFuncs <- newValue fixer bottom
    -- set all roots as used
    flip mapM_ roots $ \r -> do
        addRule $ value True `implies` sValue usedFuncs r
    let postInline = phaseEvalInlined (grinPhase grin)

    forM_ (grinCafs grin) $ \ (v,NodeC t []) -> do
        (0,fn) <- tagUnfunction t
        v' <- supplyValue usedCafs v
        addRule $ conditionalRule id v' $ (suspFuncs `isSuperSetOf` value (singleton fn))
        addRule $ v' `implies` (sValue usedFuncs fn)

    mapM_ (go fixer pappFuncs suspFuncs usedFuncs usedArgs usedCafs postInline) (grinFuncs grin)
    findFixpoint Nothing {-"Dead Code"-} fixer
    ua <- supplyReadValues usedArgs
    uc <- supplyReadValues usedCafs
    uf <- supplyReadValues usedFuncs
    pappFuncs <- readValue pappFuncs
    suspFuncs <- readValue suspFuncs
    when False $ do
        putStrLn "usedArgs"
        mapM_ print ua
        putStrLn "usedCafs"
        mapM_ print uc
        putStrLn "usedFuncs"
        mapM_ print uf
        putStrLn "pappFuncs"
        print pappFuncs
        putStrLn "suspFuncs"
        print suspFuncs
    let cafSet = fg uc
        funSet = fg uf
        argSet = fg ua
                 `union`
                 fromList [ (n,i) | FuncDef n (args :-> _) _ _ <- grinFunctions grin,
                                        n `member` grinEntryPoints grin,
                                        i <- [0 .. length args] ]
        directFuncs =  funSet \\ suspFuncs \\ pappFuncs
        fg xs = fromList [ x | (x,True) <- xs ]
    newCafs <- flip mconcatMapM (grinCafs grin) $ \ (x,y) -> if x `member` cafSet then return [(x,y)] else tick stats "Optimize.dead-code.caf" >> return []
    let f ((x,y):xs) rs ws = do
            if not $ x `member` funSet then tick stats "Optimize.dead-code.func" >> f xs rs ws else do
            (ws',r) <- runStatIO stats $ removeDeadArgs postInline funSet directFuncs cafSet argSet (x,y) ws
            f xs (r:rs) ws'
        f [] rs _ = return rs
    newFuncs <- f (grinFuncs grin) [] whizState
    --newFuncs <- flip mconcatMapM (grinFuncs grin) $ \ (x,y) -> do
    let (TyEnv mp) = grinTypeEnv grin
    mp' <- flip mconcatMapM (toList mp) $ \ (x,tyty@TyTy { tySlots = ts }) -> case Just x  of
        Just _ | tagIsFunction x, not $ x `member` funSet -> return []
        Just fn | fn `member` directFuncs -> do
            let da (t,i)
                    | member (fn,i) argSet = return [t]
                    | otherwise = tick stats ("Optimize.dead-code.arg-func.{" ++ show x ++ "-" ++ show i) >> return []
            ts' <- mconcatMapM da (zip ts naturals)
            return [(x,tyty { tySlots = ts' })]
        _ -> return [(x,tyty)]

    return $ setGrinFunctions newFuncs grin {
        grinCafs = newCafs,
        grinPartFunctions = pappFuncs,
        grinTypeEnv = TyEnv $ fromList mp',
        --grinArgTags = Map.fromList newArgTags,
        grinSuspFunctions = suspFuncs
        }

combineArgs fn as = [ ((fn,n),a) | (n,a) <- zip [0 :: Int ..] as]

go fixer pappFuncs suspFuncs usedFuncs usedArgs usedCafs postInline (fn,as :-> body) = ans where
    goAgain = go fixer pappFuncs suspFuncs usedFuncs usedArgs usedCafs postInline
    ans = do
        usedVars <- newSupply fixer

        flip mapM_ (combineArgs fn as) $ \ (ap,Var v _) -> do
            x <- supplyValue usedArgs ap
            v <- supplyValue usedVars v
            addRule $ v `implies` x
        -- a lot of things are predicated on this so that CAFS are not held on to unnecesarily
        fn' <- supplyValue usedFuncs fn
        let varValue v | v < v0 = sValue usedCafs v
                       | otherwise = sValue usedVars v
            f e = g e >> return e
            g (BaseOp Eval [e]) =  addRule (doNode e)
            g (BaseOp Apply {} vs) =  addRule (mconcatMap doNode vs)
            g (Case e _) =  addRule (doNode e)
            g Prim { expArgs = as } = addRule (mconcatMap doNode as)
            g (App a vs _) = do
                addRule $ conditionalRule id fn' $ mconcat [ mconcatMap (implies (sValue usedArgs fn) . varValue) (freeVars a) | (fn,a) <- combineArgs a vs]
                addRule $ fn' `implies` sValue usedFuncs a
                addRule (mconcatMap doNode vs)
            g (BaseOp Overwrite [Var v _,n]) | v < v0 = do
                v' <- supplyValue usedCafs v
                addRule $ conditionalRule id v' $ doNode n
            g (BaseOp Overwrite [vv,n]) = addRule $ (doNode vv) `mappend` (doNode n)
            g (BaseOp PokeVal [vv,n]) = addRule $ (doNode vv) `mappend` (doNode n)
            g (BaseOp PeekVal [vv]) = addRule $ (doNode vv)
            g (BaseOp Promote [vv]) = addRule $ (doNode vv)
            g (BaseOp _ xs) = addRule $ mconcatMap doNode xs
            g Alloc { expValue = v, expCount = c, expRegion = r } = addRule $ doNode v `mappend` doNode c `mappend` doNode r
            g Let { expDefs = defs, expBody = body } = do
                mapM_ goAgain [ (name,bod) | FuncDef { funcDefBody = bod, funcDefName = name } <- defs]
                flip mapM_ (map funcDefName defs) $ \n -> do
                    --n' <- supplyValue usedFuncs n
                    --addRule $ fn' `implies` n'
                    return ()
            g Error {} = return ()
            -- TODO - handle function and case return values smartier.
            g (Return ns) = mapM_ (addRule . doNode) ns
            g x = error $ "deadcode.g: " ++ show x
            h' (p,e) = h (p,e) >> return (Just (p,e))
            h (p,BaseOp (StoreNode _) [v]) = addRule $ mconcat $ [ conditionalRule id  (varValue pv) (doNode v) | pv <- freeVars p]
            h (p,BaseOp Demote [v]) = addRule $ mconcat $ [ conditionalRule id  (varValue pv) (doNode v) | pv <- freeVars p]
            h (p,Alloc { expValue = v, expCount = c, expRegion = r }) = addRule $ mconcat $ [ conditionalRule id  (varValue pv) (doNode v `mappend` doNode c `mappend` doNode r) | pv <- freeVars p]
            h (p,Return vs) = mapM_ (h . \v -> (p,BaseOp Promote [v])) vs -- addRule $ mconcat $ [ conditionalRule id  (varValue pv) (doNode v) | pv <- freeVars p]
            h (p,BaseOp Promote [v]) = addRule $ mconcat $ [ conditionalRule id  (varValue pv) (doNode v) | pv <- freeVars p]
            h (p,e) = g e
            doNode (NodeC n as) | not postInline, Just (x,fn) <- tagUnfunction n  = let
                consts = (mconcatMap doNode as)
                usedfn = implies fn' (sValue usedFuncs fn)
                suspfn | x > 0 = conditionalRule id fn' (pappFuncs `isSuperSetOf` value (singleton fn))
                       | otherwise = conditionalRule id fn' (suspFuncs `isSuperSetOf` value (singleton fn))
                in mappend consts $ mconcat (usedfn:suspfn:[ mconcatMap (implies (sValue usedArgs fn) . varValue) (freeVars a) | (fn,a) <- combineArgs fn as])
            doNode x = doConst x `mappend` mconcatMap (implies fn' . varValue) (freeVars x)
            doConst _ | postInline  = mempty
            doConst (Const n) = doNode n
            doConst (NodeC n as) = mconcatMap doConst as
            doConst _ = mempty

        (nl,_) <- whiz (\_ -> id) h' f whizState (as :-> body)
        return nl

removeDeadArgs :: MonadStats m => Bool -> Set.Set Atom -> Set.Set Atom -> (Set.Set Var) -> (Set.Set (Atom,Int)) -> (Atom,Lam) -> WhizState -> m (WhizState,(Atom,Lam))
removeDeadArgs postInline funSet directFuncs usedCafs usedArgs (a,l) whizState =  whizExps f (margs a l) >>= \(l,ws) -> return (ws,(a,l)) where
    whizExps f l = whiz (\_ x -> x) (\(p,e) -> f e >>= \e' -> return  (Just (p,e'))) f whizState l
    margs fn (as :-> e) | a `Set.member` directFuncs = ((removeArgs fn as) :-> e)
    margs _ x = x
    f (App fn as ty)  = do
        as <- dff fn as
        as <- mapM clearCaf as
        return $ App fn as ty
    f (Return [NodeC fn as]) | Just fn' <- tagToFunction fn = do
        as <- dff' fn' as
        as <- mapM clearCaf as
        return $ Return [NodeC fn as]
    f (BaseOp (StoreNode False) [NodeC fn as]) |  Just fn' <- tagToFunction fn = do
        as <- dff' fn' as
        as <- mapM clearCaf as
        return $ BaseOp (StoreNode False) [NodeC fn as]
    f (BaseOp Overwrite [(Var v TyINode),_]) | deadCaf v = do
        mtick $ toAtom "Optimize.dead-code.caf-update"
        return $ Return []
    f (BaseOp Overwrite [p,NodeC fn as]) |  Just fn' <- tagToFunction fn = do
        as <- dff' fn' as
        as <- mapM clearCaf as
        return $ BaseOp Overwrite  [p,NodeC fn as]
--    f (Update (Var v TyINode) _) | deadCaf v = do
--        mtick $ toAtom "Optimize.dead-code.caf-update"
--        return $ Return []
--    f (Update p (NodeC fn as)) |  Just fn' <- tagToFunction fn = do
--        as <- dff' fn' as
--        as <- mapM clearCaf as
--        return $ Update p (NodeC fn as)
    f lt@Let { expDefs = defs }  = return $ updateLetProps lt { expDefs = defs' } where
        defs' = [ updateFuncDefProps df { funcDefBody = margs name body } | df@FuncDef { funcDefName = name, funcDefBody = body } <- defs, name `Set.member` funSet ]
    f x = return x
    dff' fn as | fn `member` directFuncs = return as
    dff' fn as = dff'' fn as
    dff fn as | fn `member` directFuncs = return (removeArgs fn as)
    dff fn as = dff'' fn as
    dff'' fn as | not (fn `member` funSet) = return as -- if function was dropped, we don't have argument use information.
    dff'' fn as = mapM df  (zip as naturals) where
        df (a,i) | not (deadVal a) && not (member (fn,i) usedArgs) = do
            mtick $ toAtom "Optimize.dead-code.func-arg"
            return $ properHole (getType a)
        df (a,_)  = return a
    clearCaf (Var v TyINode) | deadCaf v = do
        mtick $ toAtom "Optimize.dead-code.caf-arg"
        return (properHole TyINode)
    clearCaf (NodeC a xs) = do
        xs <- mapM clearCaf xs
        return $ NodeC a xs
    clearCaf (Index a b) = return Index `ap` clearCaf a `ap` clearCaf b
    clearCaf (Const a) = Const `liftM` clearCaf a
    clearCaf x = return x
    deadCaf v = v < v0 && not (v `member` usedCafs)
    deadVal (Lit 0 _) = True
    deadVal x = isHole x
    removeArgs fn as = concat [ perhapsM ((fn,i) `member` usedArgs) a | a <- as | i <- naturals ]
