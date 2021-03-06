module Kit.Compiler.Generators.C.GenerateCHeader where

import Control.Monad
import Data.IORef
import Data.List
import Data.Maybe
import Data.Ord
import Language.C
import System.Directory
import System.FilePath
import System.IO
import Text.PrettyPrint
import Kit.Ast
import Kit.Compiler.Generators.C.CExpr
import Kit.Compiler.Generators.C.CFun
import Kit.Compiler.Generators.C.CTypeDecl
import Kit.Compiler.Context
import Kit.Compiler.Module
import Kit.Compiler.Utils
import Kit.HashTable
import Kit.Ir
import Kit.Str

generateProjectHeader :: CompileContext -> [(Module, [IrBundle])] -> IO ()
generateProjectHeader ctx ir = do
  let headerFilePath = includePath ctx
  debugLog ctx $ "generating project header in " ++ headerFilePath
  createDirectoryIfMissing True $ takeDirectory $ headerFilePath
  handle   <- openFile headerFilePath WriteMode
  -- include native dependencies
  includes <- readIORef $ ctxIncludes ctx
  forM_ (nub includes) $ \filepath -> do
    hPutStrLn handle $ "#include \"" ++ filepath ++ "\""
  let flatDecls = foldr
        (++)
        []
        [ bundleMembers bundle | (_, bundles) <- ir, bundle <- bundles ]
  let forwardDecls = map generateHeaderForwardDecl flatDecls
  forM_ (nub $ catMaybes forwardDecls) $ hPutStrLn handle
  sorted <- sortHeaderDefs flatDecls
  let defs = map generateHeaderDef sorted
  forM_ (catMaybes defs) $ hPutStrLn handle
  hClose handle
  return ()

sortHeaderDefs :: [IrDecl] -> IO [IrDecl]
sortHeaderDefs decls = do
  memos        <- h_newSized (length decls)
  dependencies <- h_newSized (length decls)
  -- memoize BasicType dependencies of type declarations
  forM_ decls $ \decl -> case decl of
    DeclType t -> case typeSubtype t of
      Struct { structFields = fields } ->
        h_insert dependencies (typeName t) (map varType fields)
      Union { unionFields = fields } ->
        h_insert dependencies (typeName t) (map varType fields)
      Enum { enumVariants = variants } -> h_insert
        dependencies
        (typeName t)
        (nub [ argType arg | variant <- variants, arg <- variantArgs variant ])
      _ -> return ()
    _ -> return ()
  scored <- forM decls $ \decl -> do
    score <- btOrder dependencies memos (declToBt decl)
    return (if score == (-1) then (1 / 0) else realToFrac score, decl)
  return $ map snd $ sortBy (\(a, _) (b, _) -> if a > b then GT else LT)
                            (nub scored)

declToBt :: IrDecl -> BasicType
declToBt (DeclTuple t) = t
declToBt (DeclType  t) = case typeBasicType t of
  Just x  -> x
  Nothing -> BasicTypeUnknown
declToBt t = BasicTypeUnknown

btOrder
  :: HashTable TypePath [BasicType]
  -> HashTable BasicType Int
  -> BasicType
  -> IO Int
btOrder dependencies memos t = do
  let depScore deps = (foldr max (-1) deps) + 1
  let tpScore tp = do
        deps <- h_lookup dependencies tp
        case deps of
          Just x -> do
            deps <- forM x $ btOrder dependencies memos
            return $ (depScore deps) + 1
          Nothing -> return 0
  existing <- h_lookup memos t
  case existing of
    Just x -> return x
    _      -> do
      score <- case t of
        BasicTypeTuple _ fields -> do
          deps <- forM fields $ btOrder dependencies memos
          return $ depScore deps
        BasicTypeStruct      tp -> tpScore tp
        BasicTypeUnion       tp -> tpScore tp
        BasicTypeSimpleEnum  tp -> tpScore tp
        BasicTypeComplexEnum tp -> tpScore tp
        CArray t _              ->do
          depScore <- btOrder dependencies memos t
          return $ depScore + 1
        _                       -> return (-1)
      h_insert memos t score
      return score

bundleDef :: Str -> String
bundleDef s = "KIT_INCLUDE__" ++ s_unpack s

generateHeaderForwardDecl :: IrDecl -> Maybe String
generateHeaderForwardDecl decl = case decl of
  DeclTuple t -> generateTypeForwardDecl t
  DeclType  def@(TypeDefinition { typeName = name }) -> do
    case typeBasicType def of
      -- ISO C forbids forward references to enum types
      Just t  -> generateTypeForwardDecl t
      Nothing -> Nothing
  _ -> Nothing

generateTypeForwardDecl :: BasicType -> Maybe String
generateTypeForwardDecl t = case t of
  BasicTypeAnonEnum _ _  -> Nothing
  BasicTypeSimpleEnum  _ -> Nothing
  BasicTypeComplexEnum _ -> Nothing
  _ -> Just (render $ pretty $ CDeclExt $ cDecl t Nothing Nothing)

generateHeaderDef :: IrDecl -> Maybe String
generateHeaderDef decl = case decl of
  DeclTuple (BasicTypeTuple name slots) ->
    let decls = cTupleDecl name slots
    in  Just $ intercalate "\n" $ map (\d -> render $ pretty $ CDeclExt d) decls

  DeclType def@(TypeDefinition{}) ->
    let decls = cTypeDecl def
    in  Just $ intercalate "\n" $ map (\d -> render $ pretty $ CDeclExt d) decls

  DeclFunction def@(FunctionDefinition { functionType = t, functionArgs = args, functionVarargs = varargs })
    -> Just $ render $ pretty $ CDeclExt $ cfunDecl (functionName def)
                                                    (functionBasicType def)

  DeclVar def@(VarDefinition { varType = t }) ->
    Just $ render $ pretty $ CDeclExt $ cDecl t (Just $ varRealName def) Nothing

  _ -> Nothing

functionBasicType :: FunctionDefinition a BasicType -> BasicType
functionBasicType (FunctionDefinition { functionType = t, functionArgs = args, functionVarargs = varargs })
  = (BasicTypeFunction t (map (\arg -> (argName arg, argType arg)) args) varargs
    )

typeBasicType :: TypeDefinition a BasicType -> Maybe BasicType
typeBasicType def@(TypeDefinition { typeName = name }) =
  case typeSubtype def of
    Struct { structFields = fields } -> Just $ BasicTypeStruct name
    Union { unionFields = fields }   -> Just $ BasicTypeUnion name
    Enum { enumVariants = variants } -> if all variantIsSimple variants
      then Just $ BasicTypeSimpleEnum name
      else Just $ BasicTypeComplexEnum name
    _ -> Nothing
