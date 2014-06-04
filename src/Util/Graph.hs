-- | Data.Graph is sorely lacking in several ways, This just tries to fill in
-- some holes and provide a more convinient interface
{-# LANGUAGE RecursiveDo #-}

module Util.Graph(
    Graph(),
    Util.Graph.components,
    Util.Graph.dff,
    Util.Graph.reachable,
    Util.Graph.scc,
    Util.Graph.topSort,
    cyclicNodes,
    findLoopBreakers,
    fromGraph,
    fromScc,
    getBindGroups,
    groupOverlapping,
    mapGraph,
    newGraph',
    newGraph,
    newGraphReachable,
    reachableFrom,
    restitchGraph,
    sccForest,
    easySCC,
    sccGroups,
    toDag,
    transitiveClosure,
    transitiveReduction
    ) where

import Control.Monad
import Control.Monad.ST
import Data.Array.IArray
import Data.Array.ST hiding(unsafeFreeze)
import Data.Array.Unsafe (unsafeFreeze)
import Data.Graph hiding(Graph)
import Data.Maybe
import Data.STRef
import GenUtil
import Data.List(sort,sortBy,group,delete)
import Util.UnionFindST
import qualified Data.Graph as G
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Traversable as A

data Graph n = Graph G.Graph (Table n)

instance Show n => Show (Graph n) where
    showsPrec n g = showsPrec n (Util.Graph.scc g)

-- simple scc interface
easySCC :: Ord name => [node]  -> (node -> name)   ->  (node -> [name]) ->  [[node]]
easySCC ns fn fd = map f $ stronglyConnComp [ (n, fn n, fd n) | n <- ns] where
    f (AcyclicSCC x) = [x]
    f (CyclicSCC xs) = xs

fromGraph :: Graph n -> [(n,[n])]
fromGraph (Graph g lv) = [ (lv!v,map (lv!) vs) | (v,vs) <- assocs g ]

newGraph :: Ord k => [n] -> (n -> k) -> (n -> [k]) -> (Graph n)
newGraph ns a b = snd $ newGraph' ns a b

newGraphReachable :: Ord k => [n] -> (n -> k) -> (n -> [k]) -> ([k] -> [n],Graph n)
newGraphReachable ns fn fd = (rable,ng) where
    (vmap,ng) = newGraph' ns fn fd
    rable ks = Util.Graph.reachable ng [ v | Just v <- map (flip Map.lookup vmap) ks ]

reachableFrom :: Ord k => (n -> k) -> (n -> [k]) -> [n] -> [k] -> [n]
reachableFrom fn fd ns  = fst $ newGraphReachable ns fn fd

-- | Build a graph from a list of nodes uniquely identified by keys,
-- with a list of keys of nodes this node should have edges to.
-- The out-list may contain keys that don't correspond to
-- nodes of the graph; they are ignored.
newGraph' :: Ord k => [n] -> (n -> k) -> (n -> [k]) -> (Map.Map k Vertex,Graph n)
newGraph' ns fn fd = (kmap,Graph graph nr) where
    nr = listArray bounds0 ns
    max_v      	    = length ns - 1
    bounds0         = (0,max_v) :: (Vertex, Vertex)
    kmap = Map.fromList [ (fn n,i) | (i,n) <- zip [0 ..] ns ]
    graph	    = listArray bounds0 [mapMaybe (flip Map.lookup kmap) (snub $ fd n) | n <- ns]

fromScc (Left n) = [n]
fromScc (Right n) = n

-- | determine a set of loopbreakers subject to a fitness function
-- loopbreakers have a minimum of their  incoming edges ignored.
findLoopBreakers
    :: (n -> Int)  -- ^ fitness function, greater numbers mean more likely to be a loopbreaker
    -> (n -> Bool) -- ^ whether a node is suitable at all for a choice as loopbreaker
    -> Graph n     -- ^ the graph
    ->  ([n],[n])  -- ^ (loop breakers,dependency ordered nodes after loopbreaking)
findLoopBreakers func ex (Graph g ln) = ans where
    scc = G.scc g
    ans = f g scc [] [] where
        f g (Node v []:sccs) fs lb
            | v `elem` g ! v = let ng = (fmap (Data.List.delete v) g) in  f ng (G.scc ng) [] (v:lb)
            | otherwise = f g sccs (v:fs) lb

        f g (n:_) fs lb = f ng (G.scc ng) [] (mv:lb) where
            mv = case  sortBy (\ a b -> compare (snd b) (snd a)) [ (v,func (ln!v)) | v <- ns, ex (ln!v) ] of
                ((mv,_):_) -> mv
                [] -> error "findLoopBreakers: no valid loopbreakers"
            ns = dec n []
            ng = fmap (Data.List.delete mv) g

        f _ [] xs lb = (map ((ln!) . head) (group $ sort lb),reverse $ map (ln!) xs)
    dec (Node v ts) vs = v:foldr dec vs ts

reachable :: Graph n -> [Vertex] -> [n]
reachable (Graph g ln) vs = map (ln!) $ snub $  concatMap (G.reachable g) vs

sccGroups :: Graph n -> [[n]]
sccGroups g = map fromScc (Util.Graph.scc g)

scc :: Graph n -> [Either n [n]]
scc (Graph g ln) = map decode forest where
    forest = G.scc g
    decode (Node v [])
        | v `elem` g ! v = Right [ln!v]
        | otherwise = Left (ln!v)
    decode other = Right (dec other [])
    dec (Node v ts) vs = ln!v:foldr dec vs ts

sccForest :: Graph n -> Forest n
sccForest (Graph g ln) = map (fmap (ln!)) forest where
    forest = G.scc g

dff :: Graph n -> Forest n
dff (Graph g ln) = map (fmap (ln!)) forest where
    forest = G.dff g

components :: Graph n -> [[n]]
components (Graph g ln) = map decode forest where
    forest = G.components g
    decode n = dec n []
    dec (Node v ts) vs = ln!v:foldr dec vs ts

topSort :: Graph n -> [n]
topSort (Graph g ln) = map (ln!) $ G.topSort g

cyclicNodes :: Graph n -> [n]
cyclicNodes g = concat [ xs | Right xs <- Util.Graph.scc g]

toDag :: Graph n -> Graph [n]
toDag (Graph g lv) = Graph g' ns' where
    ns' = listArray (0,max_v) [ map (lv!) ns |  ns <- nss ]
    g' = listArray (0,max_v) [ snub [ v | n <- ns, v <- g!n ] | ns <- nss ]
    max_v = length nss - 1
    nss = map (flip f []) (G.scc g) where
        f (Node v ts) rs = v:foldr f rs ts

type AdjacencyMatrix s  = STArray s (Vertex,Vertex) Bool
type IAdjacencyMatrix  = Array (Vertex,Vertex) Bool

transitiveClosureAM :: AdjacencyMatrix s -> ST s ()
transitiveClosureAM arr = do
    bnds@(_,(max_v,_)) <- getBounds arr
    forM_ [0 .. max_v] $ \k -> do
        forM_ (range bnds) $ \ (i,j) -> do
                dij <- readArray arr (i,j)
                dik <- readArray arr (i,k)
                dkj <- readArray arr (k,j)
                writeArray arr (i,j) (dij || (dik && dkj))

transitiveReductionAM :: AdjacencyMatrix s -> ST s ()
transitiveReductionAM arr = do
    bnds@(_,(max_v,_)) <- getBounds arr
    transitiveClosureAM arr
    (farr :: IAdjacencyMatrix) <- freeze arr
    forM_ [0 .. max_v] $ \k -> do
        forM_ (range bnds) $ \ (i,j) -> do
            if farr!(k,i) && farr!(i,j) then
                writeArray arr (k,j) False
             else return ()

toAdjacencyMatrix :: G.Graph -> ST s (AdjacencyMatrix s)
toAdjacencyMatrix g = do
    let (0,max_v) = bounds g
    arr <- newArray ((0,0),(max_v,max_v)) False :: ST s (STArray s (Vertex,Vertex) Bool)
    sequence_ [ writeArray arr (v,u) True | (v,vs) <- assocs g, u <- vs ]
    return arr

fromAdjacencyMatrix :: AdjacencyMatrix s -> ST s G.Graph
fromAdjacencyMatrix arr = do
    bnds@(_,(max_v,_)) <- getBounds arr
    rs <- getAssocs arr
    let rs' = [ x | (x,True) <- rs ]
    return (listArray (0,max_v) [ [ v | (n',v) <- rs', n == n' ] | n <- [ 0 .. max_v] ])

transitiveClosure :: Graph n -> Graph n
transitiveClosure (Graph g ns) = let g' = runST (tc g) in (Graph g' ns) where
    tc g = do
        a <- toAdjacencyMatrix g
        transitiveClosureAM a
        fromAdjacencyMatrix a

transitiveReduction :: Graph n -> Graph n
transitiveReduction (Graph g ns) = let g' = runST (tc g) in (Graph g' ns) where
    tc g = do
        a <- toAdjacencyMatrix g
        transitiveReductionAM a
        fromAdjacencyMatrix a

instance Functor Graph where
    fmap f (Graph g n) = Graph g (fmap f n)

--mapT    :: (Vertex -> a -> b) -> Table a -> Table b
--mapT f t = listArray (bounds t) [ (f v (t!v)) | v <- indices t ]

restitchGraph :: Ord k => (n -> k) -> (n -> [k]) -> Graph n -> Graph n
restitchGraph fn fd (Graph g nr) = Graph g' nr where
    kmap = Map.fromList [ (fn n,i) | (i,n) <- assocs nr ]
    g'	 = listArray (bounds g) [mapMaybe (flip Map.lookup kmap) (snub $ fd n) | n <- elems nr]

mapGraph :: forall a b . (a -> [b] -> b) -> Graph a -> Graph b
mapGraph f (Graph gr nr) = runST $ do
    mnr <- thaw nr  :: ST s (STArray s Vertex a)
    mnr <- mapArray Left mnr
    let g i = readArray mnr i >>= \v -> case v of
            Right m -> return m
            Left l -> mdo
                writeArray mnr i (Right r)
                rs <- mapM g (gr!i)
                let r = f l rs
                return r
    mapM_ g (range $ bounds nr)
    mnr <- mapArray fromRight mnr
    mnr <- unsafeFreeze mnr
    return (Graph gr mnr)

-- this uses a very efficient union-find algorithm.
groupOverlapping :: Ord b => (a -> [b]) -> [a] -> (Map.Map b Int,[(Int,[a])])
groupOverlapping fn xs = runUF $ do
    es <- forM xs $ \x -> new_ x
    mref <- liftST (newSTRef Map.empty)
    forM_ es $ \e -> do
        let bs = fn $ fromElement e
        cmap <- liftST $ readSTRef mref
        sequence_ [ union_ x e | b <- bs, Just x <- [Map.lookup b cmap]]
        liftST $ modifySTRef mref (Map.union (Map.fromList [ (x,e) | x <- bs ]))
    cmap <- liftST $ readSTRef mref
    cmap' <- A.mapM getUnique cmap
    es <- (Set.toList . Set.fromList) `liftM` mapM find es
    es' <- forM es $ \e -> do
        u <- getUnique e
        es <- getElements e
        return (u,map fromElement es)
    return (cmap',es')

-- Given a list of nodes, a function to convert nodes to a list of its names,
-- function to convert nodes to a list of names on which the node is
-- dependendant, bindgroups will return a list of bind groups generater from the
-- list of nodes given.  nodes with matching keys are placed in the same binding
-- groups.

getBindGroups :: Ord name =>
    [node]           ->      -- List of nodes
    (node -> [name]) ->      -- Function to convert nodes to unique names
    (node -> [name]) ->      -- Function to return dependencies of this node
    [Either [node] [[node]]] -- binding groups, collecting nodes with overlapping names together

getBindGroups ns fn fd = ans where
    (mp,ns') = (groupOverlapping fn ns)
    ans = map f $ stronglyConnComp
        [(xs,Just n,map (`Map.lookup` mp) (concatMap fd xs)) | (n,xs) <- ns']
    f (AcyclicSCC x) = Left x
    f (CyclicSCC xs) = Right xs
