{-# LANGUAGE OverloadedStrings #-}
module LogicIR.Frontend.Java (javaExpToLExpr) where

import JavaHelpers.Folds
import JavaHelpers.HelperFunctions

import Language.Java.Pretty
import Language.Java.Syntax

import Data.String
import LogicIR.Expr
import LogicIR.Parser ()

javaExpToLExpr :: Exp -> TypeEnv -> [TypeDecl] -> LExpr
javaExpToLExpr = foldExp javaExpToLExprAlgebra

-- Converts a name to a LogicIR.Var, it queries the type environment to find the correct type.
nameToVar :: Name -> TypeEnv -> [TypeDecl] -> Var
nameToVar name env decls =
    case type_ of
        PrimType BooleanT                       -> fromString(symbol ++ ":bool")
        PrimType ShortT                         -> fromString(symbol ++ ":int")
        PrimType IntT                           -> fromString(symbol ++ ":int")
        PrimType LongT                          -> fromString(symbol ++ ":int")
        PrimType FloatT                         -> fromString(symbol ++ ":real")
        PrimType DoubleT                        -> fromString(symbol ++ ":real")
        RefType (ArrayType (PrimType ShortT))   -> fromString(symbol ++ ":[int]")
        RefType (ArrayType (PrimType IntT))     -> fromString(symbol ++ ":[int]")
        RefType (ArrayType (PrimType LongT))    -> fromString(symbol ++ ":[int]")
        RefType (ArrayType (PrimType FloatT))   -> fromString(symbol ++ ":[real]")
        RefType (ArrayType (PrimType DoubleT))  -> fromString(symbol ++ ":[real]")
        _ -> error $ "Unsupported type: " ++ prettyPrint type_ ++ " " ++ prettyPrint name
    where
      (type_, symbol) = (lookupType decls env name, prettyPrint name)

javaExpToLExprAlgebra :: ExpAlgebra (TypeEnv -> [TypeDecl] -> LExpr)
javaExpToLExprAlgebra =
  (fLit, fClassLit, fThis, fThisClass, fInstanceCreation, fQualInstanceCreation,
   fArrayCreate, fArrayCreateInit, fFieldAccess, fMethodInv, fArrayAccess, fExpName,
   fPostIncrement, fPostDecrement, fPreIncrement, fPreDecrement, fPrePlus, fPreMinus,
   fPreBitCompl, fPreNot, fCast, fBinOp, fInstanceOf, fCond, fAssign, fLambda, fMethodRef)
  where
    fLit lit _ _ =
      case lit of
        Boolean t -> b t
        Int i     -> n $ fromInteger i
        Float i   -> r i
        Double i  -> r i
        Null      -> "null"
        _         -> error $ "Unsupported type: " ++ show lit
    fClassLit = error "fClassLit not supported..."
    fThis = error "fThis not supported..."
    fThisClass = error "fThisClass not supported..."
    fInstanceCreation = error "fInstanceCreation not supported..."
    fQualInstanceCreation = error "fQualInstanceCreation not supported..."
    fArrayCreate = error "fArrayCreate not supported..."
    fArrayCreateInit = error "fArrayCreateInit not supported..."
    fFieldAccess = undefined {-case fieldAccess of -- TODO: implement field accesses
                        PrimaryFieldAccess e id         -> case e of
                                                                InstanceCreation _ t args _ -> undefined
                                                                _ -> undefined
                        SuperFieldAccess id             -> mkStringSymbol (prettyPrint (Name [id])) >>= mkIntVar
                        ClassFieldAccess (Name name) id -> mkStringSymbol (prettyPrint (Name (name ++ [id]))) >>= mkIntVar -}
    fMethodInv inv env decls =
      case inv of -- TODO: very hardcoded EDSL + lambdas cannot be { return expr; } + ranged
        -- Java: imp(exp1, exp2);
        MethodCall (Name [Ident "imp"]) [exp1, exp2]
            -> refold exp1 .==> refold exp2
        -- Java: with(exp1, bound -> exp2);
        MethodCall (Name [Ident "with"]) [exp1, Lambda (LambdaSingleParam bound) (LambdaExpression exp2)]
            -> (LVar (nameToVar (Name [bound]) env decls) .== refold exp1) .==> refold exp2
        -- Java: method(name, bound -> expr);
        MethodCall (Name [Ident method]) [ExpName name, Lambda (LambdaSingleParam (Ident bound)) (LambdaExpression expr)]
            -> quant method name bound expr
        -- Java: method(name, bound -> { return expr; });
        MethodCall (Name [Ident method]) [ExpName name, Lambda (LambdaSingleParam (Ident bound)) (LambdaBlock (Block [BlockStmt (Return (Just expr))]))]
            -> quant method name bound expr
        -- Java: method(name, rbegin, rend, bound -> expr);
        MethodCall (Name [Ident method]) [ExpName name, rbegin, rend, Lambda (LambdaSingleParam (Ident bound)) (LambdaExpression expr)]
            -> quantr method name rbegin rend bound expr
        -- Java: method(name, rbegin, rend, bound -> { return expr; });
        MethodCall (Name [Ident method]) [ExpName name, rbegin, rend, Lambda (LambdaSingleParam (Ident bound)) (LambdaBlock (Block [BlockStmt (Return (Just expr))]))]
            -> quantr method name rbegin rend bound expr
        _
            -> error $ "Unimplemented fMethodInv: " ++ prettyPrint inv
        where quant method name bound expr =
                let i = Var (TPrim PInt) bound
                    (zero, len) = (LConst (CInt 0), LLen (nameToVar name env decls))
                in case method of
                          "forall" -> lquantr QAll i zero len expr
                          "exists" -> lquantr QAny i zero len expr
                          _ -> error $ "Unimplemented fMethodInv: " ++ prettyPrint inv
              quantr method name rbegin rend bound expr =
                let (begin, end) = (refold rbegin, refold rend)
                    (i, _) = (Var (TPrim PInt) bound, nameToVar name env decls)
                in case method of
                          "forallr" -> lquantr QAll i begin end expr
                          "existsr" -> lquantr QAny i begin end expr
                          _ -> error $ "Unimplemented fMethodInv: " ++ prettyPrint inv
              lquantr op i begin end expr =
                LQuant op i (LBinop (v i .>= begin) LAnd (LBinop (LVar i) CLess end)) (refold expr)
              refold expr =
                foldExp javaExpToLExprAlgebra expr env decls
    fArrayAccess arrayIndex env decls =
      case arrayIndex of
        ArrayIndex (ExpName name) [expr]
          -> LArray (nameToVar name env decls) (javaExpToLExpr expr env decls)
        _
          -> error $ "Multidimensional arrays are not supported: " ++ prettyPrint arrayIndex
    fExpName name env decls =
      case name of
        Name [Ident a, Ident "length"] -> LLen $ nameToVar (Name [Ident a]) env decls
        _ -> LVar $ nameToVar name env decls
    fPostIncrement = error "fPostIncrement has side effects..."
    fPostDecrement = error "fPostDecrement has side effects..."
    fPreIncrement = error "fPreIncrement has side effects..."
    fPreDecrement = error "fPreDecrement has side effects..."
    fPrePlus e = e
    fPreMinus e env decls = LUnop NNeg (e env decls)
    fPreBitCompl _ _ _ = error "Bitwise operations not supported..."
    fPreNot e env decls = LUnop LNot (e env decls)
    fCast = error "fCast is not supported..." -- TODO: perhaps support cast for some types?
    fBinOp e1 op e2 env decls = -- TODO: type checking?
      e1 env decls `bop` e2 env decls
      where
        bop =
          case op of
            -- Integer
            Mult    -> (.*)
            Div     -> (./)
            Rem     -> (.%)
            Add     -> (.+)
            Sub     -> (.-)
            RRShift -> undefined
            -- Logical
            CAnd    -> (.&&)
            COr     -> (.||)
            -- Comparisons
            LThan   -> (.<)
            GThan   -> (.>)
            LThanE  -> (.<=)
            GThanE  -> (.>=)
            Equal   -> (.==)
            NotEq   -> (.!=)
            _       -> error $ "Unsupported operation: " ++ prettyPrint op
    fInstanceOf = error "fInstanceOf is not supported..."
    fCond c a b_ env decls = LIf (c env decls) (a env decls) (b_ env decls)
    fAssign = error "fAssign has side effects..."
    fLambda = error "fLambda should be handled by fMethodInv..."
    fMethodRef = undefined
