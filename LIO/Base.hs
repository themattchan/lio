module LIO.Base (
                 POrdering(..), POrd(..), o2po, Label(..)
                , Lref, Priv(..)
                , labelOf, taint, untaint, unlref
                , LIO
                , lref
                , labelOfio, clearOfio
                , taintio, guardio, untaintio
                , lowerio, unlowerio
                , openL, closeL, discardL
                , throwL, catchL

                , LIORef, newLIORef, labelOfLIORef
                , readLIORef, writeLIORef, atomicModifyLIORef
                ) where

import LIO.TCB hiding ( 
                 lrefTCB
               , PrivTCB
               , showTCB
               , unlrefTCB, untaintioTCB, unlowerioTCB
               , getTCB, putTCB, runTCB, evalTCB
               , ioTCB
               , LabeledExceptionTCB
               , rethrowTCB
               )

import LIO.IOTCB
                         
                         