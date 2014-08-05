module Language.Hasquito.JSify where
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Reader
import qualified Data.Map as M
import qualified Data.Text as T
import           Language.Hasquito.STG
import qualified Language.Hasquito.Syntax as S
import           Language.Hasquito.Util
import           Language.JavaScript.AST
import           Language.JavaScript.NonEmptyList

data Closure = Closure { topClos  :: M.Map Name [Name] -- ^ A map of names to closed variables
                       , currClos :: M.Map Name Int -- ^ A map of closed over variables to their current position
                       }

type CodeGenM = ReaderT Closure CompilerM

jname :: String -> CodeGenM Name
jname = either (throwError . Impossible . T.pack) return . name

jvar :: S.Name -> CodeGenM Name
jvar (S.Gen i)  = either (throwError . Impossible . T.pack) return
                  . name
                  $ ('_' : show i)
jvar (S.Name s) = either (throwError . Impossible . T.pack) return
                  . name
                  . T.unpack
                  $ s

block :: [CodeGenM Stmt] -> CodeGenM Stmt
block = fmap dummyIf . sequence
  where dummyIf ss = StmtIf $ IfStmt (ExprLit $ LitBool True) ss Nothing

opCont :: S.Op -> CodeGenM Name
opCont S.Plus  = jname "doPlus"
opCont S.Minus = jname "doMinus"
opCont S.Mult  = jname "doMult"
opCont S.Div   = jname "doDiv"

enter :: Expr -> CodeGenM Stmt
enter e = do
  enterName <- jname "enter"
  return . StmtExpr $
    singleton (LValue enterName []) `ESApply`
     (RVInvoke . singleton . Invocation) [e]


-- This is a fun word.
closurify :: Expr -> CodeGenM Expr
closurify = undefined

pushStack :: Expr -> Name -> CodeGenM Stmt
pushStack exp nm = do
  closed   <- closurify exp
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

jump :: CodeGenM Stmt
jump = do
  jump <- jname "jumpNext"
  return . StmtExpr $
    singleton (LValue jump []) `ESApply`
     (RVInvoke . singleton . Invocation) []

prim :: S.Op -> Expr -> Expr -> CodeGenM Stmt
prim op l r = block [ pushArg r
                    , opCont op >>= pushCont . ExprName
                    , eval >>= pushCont
                    , eval >>= pushCont
                    , enter l ]

lit :: Int -> CodeGenM Stmt
lit i = block [ pushEval . ExprLit . LitNumber . Number . fromIntegral $ i
              , jump ]
