module Kit.Ir.IrExpr where

  import Kit.Str
  import Kit.Ast.Base
  import Kit.Ast.Modifier
  import Kit.Ast.Operator
  import Kit.Ast.Value
  import Kit.Ir.BasicType
  import Kit.Parser.Span

  data IrExpr
    = IrBlock [IrExpr]
    | IrLiteral ValueLiteral
    | IrIdentifier Str
    | IrPreUnop Operator IrExpr
    | IrPostUnop Operator IrExpr
    | IrBinop Operator IrExpr IrExpr
    | IrFor Str BasicType IrExpr IrExpr IrExpr
    | IrWhile IrExpr IrExpr
    | IrIf IrExpr IrExpr (Maybe IrExpr)
    | IrContinue
    | IrBreak
    | IrReturn (Maybe IrExpr)
    | IrField IrExpr Str
    | IrArrayAccess IrExpr IrExpr
    | IrCall IrExpr [IrExpr]
    | IrCast IrExpr BasicType
    | IrCArrLiteral [IrExpr]
    | IrVarDeclaration Str BasicType (Maybe IrExpr)
    deriving (Eq, Show)

  data IrDecl
    = IrVar Str BasicType (Maybe IrExpr)
    | IrFunction
    | IrType BasicType

  data IrModule = IrModule {
    irmod_path :: ModulePath,
    irmod_declarations :: [IrDecl],
    irmod_includes :: [FilePath]
  }