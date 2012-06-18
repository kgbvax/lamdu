{-# LANGUAGE
    TemplateHaskell,
    GeneralizedNewtypeDeriving
  #-}
module Editor.Data.Typed
  ( StoredExpressionRef(..)
  , atEeInferredType, atEeValue
  , eeReplace, eeGuid, eeIRef
  , GuidExpression(..)
  , InferredTypeLoop(..)
  , InferredType(..)
  , StoredDefinition(..)
  , atDeIRef, atDeValue
  , deGuid
  , loadInferDefinition
  , loadInferExpression
  , mapMExpressionEntities
  , StoredExpression(..), esGuid -- re-export from Data.Load
  , TypeData, TypedStoredExpression, TypedStoredDefinition
  ) where

--import qualified Data.Store.Transaction as Transaction
import Control.Applicative (Applicative)
import Control.Monad (liftM, liftM2, (<=<), when, unless, filterM)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Random (RandomT, nextRandom, runRandomT)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Control.Monad.Trans.State (execStateT)
import Control.Monad.Trans.UnionFind (UnionFindT, evalUnionFindT)
import Data.Functor.Identity (Identity(..))
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Monoid (Any(..), mconcat)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import Editor.Data.Load (StoredExpressionRef(..), esGuid)
import qualified Control.Monad.Trans.List.Funcs as ListFuncs
import qualified Control.Monad.Trans.Reader as Reader
import qualified Control.Monad.Trans.State as State
import qualified Control.Monad.Trans.UnionFind as UnionFind
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Binary.Utils as BinaryUtils
import qualified Data.List.Class as ListCls
import qualified Data.Map as Map
import qualified Data.Store.Guid as Guid
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Property as Property
import qualified Editor.Anchors as Anchors
import qualified Editor.Data as Data
import qualified Editor.Data.Load as DataLoad
import qualified System.Random as Random

type T = Transaction ViewTag

type TypedStoredExpression = StoredExpression [InferredTypeLoop]
type TypedStoredDefinition = StoredDefinition [InferredTypeLoop]

eeGuid :: StoredExpression it m -> Guid
eeGuid = esGuid . eeStored

newtype TypeData = TypeData
  { unTypeData :: [GuidExpression TypeRef]
  } deriving (Show)
type TypeRef = UnionFind.Point TypeData

newtype InferredType = InferredType
  { unInferredType :: GuidExpression InferredType
  } deriving (Show, Eq)

data GuidExpression ref = GuidExpression
  { geGuid :: Guid
  , geValue :: Data.Expression ref
  } deriving (Show, Eq)

data StoredExpression it m = StoredExpression
  { eeStored :: DataLoad.StoredExpressionRef m
  , eeInferredType :: it
  , eeValue :: Data.Expression (StoredExpression it m)
  } deriving (Eq)

data InferredTypeLoop
  = InferredTypeNoLoop (GuidExpression InferredTypeLoop)
  | InferredTypeLoop Guid
  deriving (Show, Eq)

data StoredDefinition it m = StoredDefinition
  { deIRef :: Data.DefinitionIRef
  , deValue :: Data.Definition (StoredExpression it m)
  } deriving (Eq)

deGuid :: StoredDefinition it m -> Guid
deGuid = IRef.guid . deIRef

AtFieldTH.make ''GuidExpression
AtFieldTH.make ''StoredExpression
AtFieldTH.make ''StoredDefinition

eeReplace :: StoredExpression it m -> Maybe (Data.ExpressionIRef -> m ())
eeReplace = esReplace . eeStored

eeIRef :: StoredExpression it m -> Data.ExpressionIRef
eeIRef = esIRef . eeStored

--------------- Infer Stack boilerplate:

type Scope = [(Guid, TypeRef)]

newtype Infer m a = Infer
  { unInfer
    :: ReaderT Scope
       (UnionFindT TypeData
        (RandomT Random.StdGen (T m))) a
  } deriving (Functor, Applicative, Monad)
AtFieldTH.make ''Infer

liftScope
  :: ReaderT Scope (UnionFindT TypeData (RandomT Random.StdGen (T m))) a
  -> Infer m a
liftScope = Infer

liftTypeRef
  :: Monad m
  => UnionFindT TypeData (RandomT Random.StdGen (T m)) a -> Infer m a
liftTypeRef = liftScope . lift

liftRandom
  :: Monad m
  => RandomT Random.StdGen (T m) a -> Infer m a
liftRandom = liftTypeRef . lift

liftTransaction
  :: Monad m => T m a -> Infer m a
liftTransaction = liftRandom . lift

-- Reader "local" operation cannot simply be lifted...
localScope
  :: Monad m => (Scope -> Scope)
  -> Infer m a -> Infer m a
localScope = atInfer . Reader.local

----------------- Infer operations:

makeTypeRef :: Monad m => [GuidExpression TypeRef] -> Infer m TypeRef
makeTypeRef = liftTypeRef . UnionFind.new . TypeData

getTypeRef :: Monad m => TypeRef -> Infer m [GuidExpression TypeRef]
getTypeRef = liftM unTypeData . liftTypeRef . UnionFind.descr

setTypeRef :: Monad m => TypeRef -> [GuidExpression TypeRef] -> Infer m ()
setTypeRef typeRef types =
  liftTypeRef . UnionFind.setDescr typeRef $
  TypeData types

runInfer
  :: Monad m
  => Infer m (TypedStoredExpression f)
  -> T m (TypedStoredExpression f)
runInfer action =
  liftM canonizeIdentifiersTypes .
    runRandomT (Random.mkStdGen 0) .
    evalUnionFindT .
    (`runReaderT` []) $
    unInfer action

putInScope
  :: Monad m => [(Guid, TypeRef)]
  -> Infer m a
  -> Infer m a
putInScope = localScope . (++)

readScope :: Monad m => Infer m Scope
readScope = liftScope Reader.ask

nextGuid :: Monad m => Infer m Guid
nextGuid = liftRandom nextRandom

findInScope :: Monad m => Guid -> Infer m (Maybe TypeRef)
findInScope guid = liftM (lookup guid) readScope

generateEntity
  :: Monad m
  => Data.Expression TypeRef
  -> Infer m TypeRef
generateEntity v = do
  g <- nextGuid
  makeTypeRef [GuidExpression g v]

generateEmptyEntity :: Monad m => Infer m TypeRef
generateEmptyEntity = makeTypeRef []

--------------

mapMExpressionEntities
  :: Monad m
  => (StoredExpressionRef f
      -> a
      -> Data.Expression (StoredExpression b g)
      -> m (StoredExpression b g))
  -> StoredExpression a f
  -> m (StoredExpression b g)
mapMExpressionEntities f =
  Data.mapMExpression g
  where
    g (StoredExpression stored a val) =
      (return val, f stored a)

atInferredTypes
  :: Monad m
  => (StoredExpressionRef f -> a -> m b)
  -> StoredExpression a f
  -> m (StoredExpression b f)
atInferredTypes f =
  mapMExpressionEntities g
  where
    g stored a v = do
      b <- f stored a
      return $ StoredExpression stored b v

fromEntity
  :: Monad m => (Guid -> Data.Expression ref -> m ref)
  -> StoredExpression it f -> m ref
fromEntity mk =
  Data.mapMExpression f
  where
    f (StoredExpression stored _ val) =
      ( return val
      , mk $ esGuid stored
      )

inferredTypeFromEntity
  :: StoredExpression it f -> InferredType
inferredTypeFromEntity =
  fmap runIdentity $ fromEntity f
  where
    f guid = return . InferredType . GuidExpression guid

ignoreStoredMonad
  :: StoredExpression it (T Identity)
  -> StoredExpression it (T Identity)
ignoreStoredMonad = id

expand :: Monad m => StoredExpression it f -> T m InferredType
expand =
  (`runReaderT` Map.empty) . recurse . inferredTypeFromEntity
  where
    recurse e@(InferredType (GuidExpression guid val)) =
      case val of
      Data.ExpressionGetVariable (Data.DefinitionRef defI) ->
        -- TODO: expand the result recursively (with some recursive
        -- constraint)
        liftM
        (inferredTypeFromEntity .
         ignoreStoredMonad .
         fromLoaded () . Data.defBody . DataLoad.defEntityValue) .
        lift $ DataLoad.loadDefinition defI
      Data.ExpressionGetVariable (Data.ParameterRef guidRef) -> do
        mValueEntity <- Reader.asks (Map.lookup guidRef)
        return $ fromMaybe e mValueEntity
      Data.ExpressionApply
        (Data.Apply
         (InferredType
          (GuidExpression lamGuid
           -- TODO: Don't ignore paramType, we do want to recursively
           -- type-check this:
           (Data.ExpressionLambda (Data.Lambda _paramType body))))
         argEntity) -> do
          newArgEntity <- recurse argEntity
          Reader.local (Map.insert lamGuid newArgEntity) $
            recurse body
      Data.ExpressionLambda (Data.Lambda paramType body) ->
        recurseLambda Data.ExpressionLambda paramType body
      Data.ExpressionPi (Data.Lambda paramType body) -> do
        newParamType <- recurse paramType
        recurseLambda Data.ExpressionPi newParamType body
      _ -> return e
      where
        recurseLambda cons paramType body = do
          newBody <- recurse body
          return .
            InferredType . GuidExpression guid . cons $
            Data.Lambda paramType newBody

typeRefFromEntity
  :: Monad m => StoredExpression it f
  -> Infer m TypeRef
typeRefFromEntity =
  Data.mapMExpression f <=< liftTransaction . expand
  where
    f (InferredType (GuidExpression guid val)) =
      ( return val
      , makeTypeRef . (: []) . GuidExpression guid
      )

fromLoaded
  :: it
  -> DataLoad.ExpressionEntity f
  -> StoredExpression it f
fromLoaded it =
  runIdentity . Data.mapMExpression f
  where
    f (DataLoad.ExpressionEntity stored val) =
      (return val, makeEntity stored)
    makeEntity stored newVal =
      return $ StoredExpression stored it newVal

addTypeRefs
  :: Monad m
  => StoredExpression () f
  -> Infer m (StoredExpression TypeRef f)
addTypeRefs =
  mapMExpressionEntities f
  where
    f stored () val = do
      typeRef <- generateEmptyEntity
      return $ StoredExpression stored typeRef val

derefTypeRef
  :: Monad m
  => TypeRef -> Infer m [InferredTypeLoop]
derefTypeRef =
  ListCls.toList . (`runReaderT` []) . go
  where
    liftInfer = lift . lift
    go typeRef = do
      visited <- Reader.ask
      isLoop <- liftInfer . liftTypeRef . liftM or $
        mapM (UnionFind.equivalent typeRef) visited
      if isLoop
        then liftM InferredTypeLoop $ liftInfer nextGuid
        else onType typeRef =<< lift . ListFuncs.fromList =<< liftInfer (getTypeRef typeRef)
    onType typeRef (GuidExpression guid expr) =
      liftM (InferredTypeNoLoop . GuidExpression guid) .
      Data.sequenceExpression $ Data.mapExpression recurse expr
      where
        recurse = Reader.mapReaderT (ListFuncs.fromList <=< lift . (holify <=< ListCls.toList)) . Reader.local (typeRef :) . go
        holify [] = do
          g <- nextGuid
          return [InferredTypeNoLoop (GuidExpression g Data.ExpressionHole)]
        holify xs = return xs

derefTypeRefs
  :: Monad m
  => StoredExpression TypeRef f
  -> Infer m (StoredExpression [InferredTypeLoop] f)
derefTypeRefs =
  mapMExpressionEntities f
  where
    f stored typeRef val = do
      types <- derefTypeRef typeRef
      return $ StoredExpression stored types val

unifyOnTree
  :: Monad m
  => StoredExpression TypeRef f
  -> Infer m ()
unifyOnTree (StoredExpression stored typeRef value) = do
  setType =<< generateEmptyEntity
  case value of
    Data.ExpressionLambda lambda ->
      handleLambda lambda
    Data.ExpressionPi lambda@(Data.Lambda _ resultType) ->
      inferLambda lambda . const . return $ eeInferredType resultType
    Data.ExpressionApply (Data.Apply func arg) -> do
      unifyOnTree func
      unifyOnTree arg
      let
        funcTypeRef = eeInferredType func
        argTypeRef = eeInferredType arg
        piType = Data.ExpressionPi $ Data.Lambda argTypeRef typeRef
      unify funcTypeRef =<< generateEntity piType
      funcTypes <- getTypeRef funcTypeRef
      sequence_
        [ subst piGuid (typeRefFromEntity arg) piResultTypeRef
        | GuidExpression piGuid
          (Data.ExpressionPi
           (Data.Lambda _ piResultTypeRef))
          <- funcTypes
        ]
    Data.ExpressionGetVariable (Data.ParameterRef guid) -> do
      mParamTypeRef <- findInScope guid
      case mParamTypeRef of
        -- TODO: Not in scope: Bad code,
        -- add an OutOfScopeReference type error
        Nothing -> return ()
        Just paramTypeRef -> setType paramTypeRef
    Data.ExpressionGetVariable (Data.DefinitionRef defI) -> do
      defTypeEntity <-
        liftM (fromLoaded [] . Data.defType . DataLoad.defEntityValue) .
        liftTransaction $
        DataLoad.loadDefinition defI
      defTypeRef <- typeRefFromEntity $ ignoreStoredMonad defTypeEntity
      setType defTypeRef
    Data.ExpressionLiteralInteger _ ->
      setType <=< generateEntity . Data.ExpressionBuiltin $ Data.FFIName ["Prelude"] "Integer"
    _ -> return ()
  where
    setType = unify typeRef
    handleLambda lambda@(Data.Lambda _ body) =
      inferLambda lambda $ \paramTypeRef ->
        generateEntity . Data.ExpressionPi .
        Data.Lambda paramTypeRef $
        eeInferredType body
    inferLambda (Data.Lambda paramType result) mkType = do
      paramTypeRef <- typeRefFromEntity paramType
      setType =<< mkType paramTypeRef
      putInScope [(esGuid stored, paramTypeRef)] $
        unifyOnTree result

tryRemap :: Ord k => k -> Map k k -> k
tryRemap x = fromMaybe x . Map.lookup x

unify
  :: Monad m
  => TypeRef
  -> TypeRef
  -> Infer m ()
unify a b = do
  e <- liftTypeRef $ UnionFind.equivalent a b
  unless e $ do
    as <- getTypeRef a
    bs <- getTypeRef b
    result <- liftM (as ++) $ filterM (liftM not . matches as) bs
    liftTypeRef $ do
      a `UnionFind.union` b
      UnionFind.setDescr a $ TypeData result
  where
    matches as y = liftM or $ mapM (`unifyPair` y) as

-- biased towards left child (if unifying Pis,
-- substs right child's guids to left)
unifyPair
  :: Monad m
  => GuidExpression TypeRef
  -> GuidExpression TypeRef
  -> Infer m Bool
unifyPair
  (GuidExpression aGuid aVal)
  (GuidExpression bGuid bVal)
  = case (aVal, bVal) of
    (Data.ExpressionPi l1,
     Data.ExpressionPi l2) ->
      unifyLambdas l1 l2
    (Data.ExpressionLambda l1,
     Data.ExpressionLambda l2) ->
      unifyLambdas l1 l2
    (Data.ExpressionApply (Data.Apply aFuncTypeRef aArgTypeRef),
     Data.ExpressionApply (Data.Apply bFuncTypeRef bArgTypeRef)) -> do
      unify aFuncTypeRef bFuncTypeRef
      unify aArgTypeRef bArgTypeRef
      return True
    (Data.ExpressionBuiltin bi1,
     Data.ExpressionBuiltin bi2) -> return $ bi1 == bi2
    (Data.ExpressionGetVariable v1,
     Data.ExpressionGetVariable v2) -> return $ v1 == v2
    (Data.ExpressionLiteralInteger i1,
     Data.ExpressionLiteralInteger i2) -> return $ i1 == i2
    (Data.ExpressionMagic,
     Data.ExpressionMagic) -> return True
    _ -> return False
  where
    unifyLambdas
      (Data.Lambda aParamTypeRef aResultTypeRef)
      (Data.Lambda bParamTypeRef bResultTypeRef) = do
      unify aParamTypeRef bParamTypeRef
      -- Remap b's guid to a's guid and return a as the unification:
      let
        mkGetAGuidRef =
          generateEntity . Data.ExpressionGetVariable . Data.ParameterRef $
          aGuid
      subst bGuid mkGetAGuidRef bResultTypeRef
      unify aResultTypeRef bResultTypeRef
      return True

subst :: Monad m => Guid -> Infer m TypeRef -> TypeRef -> Infer m ()
subst from mkTo rootRef = do
  refs <- allUnder rootRef
  mapM_ replace refs
  where
    removeFrom
      a@(GuidExpression _
       (Data.ExpressionGetVariable (Data.ParameterRef guidRef)))
      | guidRef == from = (Any True, [])
      | otherwise = (Any False, [a])
    removeFrom x = (Any False, [x])
    replace typeRef = do
      (Any removed, new) <- liftM (mconcat . map removeFrom) $ getTypeRef typeRef
      when removed $ do
        setTypeRef typeRef new
        unify typeRef =<< mkTo

allUnder :: Monad m => TypeRef -> Infer m [TypeRef]
allUnder =
  (`execStateT` []) . recurse
  where
    recurse typeRef = do
      visited <- State.get
      alreadySeen <-
        lift . liftTypeRef . liftM or $
        mapM (UnionFind.equivalent typeRef) visited
      unless alreadySeen $ do
        State.modify (typeRef :)
        types <- lift $ getTypeRef typeRef
        mapM_ onType types
    onType entity =
      case geValue entity of
      Data.ExpressionPi (Data.Lambda p r) -> recurse p >> recurse r
      Data.ExpressionLambda (Data.Lambda p r) -> recurse p >> recurse r
      Data.ExpressionApply (Data.Apply f a) -> recurse f >> recurse a
      _ -> return ()

canonizeIdentifiersTypes
  :: TypedStoredExpression m
  -> TypedStoredExpression m
canonizeIdentifiersTypes =
  runIdentity . atInferredTypes canonizeTypes
  where
    canonizeTypes stored =
      return . zipWith canonizeIdentifiers (gens (esGuid stored))
    gens guid =
      map Random.mkStdGen . Random.randoms $
      guidToStdGen guid
    guidToStdGen = Random.mkStdGen . BinaryUtils.decodeS . Guid.bs
    canonizeIdentifiers gen =
      runIdentity . runRandomT gen . (`runReaderT` Map.empty) . f
      where
        onLambda oldGuid newGuid (Data.Lambda paramType body) =
          liftM2 Data.Lambda (f paramType) .
          Reader.local (Map.insert oldGuid newGuid) $ f body
        f (InferredTypeLoop guid) = return $ InferredTypeLoop guid
        f (InferredTypeNoLoop (GuidExpression oldGuid v)) = do
          newGuid <- lift nextRandom
          liftM (InferredTypeNoLoop . GuidExpression newGuid) $
            case v of
            Data.ExpressionLambda lambda ->
              liftM Data.ExpressionLambda $ onLambda oldGuid newGuid lambda
            Data.ExpressionPi lambda ->
              liftM Data.ExpressionPi $ onLambda oldGuid newGuid lambda
            Data.ExpressionApply (Data.Apply func arg) ->
              liftM Data.ExpressionApply $
              liftM2 Data.Apply (f func) (f arg)
            Data.ExpressionGetVariable (Data.ParameterRef guid) ->
              Reader.asks
              (Data.ExpressionGetVariable . Data.ParameterRef . tryRemap guid)
            x -> return x

builtinsToGlobals :: Map Data.FFIName Data.VariableRef -> InferredTypeLoop -> InferredTypeLoop
builtinsToGlobals _ x@(InferredTypeLoop _) = x
builtinsToGlobals builtinsMap (InferredTypeNoLoop (GuidExpression guid expr)) =
  InferredTypeNoLoop . GuidExpression guid $
  case expr of
  builtin@(Data.ExpressionBuiltin name) ->
    (maybe builtin Data.ExpressionGetVariable . Map.lookup name)
    builtinsMap
  Data.ExpressionApply (Data.Apply f a) ->
    Data.ExpressionApply $ Data.Apply (go f) (go a)
  Data.ExpressionLambda lambda ->
    Data.ExpressionLambda $ onLambda lambda
  Data.ExpressionPi lambda ->
    Data.ExpressionPi $ onLambda lambda
  _ -> expr
  where
    go = builtinsToGlobals builtinsMap
    onLambda (Data.Lambda p r) = Data.Lambda (go p) (go r)

inferExpression
 :: Monad m
 => Maybe TypeRef
 -> StoredExpression () f
 -> Infer m (TypedStoredExpression f)
inferExpression mTypeRef expr = do
  withTypeRefs <- addTypeRefs expr
  case mTypeRef of
    Nothing -> return ()
    Just typeRef ->
      unify typeRef $ eeInferredType withTypeRefs
  unifyOnTree withTypeRefs
  builtinsMap <- liftTransaction $ Property.get Anchors.builtinsMap
  derefed <- derefTypeRefs withTypeRefs
  return . runIdentity . (atInferredTypes . const) (Identity . map (builtinsToGlobals builtinsMap)) $ derefed

inferDefinition
  :: Monad m
  => DataLoad.DefinitionEntity (T f)
  -> T m (TypedStoredDefinition (T f))
inferDefinition (DataLoad.DefinitionEntity iref value) =
  liftM (StoredDefinition iref) $
  case value of
  Data.Definition typeI bodyI -> do
    let inferredType = canonizeIdentifiersTypes $ fromLoaded [] typeI

    inferredBody <- runInfer $ do
      inferredTypeRef <- typeRefFromEntity inferredType
      inferExpression (Just inferredTypeRef) $ fromLoaded () bodyI
    return $ Data.Definition inferredType inferredBody

loadInferDefinition
  :: Monad m => Data.DefinitionIRef
  -> T m (TypedStoredDefinition (T m))
loadInferDefinition =
  inferDefinition <=< DataLoad.loadDefinition

loadInferExpression
  :: Monad m => Data.ExpressionIRef
  -> T m (TypedStoredExpression (T m))
loadInferExpression =
  runInfer . inferExpression Nothing . fromLoaded () <=<
  flip DataLoad.loadExpression Nothing
