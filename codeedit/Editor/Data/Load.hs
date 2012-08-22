{-# LANGUAGE TypeFamilies, FlexibleContexts #-}
module Editor.Data.Load
  ( loadDefinition, DefinitionEntity(..)
  , loadExpression, ExpressionEntity
  , loadPureExpression, loadPureDefinition
  , loadPureDefinitionBody, loadPureDefinitionType
  ) where

import Control.Monad (liftM, liftM2, (<=<))
import Data.Store.Property (Property(Property))
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import qualified Data.Traversable as Traversable
import qualified Editor.Data as Data

type ExpressionEntity m = Data.Expression (Data.ExpressionIRefProperty m)

data DefinitionEntity m = DefinitionEntity
  { defEntityIRef :: Data.DefinitionIRef
  , defEntityValue :: Data.Definition (ExpressionEntity m)
  }

type T = Transaction ViewTag

loadPureExpression
  :: Monad m
  => Data.ExpressionIRef -> Transaction t m Data.PureExpression
loadPureExpression exprI =
  liftM (Data.pureExpression (Data.exprIRefGuid exprI)) .
  Traversable.mapM loadPureExpression =<< Data.readExprIRef exprI

loadPureDefinition
  :: Monad m
  => Data.DefinitionIRef
  -> T m (Data.Definition Data.PureExpression)
loadPureDefinition defI = do
  def <- Transaction.readIRef defI
  liftM2 (Data.Definition . Data.DefinitionExpression)
    (loadPureExpression ((Data.defExpression . Data.defBody) def))
    (loadPureExpression (Data.defType def))

loadPureDefinitionBody ::
  Monad m => Data.DefinitionIRef -> T m Data.PureExpression
loadPureDefinitionBody =
  loadPureExpression . Data.defExpression . Data.defBody <=< Transaction.readIRef

loadPureDefinitionType :: Monad m => Data.DefinitionIRef -> T m Data.PureExpression
loadPureDefinitionType =
  loadPureExpression . Data.defType <=< Transaction.readIRef

loadExpression
  :: (Monad m, Monad f)
  => Property (T f) Data.ExpressionIRef
  -> T m (ExpressionEntity (T f))
loadExpression exprP = do
  expr <- Data.readExprIRef exprI
  liftM (flip (Data.Expression (Data.exprIRefGuid exprI)) exprP) $
    case expr of
    Data.ExpressionLambda lambda ->
      liftM Data.ExpressionLambda $ loadLambda Data.ExpressionLambda lambda
    Data.ExpressionPi lambda ->
      liftM Data.ExpressionPi $ loadLambda Data.ExpressionPi lambda
    Data.ExpressionApply apply ->
      liftM2 Data.makeApply
      (loadExpression (applyFuncProp exprI apply))
      (loadExpression (applyArgProp exprI apply))
    Data.ExpressionLeaf x -> return $ Data.ExpressionLeaf x
  where
    exprI = Property.value exprP
    loadLambda cons lambda =
      liftM2 Data.Lambda
      (loadExpression (lambdaTypeProp cons exprI lambda))
      (loadExpression (lambdaBodyProp cons exprI lambda))

loadDefinition
  :: (Monad m, Monad f)
  => Data.DefinitionIRef
  -> T m (DefinitionEntity (T f))
loadDefinition defI = do
  def <- Transaction.readIRef defI
  liftM (DefinitionEntity defI) $
    liftM2 (Data.Definition . Data.DefinitionExpression)
    (loadExpression (defBodyProp defI def))
    (loadExpression (defTypeProp defI def))

defTypeProp
  :: Monad m
  => Data.DefinitionIRef -> Data.DefinitionI
  -> Data.ExpressionIRefProperty (T m)
defTypeProp defI (Data.Definition bodyI typeI) =
  Property typeI
  (Transaction.writeIRef defI . Data.Definition bodyI)

defBodyProp
  :: Monad m
  => Data.DefinitionIRef -> Data.DefinitionI
  -> Data.ExpressionIRefProperty (T m)
defBodyProp defI (Data.Definition (Data.DefinitionExpression bodyI) typeI) =
  Property bodyI
  (Transaction.writeIRef defI . flip Data.Definition typeI . Data.DefinitionExpression)

lambdaTypeProp
  :: Monad m
  => (Data.LambdaI -> Data.ExpressionI)
  -> Data.ExpressionIRef -> Data.LambdaI
  -> Data.ExpressionIRefProperty (T m)
lambdaTypeProp cons lambdaI (Data.Lambda paramTypeI bodyI) =
  Property paramTypeI
  (Data.writeExprIRef lambdaI . cons . flip Data.Lambda bodyI)

lambdaBodyProp
  :: Monad m
  => (Data.LambdaI -> Data.ExpressionI)
  -> Data.ExpressionIRef -> Data.LambdaI
  -> Data.ExpressionIRefProperty (T m)
lambdaBodyProp cons lambdaI (Data.Lambda paramTypeI bodyI) =
  Property bodyI
  (Data.writeExprIRef lambdaI . cons . Data.Lambda paramTypeI)

applyFuncProp
  :: Monad m
  => Data.ExpressionIRef
  -> Data.ApplyI -> Data.ExpressionIRefProperty (T m)
applyFuncProp applyI (Data.Apply funcI argI) =
  Property funcI
  (Data.writeExprIRef applyI . (`Data.makeApply` argI))

applyArgProp
  :: Monad m
  => Data.ExpressionIRef
  -> Data.ApplyI -> Data.ExpressionIRefProperty (T m)
applyArgProp applyI (Data.Apply funcI argI) =
  Property argI
  (Data.writeExprIRef applyI . Data.makeApply funcI)
