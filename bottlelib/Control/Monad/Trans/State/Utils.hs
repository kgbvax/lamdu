{-# LANGUAGE CPP #-}
module Control.Monad.Trans.State.Utils (toStateT) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative (Applicative(..))
#endif
import Control.Monad.Trans.State (State, StateT, mapStateT)
import Data.Functor.Identity (runIdentity)

toStateT :: Applicative m => State s a -> StateT s m a
toStateT = mapStateT (pure . runIdentity)
