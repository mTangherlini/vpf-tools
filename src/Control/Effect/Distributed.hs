{-# language StaticPointers #-}
{-# language TemplateHaskell #-}
{-# language UndecidableInstances #-}
module Control.Effect.Distributed where

import Control.Distributed.StoreClosure
import Control.Effect.Carrier
import Control.Effect.MTL.TH
import Control.Monad.Morph (hoist)
import Control.Monad.Trans.Control (MonadBaseControl(..))

import Data.Constraint
import Data.List.NonEmpty (NonEmpty)

import Type.Reflection (Typeable)



newtype ScopeT s m a = ScopeT { unScopeT :: m a }


runScopeT :: (forall (s :: *). ScopeT s m a) -> m a
runScopeT sm =
    case sm @() of
      ScopeT m -> m


deriveMonadTrans ''ScopeT


instance Carrier sig m => Carrier sig (ScopeT s m) where
    eff = eff . handleCoercible


newtype Scoped s a = Scoped a


getScoped :: Monad m => Scoped s a -> ScopeT s m a
getScoped (Scoped a) = return a


data Distributed n w m k
    = forall a. Semigroup a => WithWorkers (forall (s :: *). Scoped s (w n) -> ScopeT s m a) (a -> m k)
    | forall a. RunInWorker (w n) (Closure (n a)) (a -> m k)


instance Functor m => Functor (Distributed n w m) where
    fmap f (WithWorkers block k) = WithWorkers block (fmap f . k)
    fmap f (RunInWorker w clo k) = RunInWorker w clo (fmap f . k)


instance HFunctor (Distributed n w) where
    hmap f (WithWorkers block k) = WithWorkers (ScopeT . f . unScopeT . block) (f . k)
    hmap f (RunInWorker w clo k) = RunInWorker w clo (f . k)


instance Effect (Distributed n w) where
    handle state handler (WithWorkers block k) =
        WithWorkers (ScopeT . handler . (<$ state) . unScopeT . block)  (handler . fmap k)

    handle state handler (RunInWorker w clo k) =
        RunInWorker w clo (handler . (<$ state) . k)


withWorkers ::
    ( Carrier sig m
    , Member (Distributed n w) sig
    , HasInstance (Serializable a)
    , Semigroup a
    )
    => (forall (s :: *). Scoped s (w n) -> ScopeT s m a)
    -> m a
withWorkers block = send (WithWorkers block return)


runInWorker ::
    ( Carrier sig m
    , Member (Distributed n w) sig
    , HasInstance (Serializable a)
    )
    => w n
    -> Closure (n a)
    -> m a
runInWorker w clo = send (RunInWorker w clo return)


-- distribute ::
--     ( Carrier sig m
--     , Member (Distributed n) sig
--     , HasInstance (Serializable a)
--     )
--     => Closure (n a)
--     -> m (NonEmpty a)
-- distribute clo = send (Distribute clo return)
--
--
-- distributeBase :: forall sig m base a.
--     ( Carrier sig m
--     , Member (Distributed m) sig
--     , MonadBaseControl base m
--     , Typeable a
--     , Typeable base
--     , Typeable m
--     , Typeable (StM m a)
--     , HasInstance (Serializable (StM m a))
--     , HasInstance (MonadBaseControl base m)
--     )
--     => Closure (m a)
--     -> m (NonEmpty a)
-- distributeBase clo = do
--     stas <- distribute baseClo
--     mapM restoreM stas
--   where
--     baseClo :: Closure (m (StM m a))
--     baseClo =
--         liftC2 (static (\Dict m -> liftBaseWith ($ m)))
--             (staticInstance @(MonadBaseControl base m))
--             clo


newtype SingleProcessT n m a = SingleProcessT { runSingleProcessT :: m a }


deriveMonadTrans ''SingleProcessT


data LocalWorker n = LocalWorker


interpretSingleProcessT :: (Monad m, n ~ m) => Distributed n LocalWorker (SingleProcessT n m) a -> SingleProcessT n m a
interpretSingleProcessT (WithWorkers block k)           = k . pure =<< runScopeT (block (Scoped LocalWorker))
interpretSingleProcessT (RunInWorker LocalWorker clo k) = k =<< SingleProcessT (evalClosure clo)


deriveCarrier 'interpretSingleProcessT
