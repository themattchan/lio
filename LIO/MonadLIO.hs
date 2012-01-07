{-# LANGUAGE CPP #-}
#if defined(__GLASGOW_HASKELL__) && (__GLASGOW_HASKELL__ >= 702)
{-# LANGUAGE Trustworthy #-}
#endif
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE OverlappingInstances #-}

-- | This module provides a function 'liftLIO' for executing 'LIO'
-- computations from transformed versions of the 'LIO' monad.
-- There is also a method 'liftIO', which is a synonym for 'liftLIO',
-- to help with porting code that expects to run in the @IO@ monad.
module LIO.MonadLIO (MonadLIO(..)) where

import LIO.TCB (LIO, LabelState)
import Control.Monad.Trans (MonadTrans(..))

-- |  MonadIO-like class.
class (Monad m, LabelState l s) => MonadLIO m l s | m -> l s where
    liftLIO :: LIO l s a -> m a
    liftIO  :: LIO l s a -> m a
    liftIO  = liftLIO

instance (LabelState l s) => MonadLIO (LIO l s) l s where
    liftLIO = id

instance (MonadLIO m l s, MonadTrans t, Monad (t m)) => MonadLIO (t m) l s where
   liftLIO = lift . liftLIO
