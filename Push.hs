{-# LANGUAGE BangPatterns, TypeSynonymInstances, FlexibleInstances, MagicHash #-}

module Main where
import Data.Monoid
import Data.Maybe
import Data.Either
import Control.Applicative
import Data.Traversable hiding (mapM)
import Data.IORef
import qualified Data.Map as Map
import System.IO.Unsafe

-- | 
-- An event broadcasts (allows subscription) of input handlers.
--
-- newtype ET m r a = E { runE :: (a -> m r) -> m (m r) }
newtype ET m r a = E { runE :: (a -> m r) -> (m r -> m r) }
-- Type of handle

-- | 
-- A reactive is an output together with a start and stop action.
--
-- newtype RT m r a = R { runR :: (m r, m a, m r) }
newtype RT m r a = R { runR :: (m a -> m r) -> m r }

-- TODO better:
-- newtype RT m r a = R { runR :: m (m a, m r) }
-- newtype RT m r a = R { runR :: (m a -> m r) -> m r }
-- Type of finally

type E = ET IO ()
type R = RT IO ()

--------------------------------------------------------------------------------
-- Prim

empty#    :: E a
union#    :: E a -> E a -> E a
scatter#  :: E [a] -> E a
map#      :: (a -> b) -> E a -> E b

const#    :: a -> R a
apply#    :: R (a -> b) -> R a -> R b

accum#    :: a -> E (a -> a) -> R a
snapshot# :: (a -> b -> c) -> R a -> E b -> E c
-- join#     :: R (R a) -> R a

-- Handlers on empty are just ignored
empty# = E $
    \_ k -> k

-- Handlers on (a <> b) are registered on both a and b
union# (E a) (E b) = E $
    \h k -> a h (b h k)

-- Handlers on (f <$> a) are composed with f and registered on a
map# f (E a) = E $
    \h k -> a (h . f) k

-- Handlers on (scatterE a) are composed with traverse and registered on a
scatter# (E a) = E $
    \h k -> let h' x = h `mapM_` x
            in a h' k

-- Registering handlers on snapshot will start the reactive, and register a modified handler on e
-- The modified handler pushes values from the reactive
-- Unregistering handlers on snapshot will stop the reactive
snapshot# f (R r) (E e) = E $ 
    \h k -> let h' x y = do { x' <- x; h $ f x' y }
            in r $ \x2 -> e (h' x2) k
    
-- Starting a stepper registers a handler on the event that modifies a variable
-- Values are pulled from the variable
-- Stopping it unregisters the handler
accum# a (E e) = R $
    \k -> do
        v <- newIORef a
        e (modifyIORef v) $ k (readIORef v)


-- snapshot# f (R rr) (E ra) = E $
--     \h k -> let h' y = do { x <- o; h (f x y) }
--             in b >> ra h' (k >> e)
-- 
-- accum# a (E ra) = R $
--     \k -> do
--     where
--         b = ra (modifyIORef v) (return ())
--         o = readIORef v
--         e = return () -- FIXME unregister
--         !v = unsafePerformIO $ newIORef a
-- {-# NOINLINE accumR #-}

const# a = R $ \k -> k (pure a)
apply# (R f) (R a) = R $ \k -> f (\f' -> a (\a' -> k $ f' <*> a'))


newSource :: IO (a -> IO (), E a)
newSource = do
    -- putStrLn "----> Source created"
    r <- newIORef (0,Map.empty)

    let write = \x -> do
        (_,hs) <- readIORef r
        -- putStrLn $ "----> Input, num handlers: " ++ show (Map.size hs)
        traverse (\h -> h x) hs
        return ()

    let register = \h k -> do
        -- putStrLn "----> Registered handler"
        (n,hs) <- readIORef r
        let hs' = Map.insert n h hs
        writeIORef r (n+1,hs')
        k
        -- putStrLn "----> Unregistered handler"
        (_,hs2) <- readIORef r
        let hs2' = Map.delete n hs2
        writeIORef r (n,hs2')
    
    return (write, E register)

newSink :: IO (IO (Maybe a), E a -> E ())
newSink = undefined

stepper#  :: a -> E a -> R a
stepper# a e = accum# a (fmap const e)



--------------------------------------------------------------------------------
-- API

instance Monoid (E a) where
    mempty = empty#
    mappend = union#
instance Functor E where
    fmap = map#
instance Functor R where
    fmap f = (pure f <*>)
instance Applicative R where
    pure = const#
    (<*>) = apply#
-- instance Monad R where
--     return = pureR#
--     x >>= k = (joinR . fmap k) x

filterE :: (a -> Bool) -> E a -> E a
filterE p = scatterE . fmap (filter p . single)

justE :: E (Maybe a) -> E a
justE = scatterE . fmap maybeToList

splitE :: E (Either a b) -> (E a, E b)
splitE e = (justE $ fromLeft <$> e, justE $ fromRight <$> e)

eitherE :: E a -> E b -> E (Either a b)
a `eitherE` b = (Left <$> a) <> (Right <$> b)

-- zipE :: (a, b) -> (E a, E b) -> E (a, b)
-- zipE = undefined

unzipE :: E (a, b) -> (E a, E b)
unzipE e = (fst <$> e, snd <$> e)

replaceE :: b -> E a -> E b
replaceE x = (x <$)

accumE :: a -> E (a -> a) -> E a
a `accumE` e = (a `accumR` e) `sample` e

foldpE :: (a -> b -> b) -> b -> E a -> E b
foldpE f a e = a `accumE` (f <$> e)

scanlE :: (a -> b -> a) -> a -> E b -> E a
scanlE f = foldpE (flip f)
        
monoidE :: Monoid a => E a -> E a
monoidE = scanlE mappend mempty

sumE :: Num a => E a -> E a
sumE = over monoidE Sum getSum

productE :: Num a => E a -> E a
productE = over monoidE Product getProduct

allE :: E Bool -> E Bool
allE = over monoidE All getAll

anyE :: E Bool -> E Bool
anyE = over monoidE Any getAny

firstE :: E a -> E a
firstE = justE . fmap snd . foldpE g (True,Nothing)
    where
        g c (True, _)  = (False,Just c)
        g c (False, _) = (False,Nothing)
            
restE :: E a -> E a
restE = justE . fmap snd . foldpE g (True,Nothing)
    where        
        g c (True, _)  = (False,Nothing)
        g c (False, _) = (False,Just c)

countE :: Enum b => E a -> E b
countE = accumE (toEnum 0) . fmap (const succ)

lastE :: E a -> E a
lastE = fmap snd . recallE

delayE :: Int -> E a -> E a
delayE n = foldr (.) id (replicate n lastE)

bufferE :: Int -> E a -> E [a]
bufferE n = (reverse <$>) . foldpE g []
    where
        g x xs = x : take (n-1) xs

gatherE :: Int -> E a -> E [a]
gatherE n = (reverse <$>) . filterE (\xs -> length xs == n) . foldpE g []
    where
        g x xs | length xs <  n  =  x : xs
               | length xs == n  =  x : []
               | otherwise       = error "gatherE: Wrong length"

scatterE :: E [a] -> E a
scatterE = scatter#

recallE :: E a -> E (a, a)
recallE = recallWithE (,)

-- Note: flipped order from Reactive
recallWithE :: (a -> a -> b) -> E a -> E b
recallWithE f = justE . fmap combine . (dup Nothing `accumE`) . fmap (shift . Just)
    where      
        shift b (_,a) = (a,b)
        dup x         = (x,x)
        combine       = uncurry (liftA2 f)

stepper  :: a -> E a -> R a
stepper = stepper#

stepper' :: E a -> R (Maybe a)
stepper' e = Nothing `stepper` fmap Just e

hold :: R a -> E b -> R (Maybe a)
hold r = hold' Nothing (fmap Just r)

hold' :: a -> R a -> E b -> R a
hold' z r e = z `stepper` (r `sample` e) 

apply :: R (a -> b) -> E a -> E b
r `apply` e = r `o` e where o = snapshotWith ($)

sample :: R a -> E b -> E a
sample = snapshotWith const

snapshot :: R a -> E b -> E (a, b)
snapshot = snapshotWith (,)

snapshotWith :: (a -> b -> c) -> R a -> E b -> E c
snapshotWith = snapshot#

filter' :: R (a -> Bool) -> E a -> E a
r `filter'` e = justE $ (partial <$> r) `apply` e

gate :: R Bool -> E a -> E a
r `gate` e = (const <$> r) `filter'` e

accumR :: a -> E (a -> a) -> R a
accumR = accum#

mapAccum :: a -> E (a -> (b,a)) -> (E b, R a)
mapAccum acc ef = (fst <$> e, stepper acc (snd <$> e))
    where 
        e = accumE (emptyAccum,acc) ((. snd) <$> ef)
        emptyAccum = error "mapAccum: Empty accumulator"

zipR :: R a -> R b -> R (a, b)
zipR = liftA2 (,)

unzipR :: R (a, b) -> (R a, R b)
unzipR r = (fst <$> r, snd <$> r)

foldpR :: (a -> b -> b) -> b -> E a -> R b
foldpR f = scanlR (flip f)

scanlR :: (a -> b -> a) -> a -> E b -> R a
scanlR f a e = a `stepper` scanlE f a e

monoidR :: Monoid a => E a -> R a
monoidR = scanlR mappend mempty

sumR :: Num a => E a -> R a
sumR = over monoidR Sum getSum

productR :: Num a => E a -> R a
productR = over monoidR Product getProduct

allR :: E Bool -> R Bool
allR = over monoidR All getAll

anyR :: E Bool -> R Bool
anyR = over monoidR Any getAny

countR :: Enum b => E a -> R b
countR = accumR (toEnum 0) . fmap (const succ)

toggleR :: E a -> R Bool
toggleR = fmap odd . countR

diffE :: Num a => E a -> E a
diffE = recallWithE $ flip (-)

-- time :: Fractional a => R a
-- time = accumR 0 ((+ kStdPulseInterval) <$ kStdPulse)

integral :: Fractional b => E a -> R b -> R b
integral t b = sumR (snapshotWith (*) b (diffE (tx `sample` t)))
    where
        -- tx = time
        tx :: Fractional a => R a
        tx = fmap (fromRational . toRational) $ systemTimeSecondsR
systemTimeSecondsR = pure 0 -- FIXME

data TransportControl t 
    = Play      -- ^ Play from the current position.
    | Reverse   -- ^ Play in reverse from the current position.
    | Pause     -- ^ Stop playing, and retain current position.
    | Stop      -- ^ Stop and reset position.
    deriving (Eq, Ord, Show)

isStop Stop = True
isStop _    = False

{-
transport :: (Ord t, Fractional t) => E (TransportControl t) -> E a -> R t -> R t
transport ctrl trig speed = position'
    where          
        -- action :: R (TransportControl t)
        action    = Pause `stepper` ctrl

        -- direction :: Num a => R a
        direction = flip ($) $ action $ \a -> case a of
            Play     -> 1
            Reverse  -> (-1)
            Pause    -> 0         
            Stop     -> 0         
            
        -- position :: Num a => R a
        position = integral trig (speed * direction)
        startPosition = sampleAndHold2 0 position (filterE isStop ctrl)

        position'     = position - startPosition

record :: Ord t => R t -> E a -> R [(t, a)]
record t x = foldpR append [] (t `snapshot` x)
    where
        append x xs = xs ++ [x]

playback :: Ord t => R t -> R [(t,a)] -> E a
playback t s = scatterE $ fmap snd <$> playback' oftenE t s
oftenE = mempty -- FIXME

playback' :: Ord t => E b -> R t -> R [(t,a)] -> E [(t, a)]
playback' p t s = cursor s (t `sample` p)
    where                             
        -- cursor :: Ord t => R [(t,a)] -> E t -> E [(a,t)]
        cursor s = snapshotWith (flip occs) s . recallE

        -- occs :: Ord t => (t,t) -> [(a,t)] -> [(a,t)]
        occs (x,y) = filter (\(t,_) -> x < t && t <= y)-}

                                                           







-- Util
start :: E a -> (a -> IO ()) -> IO () -> IO ()
start = runE

main = do
    -- (i1,e1) <- newSource              
    -- (i2,e2) <- newSource              
    -- 
    -- run putStrLn (e1 <> fmap (show . length) e1 <> fmap reverse e2)
    -- i1 "Hello"
    -- i1 "This"
    -- i2 "Is"
    -- i2 "Cool"
    -- i1 "Right?"
    -- i2 "Right?"

    (i1,e1) <- newSource
    (i2,e2) <- newSource
    let ev0 = e1 `eitherE` recallE e1
    let (ev1,ev2) = splitE ev0
    let ev  = fmap ((""++) . show) ev1 <> fmap (("               "++) . show) ev2
    
    start ev putStrLn $ do
        i1 "Hello"
        i1 "This"
        i1 "Is"
        i1 "Cool"
        i1 "Right?"
        i1 "There!"
    
    





partial p x
    | p x       = Just x
    | otherwise = Nothing
list z f [] = z
list z f xs = f xs
filterMap p = catMaybes . map p   
cycleM x = x >> cycleM x 
single x = [x]
fromLeft  (Left  a) = Just a
fromLeft  (Right b) = Nothing
fromRight (Left  a) = Nothing
fromRight (Right b) = Just b                         
over f i o = fmap o . f . fmap i

eventToReactive :: E a -> R a
eventToReactive = stepper (error "eventToReactive: ")

