{-# LANGUAGE OverloadedStrings #-}
module Language.Hasquito.JSify where
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Reader
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import           Language.Hasquito.STG
import qualified Language.Hasquito.Syntax as S
import           Language.Hasquito.Util
import           Language.JavaScript.AST
import           Language.JavaScript.NonEmptyList

data Closure = Closure { topClos  :: M.Map S.Name [S.Name] -- ^ A map of names to closed variables
                       , currClos :: M.Map S.Name Int      -- ^ A map of closed over variables to their current position
                       , updateClos :: S.Set S.Name 
                       }
type CodeGenM = ReaderT Closure CompilerM

jname :: String -> CodeGenM Name
jname = either (throwError . Impossible . T.pack) return . name

jvar :: S.Name -> CodeGenM Name
jvar (S.Gen i)  = jname ('_' : show i)
jvar (S.Name s) = jname . T.unpack $ s

opCont :: S.Op -> CodeGenM Name
opCont S.Plus  = jname "doPlus"
opCont S.Minus = jname "doMinus"
opCont S.Mult  = jname "doMult"
opCont S.Div   = jname "doDiv"

enter :: Expr -> CodeGenM Stmt
enter e = do
  enter <- jname "enter"
  let call = ExprInvocation (ExprName enter) (Invocation [e])
  return . StmtDisruptive . DSReturn . ReturnStmt . Just $ call

index :: Int -> CodeGenM Expr
index i = do
  [node, closed] <- sequence [jname "NODE", jname "closed_vars"]
  return $
    ExprRefinement (ExprName node) (Property closed)
    `ExprRefinement` Subscript (ExprLit . LitNumber . Number $ fromIntegral i)

mkClosure :: Bool -> Expr -> [Expr] -> CodeGenM Expr
mkClosure updateFlag f args = do
  mk <- ExprName <$> jname "mkClosure"
  return $ ExprInvocation mk (Invocation $ [f, list, if updateFlag then true else false])
  where list = ExprLit . LitArray . ArrayLit $ args
        true  = ExprLit . LitNumber . Number $ 1
        false = ExprLit . LitNumber . Number $ 0

findVar :: M.Map S.Name Int -> S.Name -> CodeGenM Expr
findVar m name = case M.lookup name m of
  Just i  -> index i
  Nothing -> ExprName <$> jvar name

resolve :: S.Name -> CodeGenM Expr -> CodeGenM Expr
resolve nm expr = do
  result <- asks (M.lookup nm . topClos)
  updateFlag <- asks (S.member nm . updateClos)
  case result of
    Nothing -> expr
    Just cs -> do
      clos <- asks currClos
      closure <- mapM (findVar clos) cs
      expr >>= flip (mkClosure updateFlag) closure

pushStack :: Expr -> Name -> CodeGenM Stmt
pushStack exp nm = do
  push     <- jname "push"
  return . StmtExpr $
    singleton (LValue nm [([], Property push)]) `ESApply`
    (RVInvoke . singleton . Invocation) [exp]
  
pushArg :: Expr -> CodeGenM Stmt
pushArg e = jname "ARG_STACK" >>= pushStack e

pushCont :: Expr -> CodeGenM Stmt
pushCont e = jname "CONT_STACK" >>= pushStack e

pushEval :: Expr -> CodeGenM Stmt
pushEval e = jname "EVAL_STACK" >>= pushStack e

eval :: CodeGenM Expr
eval = ExprName <$> jname "evalFirst"

sif :: Expr -> Expr -> Expr -> CodeGenM Stmt
sif n l r = do
  sif <- jname "sif"
  let call = ExprInvocation (ExprName sif) (Invocation [n, l, r])
  return . StmtDisruptive . DSReturn . ReturnStmt . Just $ call

jump :: CodeGenM Stmt
jump = do
  jump <- jname "jumpNext"  
  let call = ExprInvocation (ExprName jump) (Invocation [])
  return . StmtDisruptive . DSReturn . ReturnStmt . Just $ call

nextArg :: CodeGenM Expr
nextArg = do
  next <- jname "nextArg"
  return $ ExprInvocation (ExprName next) (Invocation [])

prim :: S.Op -> Expr -> Expr -> CodeGenM [Stmt]
prim op l r = sequence [ pushArg r
                       , ExprName <$> opCont op >>= pushCont
                       , eval >>= pushCont
                       , enter l]

lit :: Int -> CodeGenM [Stmt]
lit i = sequence [ pushEval . ExprLit . LitNumber . Number . fromIntegral $ i
                 , jump ]

app :: Expr -> Expr -> CodeGenM [Stmt]
app f a = sequence [ pushArg a
                   , enter f ]

preamble :: [S.Name] -> [S.Name] -> [Stmt] -> CodeGenM FnLit
preamble bound closured body = fmap (FnLit Nothing []) $ do
  vars <- (++) <$> mapM bindArgVar bound
          <*> mapM bindClosVar (zip [0..] closured)
  return $ FnBody vars body
  where bindArgVar v       = var <$> jvar v <*> nextArg
        bindClosVar (i, v) = var <$> jvar v <*> index i
        var l r = VarStmt . singleton $ VarDecl l (Just r)

handleVar :: S.Name -> CodeGenM Expr
handleVar v = resolve v (ExprName <$> jvar v)

entryCode :: SExp -> CodeGenM [Stmt]
entryCode (SNum i) = lit i
entryCode (SVar v) = (:[]) <$> (handleVar v >>= enter)
entryCode (SApp (SVar r) (SVar l)) = join $ app <$> handleVar r <*> handleVar l
entryCode (FullApp op l r) = join $ prim op <$> handleVar l <*> handleVar r
entryCode (SIf (SVar n) (SVar l) (SVar r)) = fmap (:[]). join $
                                                    sif <$> handleVar n
                                                        <*> handleVar l
                                                        <*> handleVar r
entryCode _ = throwError . Impossible $ "Found unflattened expression in entryCode generation!"

extractClosure :: TopLevel -> [S.Name]
extractClosure (Thunk closed _ _) = closed
extractClosure (Fun _ closed _ _) = closed

extractName :: TopLevel -> S.Name
extractName (Thunk _ n _) = n
extractName (Fun n _ _ _) = n

shouldUpdate :: TopLevel -> Bool
shouldUpdate Thunk{} = True
shouldUpdate Fun{}   = False

define :: Name -> FnLit -> VarDecl
define name = VarDecl name . Just . ExprLit . LitFn

jsify :: [TopLevel] -> CompilerM [VarDecl]
jsify decls = mapM compile decls
  where closureMap = M.fromList $ zip (map extractName decls) (map extractClosure decls)
        updateSet  = S.fromList . map extractName . filter shouldUpdate $ decls
        buildState = flip (Closure closureMap) updateSet . M.fromList . flip zip [0..]
        compile (Thunk closed name body) = flip runReaderT (buildState closed) $ do
          name' <- jvar name
          body' <- entryCode body
          fmap (define name') . preamble [] closed $ body'
        compile (Fun name closed arg body) = flip runReaderT (buildState closed) $ do
          name' <- jvar name
          body' <- entryCode body
          fmap (define name') . preamble [arg] closed $ body'
