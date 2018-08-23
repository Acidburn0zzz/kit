module Kit.Compiler.Passes.SpecializeTypes where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.List
import Data.Maybe
import Kit.Ast
import Kit.Compiler.Binding
import Kit.Compiler.Context
import Kit.Compiler.Module
import Kit.Compiler.Scope
import Kit.Compiler.TypeContext
import Kit.Compiler.TypedDecl
import Kit.Compiler.TypedExpr
import Kit.Compiler.Unify
import Kit.Compiler.Utils
import Kit.Error
import Kit.HashTable
import Kit.Ir
import Kit.Parser
import Kit.Str

specializeTypes :: CompileContext -> IO ()
specializeTypes ctx = do
  unresolved <- h_toList (ctxUnresolvedTypeVars ctx)
  forM_ (map fst unresolved) $ \id -> do
    defaultType <- findDefaultType ctx id
    case defaultType of
      Just x -> do
        debugLog ctx $ "specializing type variable " ++ show id ++ " as " ++ show x
        info <- getTypeVar ctx id
        h_insert (ctxTypeVariables ctx) id (info { typeVarValue = Just x })
      _ -> return ()

findDefaultType :: CompileContext -> Int -> IO (Maybe ConcreteType)
findDefaultType ctx id = do
  info <- getTypeVar ctx id
  if null (typeVarConstraints info)
    then return Nothing
    else do
      tctx <- newTypeContext []
      let constraints = typeVarConstraints info
      defaults <- mapM (h_lookup (ctxTraitSpecializations ctx))
                       (map (fst . fst) constraints)
      let specializations = catMaybes defaults
      specialization <- foldM
        -- FIXME: we should be storing specializations as ConcreteTypes, not TypeSpecs
        (\acc (ct, _) -> do
          case acc of
            Just _  -> return acc
            Nothing -> do
              meetConstraints <- foldM
                (\acc' c -> case acc' of
                  Just _ -> do
                    -- FIXME: params
                    result <- unify ctx tctx ct (TypeTraitConstraint (c, []))
                    return $ case result of
                      Just _ -> acc'
                      _      -> Nothing
                  Nothing -> do
                    return acc'
                )
                (Just ct)
                (map (fst . fst) constraints)
              case meetConstraints of
                Just _  -> return meetConstraints
                Nothing -> return Nothing
        )
        Nothing
        specializations
      case specialization of
        Just t -> do
          return $ Just t
        _ -> throwk $ BasicError
          ("This expression has constraints: \n\n"
          ++ (intercalate
               "\n"
               [ "  - " ++ s_unpack (showTypePath c) ++ " (" ++ reason ++ ")"
               | ((c, _), (reason, _)) <- constraints
               ]
             )
          ++ "\n\nbut no specialization for one of these traits satisfies all of them, so no concrete type can be determined.\n\nTry adding a type annotation: `(myExpression: Type)`"
          )
          (Just $ head $ typeVarPositions info)
