module Eval.Helpers where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Unsafe.Coerce (unsafeCoerce)
import System.IO.Unsafe (unsafePerformIO)

import GHC hiding (compileExpr)
import qualified GHC
import MonadUtils hiding (MonadIO, liftIO)
import Outputable
import Exception

import Eval.EvalError
import Eval.EvalM 
import Display

-- | Loads the file into the evaluator
loadFile :: FilePath -> EvalM ()
loadFile file = do
  setTargets =<< sequence [ guessTarget file Nothing
                          , guessTarget "Helper.hs" Nothing]
  graph <- depanal [] False
  -- output graph
  loaded <- load LoadAllTargets
  when (failed loaded) $ throw LoadingException
  setContext (map (IIModule . moduleName . ms_mod) graph)

-- | Compiles an expression to a @DisplayResult@
compileExpr :: String -> EvalM DisplayResult
compileExpr expr = do
  ty <- exprType expr -- throws exception if doesn't typecheck
  -- output ty
  unsafePerformIO . unsafeCoerce <$> GHC.compileExpr expr
  

-- | Outputs any value that can be pretty-printed using the default style
output :: (GhcMonad m, MonadIO m) => Outputable a => a -> m ()
output a = do
  dfs <- getSessionDynFlags
  let style = defaultUserStyle
      cntx = initSDocContext dfs style
  liftIO $ print $ runSDoc (ppr a) cntx