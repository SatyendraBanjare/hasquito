{-# LANGUAGE OverloadedStrings #-}
module Language.Hasquito.Sanity where
import Language.Hasquito.Syntax
import Language.Hasquito.Util
import Control.Monad.Except
import Data.List (find)
import Data.Maybe (isJust)

noDuplicates :: [Name] -> CompilerM ()
noDuplicates [] = return ()
noDuplicates (x : xs) | elem x xs = throwError (DuplicateDefs x)
                      | otherwise = noDuplicates xs

hasMain :: [Def] -> CompilerM ()
hasMain defs = do
  when (not . isJust $ find isMain defs) $ throwError NoMain
  where isMain (Def ty nm _) = ty == TNum && nm == Name "main"

sanityCheck :: [Def] -> CompilerM [Def]
sanityCheck defs = do
  noDuplicates (map defName defs)
  hasMain defs
  return defs
