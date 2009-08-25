{-# OPTIONS_GHC -XMultiParamTypeClasses #-}
{-# OPTIONS_GHC -XGeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -XExistentialQuantification #-}
{-# OPTIONS_GHC -XDeriveDataTypeable #-}


module LIO.TCB ( 
                 POrdering(..), POrd(..), o2po, Label(..)
               , Lref, Priv(..)
               , labelOf, taint, untaint, unlref
               , LIO
               , lref
               , labelOfio, clearOfio
               , taintio, guardio, cleario, untaintio
               , lowerio, unlowerio
               , openL, closeL, discardL
               , throwL, catchL, catchLp
               , LabelFault(..)
               -- Start TCB exports
               , lrefTCB
               , PrivTCB
               , showTCB
               , unlrefTCB, untaintioTCB, unlowerioTCB
               , getTCB, putTCB, runTCB, evalTCB
               , ioTCB
               , LabeledExceptionTCB(..)
               , rethrowTCB
               -- End TCB exports
               ) where

import Prelude hiding (catch)
import Control.Monad.State.Lazy hiding (put, get)
import Control.Exception
import Data.Monoid
import Data.Typeable

{- Things to worry about:

   - unsafe... functions must be blocked

   - inlinePerformIO must be blocked

   - Allowing untrusted code to define instances Typeable with bogus
     typeOf functions could lead to unsafe casts.

   - Some way of showing an Lref or even just the label, by putting it
     into an exception.

 -}

--
-- We need a partial order and a Label
--

data POrdering = PEQ | PLT | PGT | PNE deriving (Eq, Ord, Show)

instance Monoid POrdering where
    mempty          = PEQ
    mappend PLT PGT = PNE
    mappend PGT PLT = PNE
    mappend x y     = max x y

class (Eq a) => POrd a where
    pcompare :: a -> a -> POrdering
    leq :: a -> a -> Bool

    pcompare a b | a == b = PEQ
                 | a `leq` b = PLT
                 | b `leq` a = PGT
                 | otherwise = PNE
    leq a b = case pcompare a b of
                PEQ       -> True
                PLT       -> True
                otherwise -> False

o2po EQ = PEQ; o2po LT = PLT; o2po GT = PGT
-- instance (Ord a) => POrd a where pcompare = o2po . compare

class (POrd a, Show a, Typeable a) => Label a where
    lpure :: a                  -- label for pure values
    lclear :: a                 -- default clearance
    lub :: a -> a -> a
    glb :: a -> a -> a


--
-- Labeled value - Lref
-- Downgrading privileges - Priv
--

data (Label l) => Lref l t = Lref l t

showTCB            :: (Label l, Show t) => Lref l t -> String
showTCB (Lref l t) = shows t $ " {" ++ shows l "}"

instance Label l => Functor (Lref l) where
    fmap f (Lref l t) = Lref (l `lub` lpure) (f t)

instance Label l => Monad (Lref l) where
    return x = Lref lpure x
    (Lref l x) >>= f = let Lref l' y = f x in Lref (lub l l') y

instance Label l => MonadFix (Lref l) where
    mfix f = fix g
        where g ~(Lref _ a) = f a

class PrivTCB t where
class (Label l, Monoid p, PrivTCB p) => Priv l p where
    -- (leqp p l1 l2) means that privileges p are sufficient to
    -- downgrade data from l1 to l2.  Note that (leq l1 l2) implies
    -- (leq p l1 l2) for all p, but for some labels an p leqp will
    -- hold even if leq does not.
    leqp :: p -> l -> l -> Bool
    leqp p a b = lostar p a b `leq` b

    -- (lostar p source minimum) returns the lowest label to which one
    -- can downgrade data labeled source given privileges p,
    -- least-upper-bounded with minimum.  (Without minimum, the lowest
    -- label might be exponential in p for some label formats.)  More
    -- concretely, the result returned is the lowest lres such that:
    -- (leqp p source lres) && (leq minimum lres)
    --
    -- This is useful if your label is originally l1, and you touch
    -- some stuff labeled l2 but want to minimize the amount of taint
    -- l2 causes you.  After raising your label to l2, you can use the
    -- privileges in p to lower your label to lostar p l2 l1.
    lostar :: p -> l -> l -> l

lrefTCB     :: Label l => l -> a -> Lref l a
lrefTCB l a = Lref l a

labelOf            :: Label l => Lref l a -> l
labelOf (Lref l a) = l

taint               :: (Label l) => l -> Lref l a -> Lref l a
taint l' (Lref l a) = Lref (lub l l') a

untaint                   :: Priv l p => p -> l -> Lref l a -> Lref l a
untaint p newl (Lref l a) = if leqp p l newl then Lref newl a else undefined

unlref              :: Priv l p => p -> Lref l a -> a
unlref p (Lref l a) = if leqp p l lpure then a else undefined

unlrefTCB            :: Label l => Lref l a -> a
unlrefTCB (Lref l a) = a


--
-- Labeled IO
--

data (Label l, Typeable s) => LIOstate l s =
    LIOstate { labelState :: s
             , lioL :: l -- current label
             , lioC :: l -- current clearance
             }

newtype (Label l, Typeable s) => LIO l s a = LIO (StateT (LIOstate l s) IO a)
    deriving (Functor, Monad, MonadFix)

get :: (Label l, Typeable s) => LIO l s (LIOstate l s)
get = mkLIO $ \s -> return (s, s)

put :: (Label l, Typeable s) => LIOstate l s -> LIO l s ()
put s = mkLIO $ \_ -> return (() , s)

lref     :: (Label l, Typeable s) => l -> a -> LIO l s (Lref l a)
lref l a = get >>= doit
    where doit s | not $ l `leq` lioC s = throwL LerrClearance
                 | not $ lioL s `leq` l = throwL LerrLow
                 | otherwise            = return $ Lref l a

labelOfio :: (Label l, Typeable s) => LIO l s l
labelOfio = get >>= return . lioL

clearOfio :: (Label l, Typeable s) => LIO l s l
clearOfio = get >>= return . lioC

taintio    :: (Label l, Typeable s) => l -> LIO l s ()
taintio l' = do s <- get
                let l = lioL s `lub` l'
                if l `leq` lioC s
                  then put s { lioL = l }
                  else throwL LerrLow

guardio :: (Label l, Typeable s) => l -> LIO l s ()
guardio max = do l <- labelOfio
                 if l `leq` max
                   then return ()
                   else throwL LerrHigh

cleario :: (Label l, Typeable s) => l -> LIO l s ()
cleario min = do c <- clearOfio
                 if min `leq` c
                   then return ()
                   else throwL LerrClearance

untaintio     :: (Priv l p, Typeable s) => p -> l -> LIO l s ()
untaintio p l = do s <- get
                   if leqp p (lioL s) l
                     then put s { lioL = l }
                     else throwL LerrPriv

untaintioTCB     :: (Label l, Typeable s) => l -> LIO l s ()
untaintioTCB l = do s <- get
                    if l `leq` lioC s
                      then put s { lioL = l }
                      else throwL LerrClearance

lowerio   :: (Label l, Typeable s) => l -> LIO l s ()
lowerio l = get >>= doit
    where doit s | not $ l `leq` lioC s = throwL LerrClearance
                 | not $ lioL s `leq` l = throwL LerrLow
                 | otherwise            = put s { lioC = l }

unlowerio   :: (Priv l p, Typeable s) => p -> l -> LIO l s ()
unlowerio p l = get >>= doit
    where doit s | not $ leqp p l $ lioC s = throwL LerrPriv
                 | not $ lioL s `leq` l = throwL LerrLow
                 | otherwise            = put s { lioC = l }

unlowerioTCB   :: (Label l, Typeable s) => l -> LIO l s ()
unlowerioTCB l = get >>= doit
    where doit s | not $ lioL s `leq` l = throwL LerrInval
                 | otherwise            = put s { lioC = l }

openL             :: (Label l, Typeable s) => Lref l a -> LIO l s a
openL (Lref la a) = do
  s <- get
  if la `leq` lioC s
    then do put s { lioL = lioL s `lub` la }
            return a
    else
        return undefined

-- Might have lowered clearance inside closeL, so just preserve it
closeL   :: (Label l, Typeable s) => LIO l s a -> LIO l s (Lref l a)
closeL m = do
  LIOstate { lioL = l, lioC = c } <- get
  a <- m
  s <- get
  put s { lioL = l, lioC = c }
  return $ Lref (lioL s) a

discardL m = closeL m >> return ()
  

getTCB :: (Label l, Typeable s) => LIO l s s
getTCB = get >>= return . labelState

putTCB    :: (Label l, Typeable s) => s -> LIO l s ()
putTCB ls = get >>= put . update
    where update s = s { labelState = ls }

newstate   :: (Label l, Typeable s) => s -> LIOstate l s
newstate s = LIOstate { labelState = s , lioL = lpure , lioC = lclear }

mkLIO :: (Label l, Typeable s) => (LIOstate l s -> IO (a, LIOstate l s))
      -> LIO l s a
mkLIO = LIO . StateT

unLIO                  :: (Label l, Typeable s) => LIO l s a -> LIOstate l s
                       -> IO (a, LIOstate l s)
unLIO (LIO (StateT f)) = f

runLIO     :: (Label l, Typeable s) => LIO l s a -> LIOstate l s
           -> IO (a, LIOstate l s)
runLIO m s = unLIO m s `catch` unlabelException

runTCB     :: (Label l, Typeable s) => LIO l s a -> s -> IO (a, s)
runTCB m s = do (a, ls) <- runLIO m (newstate s)
                return (a, labelState ls)

evalTCB     :: (Label l, Typeable s) => LIO l s a -> s -> IO (a, l)
evalTCB m s = do (a, ls) <- runLIO m (newstate s)
                 return (a, lioL ls)

ioTCB :: (Label l, Typeable s) => IO a -> LIO l s a
ioTCB a = mkLIO $ \s -> do r <- a; return (r, s)


--
-- Exceptions
--

data LabelFault
    = LerrLow                   -- Requested label too low
    | LerrHigh                  -- Current label too high
    | LerrClearance             -- Label would exceed clearance
    | LerrPriv                  -- Insufficient privileges
    | LerrInval                 -- Invalid request
      deriving (Show, Typeable)

instance Exception LabelFault

data LabeledExceptionTCB l s =
    LabeledExceptionTCB l s SomeException deriving Typeable

instance Label l => Show (LabeledExceptionTCB l s) where
    showsPrec _ (LabeledExceptionTCB l s e) rest =
        shows e $ (" {" ++) $ shows l $ "}" ++ rest

instance (Label l, Typeable s) => Exception (LabeledExceptionTCB l s)

unlabelException :: (Label l, Typeable s) => LabeledExceptionTCB l s
                 -> IO (a, LIOstate l s)
unlabelException (LabeledExceptionTCB l s (SomeException e)) =
    putStrLn ("unlabeling " ++ show e ++ " {" ++ show l ++ "}") >> -- XXX
    throw e

throwL   :: (Exception e, Label l, Typeable s) => e -> LIO l s a
throwL e = mkLIO $ \s -> throwIO $
           LabeledExceptionTCB (lioL s) (labelState s) (toException e)

getresult m s = do
  (a, s') <- unLIO m s
  a' <- evaluate a
  return (a', s')

rethrowTCB   :: (Label l, Typeable s) => LIO l s a -> LIO l s a
rethrowTCB m = mkLIO $ \s -> getresult m s
               `catches` [Handler $ dolabeled s, Handler $ doother s]
    where
      dolabeled     :: (Label l, Typeable s) =>
                       LIOstate l s -> LabeledExceptionTCB l s -> a
      dolabeled _ e = throw e
      doother     :: (Label l, Typeable s) => LIOstate l s -> SomeException
                  -> IO (a, LIOstate l s)
      doother s e = unLIO (throwL e) s

catchLp       :: (Label l, Typeable s, Exception e, Priv l p) =>
                 LIO l s a -> p -> (l -> e -> LIO l s a) -> LIO l s a
catchLp m p c = mkLIO $ \s -> getresult m s `catch` doit s
    where doit s e@(LabeledExceptionTCB l ls se) =
              case fromException se of
                Just e' | leqp p l $ lioL s
                            -> unLIO (c l e') s { labelState = ls }
                Nothing -> throw e

catchL     :: (Label l, Typeable s, Exception e) =>
              LIO l s a -> (e -> LIO l s a) -> LIO l s a
catchL m c = mkLIO $ \s -> getresult m s `catch` doit s
    where doit s e@(LabeledExceptionTCB l ls se) =
              case fromException se of
                Just e' | l `leq` lioL s -> unLIO (c e') s { labelState = ls }
                Nothing -> throw e
