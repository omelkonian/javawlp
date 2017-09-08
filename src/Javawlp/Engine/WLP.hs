-- Copyright (c) 2017 Utrecht University
-- Author: Koen Wermer

-- Implementing the wlp transformer.
module Javawlp.Engine.WLP where

import Language.Java.Syntax
import Language.Java.Lexer
import Language.Java.Parser
import Language.Java.Pretty
import Data.Maybe
import Data.List
import Debug.Trace

import Javawlp.Engine.Folds
import Javawlp.Engine.Verifier
import Javawlp.Engine.Substitute
import Javawlp.Engine.HelperFunctions

data WLPConf = WLPConf {
      -- the max. number of times a loop/recursion is unrolled
      nrOfUnroll :: Int,
      -- When ignoreLibMethods is true, library calls will simply be ignored (treated as skip). 
      -- When false, we consider library methods but make no assumptions about them (so the WLP will be true)
      ignoreLibMethods :: Bool,
      ignoreMainMethod :: Bool
   }    
   
-- | The name used to represent the return value of the top-method.   
returnVarName = "returnValue"
-- | The name used to represent the "this" target object in the top-method.
targetObjName = "targetObj_"

-- | A type for the inherited attribute
data Inh = Inh {wlpConfig :: WLPConf,               -- Some configuration parameters for the wlp
                acc     :: Exp -> Exp,              -- The accumulated transformer of the current block up until the current statement
                br      :: Exp -> Exp,              -- The accumulated transformer up until the last loop (this is used when handling break statements etc.)
                -- Wish: adding this attribute to handle "continue" commands:
                cont    :: Exp -> Exp,              -- The accumulated transformer to handle the "continue" jump
                catch   :: [ExceptionTable],        -- the hierarchy of catch-finalize blocks to jump, with the first one in the list being the immediate handlers to look up
                env     :: TypeEnv,                 -- The type environment for typing expressions
                decls   :: [TypeDecl],              -- Class declarations
                reccalls :: CallCount,              -- The number of recursive calls per method
                ret     :: Maybe Ident,             -- The name of the return variable when handling a method call
                object  :: Maybe Exp                -- The object the method is called from when handling a method call
                }
            
-- | Representing the handler + finalize sections of a try-catch-block.            
data ExceptionTable = ExceptionTable 
                         [Catch]        -- the handlers
                         (Maybe Block)  -- the finalize code, if any
                         (Exp -> Exp)   -- the continuation post-wlp, which is to composed after the whole try-catch block

 

         
           
-- | A type synonym for the synthesized attributea
type Syn = Exp -> Exp -- The wlp transformer

-- | The algebra that defines the wlp transformer for statements
--   The synthesized attribute is the resulting transformer. 
--   Statements that pass control to the next statement have to explicitly combine their wlp function with the accumulated function, as some statements (e.g. break) ignore the accumulated function.
wlpStmtAlgebra :: StmtAlgebra (Inh -> Syn)
wlpStmtAlgebra = (fStmtBlock, fIfThen, fIfThenElse, fWhile, fBasicFor, fEnhancedFor, fEmpty, fExpStmt, fAssert, fSwitch, fDo, fBreak, fContinue, fReturn, fSynchronized, fThrow, fTry, fLabeled) where
    
    -- The result of the last block-statement will be the accumulated transformer for the second-last etc. 
    -- The type environment is build from the left, so it has to be done seperately.
    fStmtBlock (Block bs) inh       = foldr (\b r -> wlpBlock inh{acc = r} b) (acc inh) bs 
    
    fIfThen e s1                    = fIfThenElse e s1 acc -- if-then is just an if-then-else with an empty else-block
    fIfThenElse e s1 s2 inh         = let (e', trans) = foldExp wlpExpAlgebra e inh{acc = id}
                                          var = getVar
                                      in trans . substVar' inh var e' . (\q -> (ExpName (Name [var]) &* s1 inh q) |* (neg (ExpName (Name [var])) &* s2 inh q))

    fWhile e s inh                  = let (e', trans) = foldExp wlpExpAlgebra e inh{acc = id}
                                          var = getVar
                                          numberOfUnrolling = nrOfUnroll $ wlpConfig $ inh
                                      -- Wish: this seems to be wrong:
                                      -- in (\q -> unrollLoopOpt inh{br = const q} numberOfUnrolling e' trans s q)
                                      -- Fixing:
                                      in (\q -> unrollLoopOpt inh{br = (\q'-> acc inh q)} numberOfUnrolling e' trans s q)
                                      
    fBasicFor init me incr s inh    = let 
                                      -- encode the for loop as a while-loop
                                      -- loop below is the wlp-transformer over the loop without the initialization part:
                                      loop = fWhile (fromMaybeGuard me)  -- the guard
                                                    -- constructing s ; incr. 
                                                    -- However, this looks to be wrong:
                                                    -- (\inh' -> s (inh'{acc = wlp' inh'{acc = id} (incrToStmt incr)}) ) 
                                                    -- Fixing to:
                                                    (\inh' -> s (inh'{acc = wlp' inh' (incrToStmt incr)}) )                              
                                                    inh 
                                      in 
                                      wlp' inh{acc = loop} (initToStmt init)
                                      
    fEnhancedFor                    = error "EnhancedFor"
    fEmpty inh                      = (acc inh) -- Empty does nothing, but still passes control to the next statement
    fExpStmt e inh                  = snd $ foldExp wlpExpAlgebra e inh
    fAssert e _ inh                 = let (e', trans) = foldExp wlpExpAlgebra e inh {acc = id}
                                      in (trans . (e' &*) . acc inh)
    fSwitch e bs inh                = let (e', s1, s2) = desugarSwitch e bs in fIfThenElse e' (flip wlp' s1) (flip wlp' s2) (inh {acc = id, br = acc inh})
    
    fDo s e inh                     = -- Do is just a while with the statement block executed one additional time. 
                                      -- Break and continue still have to be handled in this additional execution.
                                      let
                                      whileTransf = fWhile e s inh
                                      in
                                      s (inh {acc = whileTransf, br = acc inh, cont = whileTransf }) 
    
    fBreak _ inh                    = br inh -- wlp of the breakpoint. Control is passed to the statement after the loop
    
    -- Wish: his seems to be wrong
    -- fContinue _ inh                 = id     -- at a continue statement it's as if the body of the loop is fully executed
    -- Fixing to:
    fContinue _ inh                 = cont inh  
        
    fReturn me inh                  = case me of
                                        Nothing -> id -- Return ignores acc, as it terminates the method
                                        Just e  -> fExpStmt (Assign (NameLhs (Name [fromJust' "fReturn" (ret inh)])) EqualA e) (inh {acc = id}) -- We treat "return e" as an assignment to a variable specifically created to store the return value in
                                                            
    fSynchronized _                 = fStmtBlock
    
    fThrow e inh                    = case catch inh of
        
                                        [] -> {- we have no more handlers, so the exception escape -} (\q -> q &* throwException e)
                                        
                                        (ExceptionTable cs f postTransf : therest) ->
                                           case getCatch (decls inh) (env inh) e cs of
                                              -- no matching handler is found in the immediate exception-table;
                                              -- search higher up:
                                              Nothing -> 
                                                  let rethrowTransf = fThrow e inh{catch = therest} 
                                                  in 
                                                  -- we will first do the finally section, then rethrow the exception before passing
                                                  -- up to the higher level handlers
                                                  case f of
                                                     Nothing        -> rethrowTransf
                                                     Just finalizer -> -- trace ("\n ## invoking finalizer on MISmatch " ++ show finalizer) $
                                                                        fStmtBlock finalizer inh{acc=rethrowTransf,catch=therest}
                                              
                                              -- a matching handler is found; handle it, compose with finalizer if there is one:
                                              Just handler ->
                                                   let
                                                   finalizeTransf = case f of
                                                       Nothing        -> postTransf
                                                       Just finalizer -> -- trace "\n ## invoking finalizer on match " $ 
                                                                         fStmtBlock finalizer inh{acc=postTransf,catch=therest}
                                                   in
                                                   fStmtBlock handler inh{acc=finalizeTransf,catch=therest}
        
    fTry (Block bs) cs f inh        = let     
                                        excTable = ExceptionTable cs f (acc inh)    
                                        normalfinalyTranf = case f of
                                            Nothing -> acc inh
                                            Just b  -> fStmtBlock b inh       
                                        in 
                                        fStmtBlock (Block bs) inh{acc=normalfinalyTranf, catch = excTable : catch inh}                   
                                      
    fLabeled _ s                    = s
    
    -- Helper functions
    
    -- A block also keeps track of the types of declared variables
    wlpBlock :: Inh -> BlockStmt -> Syn
    wlpBlock inh b  = case b of
                        BlockStmt s            -> wlp' inh s
                        LocalClass _           -> (acc inh)
                        LocalVars mods t vars  -> foldr (\v r -> wlpDeclAssignment t (inh{acc = r}) v) (acc inh) vars
                
    -- wlp of a var declaration that also assigns a value. Declaring without assignment assigns the default value
    wlpDeclAssignment :: Type -> Inh -> VarDecl -> Exp -> Exp
    wlpDeclAssignment t inh (VarDecl (VarId ident) Nothing) = case t of 
                                                                PrimType _ -> substVar (env inh) (decls inh) (NameLhs (Name [ident])) (getInitValue t) . acc inh
                                                                -- We don't initialize ref types to null, because we want to keep pointer information
                                                                RefType _ -> acc inh 
    wlpDeclAssignment t inh (VarDecl (VarId ident) (Just (InitExp e)))  = snd (foldExp wlpExpAlgebra (Assign (NameLhs (Name [ident])) EqualA e) inh)
    wlpDeclAssignment _ _ _ = error "ArrayCreateInit is not supported"
              
    -- Unrolls a while-loop a finite amount of times
    unrollLoop :: Inh -> Int -> Exp -> (Exp -> Exp) -> (Inh -> Exp -> Exp) -> Exp -> Exp
    unrollLoop inh 0 g gTrans _             = let var = getVar
                                              -- in gTrans . substVar' inh var g . (neg (ExpName (Name [var])) `imp`) . acc inh
                                              in gTrans . substVar' inh var g . (neg (ExpName (Name [var])) &*) . acc inh
    unrollLoop inh n g gTrans bodyTrans     = let 
                                              var = getVar
                                              nextUnrollingTrans = unrollLoop inh (n-1) g gTrans bodyTrans
                                              in gTrans 
                                                 . substVar' inh var g 
                                                 . (\q -> (neg (ExpName (Name [var])) &* acc inh q) 
                                                          |* 
                                                          ((ExpName (Name [var])) &* bodyTrans inh{acc = nextUnrollingTrans, cont = nextUnrollingTrans} q))
    
    -- An optimized version of unroll loop to reduce the size of the wlp
    unrollLoopOpt :: Inh -> Int -> Exp -> (Exp -> Exp) -> (Inh -> Exp -> Exp) -> Exp -> Exp
    unrollLoopOpt inh n g gTrans bodyTrans q 
           | gTrans (bodyTrans inh q) == acc inh q  = acc inh q                              -- q is not affected by the loop
           | otherwise                              = unrollLoop inh n g gTrans bodyTrans q  -- default to the standard version of unroll loop
    
    -- Converts initialization code of a for loop to a statement
    initToStmt :: Maybe ForInit -> Stmt
    initToStmt Nothing                              = Empty
    initToStmt (Just (ForInitExps es))              = StmtBlock (Block (map (BlockStmt . ExpStmt) es))
    initToStmt (Just (ForLocalVars mods t vars))    = StmtBlock (Block [LocalVars mods t vars])
    
    -- Replaces an absent guard with "True"
    fromMaybeGuard :: Maybe Exp -> Exp
    fromMaybeGuard Nothing  = true
    fromMaybeGuard (Just e) = e
    
    -- Converts increment code of a for loop to a statement
    incrToStmt :: Maybe [Exp] -> Stmt
    incrToStmt Nothing   = Empty
    incrToStmt (Just es) = StmtBlock (Block (map (BlockStmt . ExpStmt) es))
    
    -- Converts a switch into nested if-then-else statements. The switch is assumed to be non-trivial.
    desugarSwitch :: Exp -> [SwitchBlock] -> (Exp, Stmt, Stmt)
    desugarSwitch e [SwitchBlock l bs]          = case l of
                                                    SwitchCase e'   -> (BinOp e Equal e', StmtBlock (Block (addBreak bs)), Break Nothing)
                                                    Default         -> (true, StmtBlock (Block (addBreak bs)), Empty)
        where addBreak bs = bs ++ [BlockStmt (Break Nothing)] -- Adds an explicit break statement add the end of a block (used for the final block)
    desugarSwitch e sbs@(SwitchBlock l bs:sbs') = case l of
                                                    SwitchCase e'   -> (BinOp e Equal e', StmtBlock (switchBlockToBlock sbs), otherCases)
                                                    Default         -> (true, StmtBlock (switchBlockToBlock sbs), otherCases)
        where otherCases  = let (e', s1, s2) = desugarSwitch e sbs' in IfThenElse e' s1 s2
        
    -- Gets the statements from a switch statement
    switchBlockToBlock :: [SwitchBlock] -> Block
    switchBlockToBlock []                       = Block []
    switchBlockToBlock (SwitchBlock l bs:sbs)   = case switchBlockToBlock sbs of
                                                    Block b -> Block (bs ++ b)
        
throwException :: Exp -> Exp
throwException e = false
    
getCatch :: [TypeDecl] -> TypeEnv -> Exp -> [Catch] -> Maybe Block
getCatch decls env e []             = Nothing
getCatch decls env e (Catch p b:cs) = if catches decls env p e then Just b else getCatch decls env e cs

-- Checks whether a catch block catches a certain error
catches :: [TypeDecl] -> TypeEnv -> FormalParam -> Exp -> Bool
catches decls env (FormalParam _ t _ _) e = t == RefType (ClassRefType (ClassType [(Ident "Exception", [])])) || 
                                              case e of
                                                ExpName name -> lookupType decls env name == t
                                                InstanceCreation _ t' _ _ -> t == RefType (ClassRefType t')
                                             
    
-- | The algebra that defines the wlp transformer for expressions with side effects
--   The first attribute is the expression itself (this is passed to handle substitutions in case of assignments)
wlpExpAlgebra :: ExpAlgebra (Inh -> (Exp, Syn))
wlpExpAlgebra = (fLit, fClassLit, fThis, fThisClass, fInstanceCreation, fQualInstanceCreation, fArrayCreate, fArrayCreateInit, fFieldAccess, fMethodInv, fArrayAccess, fExpName, fPostIncrement, fPostDecrement, fPreIncrement, fPreDecrement, fPrePlus, fPreMinus, fPreBitCompl, fPreNot, fCast, fBinOp, fInstanceOf, fCond, fAssign, fLambda, fMethodRef) where
    fLit lit inh                                        = (Lit lit, (acc inh))
    fClassLit mType inh                                 = (ClassLit mType, (acc inh))
    fThis inh                                           = (fromJust' "fThis" (object inh), acc inh)
    fThisClass name inh                                 = (ThisClass name, (acc inh))
    fInstanceCreation typeArgs t args mBody inh         = case args of
                                                            [ExpName (Name [Ident "#"])]    -> (InstanceCreation typeArgs t args mBody, acc inh) -- '#' indicates we already called the constructor method using the correct arguments
                                                            _                               -> -- Create a var, assign a new instance to var, then call the constructor method on var
                                                                    let varId = getReturnVar invocation
                                                                        var = Name [varId]
                                                                        invocation = MethodCall (Name [varId, Ident ("#" ++ getClassName t)]) args
                                                                    in  (ExpName var, (substVar (env inh) (decls inh) (NameLhs var) (InstanceCreation typeArgs t [ExpName (Name [Ident "#"])] mBody) . snd ((fMethodInv invocation) inh {acc = id}) . acc inh))
    fQualInstanceCreation e typeArgs t args mBody inh   = error "fQualInstanceCreation"
    fArrayCreate t dimLengths dim inh                   = (ArrayCreate t (map (\e -> fst (e inh)) dimLengths) dim, acc inh)
    fArrayCreateInit t dim init inh                     = error "ArrayCreateInit" -- (ArrayCreateInit t dim init, acc inh)
    fFieldAccess fieldAccess inh                        = (foldFieldAccess inh fieldAccess, (acc inh))
    fMethodInv invocation inh                           = let
                                                          varId = getReturnVar invocation
                                                          result_ = ExpName (Name [varId])
                                                          numberOfUnrolling = nrOfUnroll $ wlpConfig inh
                                                          in
                                                          case invocation of
                                                            -- *assume is a meta-function, handle this first:
                                                            MethodCall (Name [Ident "*assume"]) [e] -> (result_, (if e == false then const true else imp e)) 
                                                            
                                                            _  ->  if isLibraryMethod inh invocation 
                                                                   -- library method, so we can't unroll:
                                                                   then   if ignoreLibMethods $ wlpConfig $ inh
                                                                          then (result_, acc inh)     -- we are to ignore lib-functions, so it behaves as a skip
                                                                          else (result_, const true)  -- treat lib-function as a miracle
                                                                   -- not a library method, unroll:
                                                                   else   if getCallCount (reccalls inh) (invocationToId invocation) >= numberOfUnrolling  
                                                                          then {- Recursion limit is reached! Force to avoid analyzing this execution path -} (result_ , const false) 
                                                                          else let 
                                                                               inh'  = inh {acc = id, 
                                                                                            reccalls = incrCallCount (reccalls inh) (invocationToId invocation), 
                                                                                            ret = Just varId, 
                                                                                            object = getObject inh invocation} 
                                                                               callWlp = wlp' inh' (inlineMethod inh invocation)
                                                                          in (result_ , (callWlp . acc inh))
                                                        
    fArrayAccess (ArrayIndex a i) inh                   = let (a', atrans) = foldExp wlpExpAlgebra a inh {acc = id}
                                                              i' = map (flip (foldExp wlpExpAlgebra) inh {acc = id}) i
                                                          in (arrayAccess a' (map fst i'), foldl (.) atrans (map snd i') . arrayAccessWlp a' (map fst i') inh)
    
    fExpName name inh                                   = (editName inh name, acc inh)
    -- x++ increments x but evaluates to the original value
    fPostIncrement e inh                                = let (e', trans) = e inh in 
                                                          case e' of
                                                            -- Wish: this is incorrect
                                                            -- var@(ExpName name) -> (var, substVar (env inh) (decls inh) (NameLhs name) (BinOp var Add (Lit (Int 1))) . trans)
                                                            -- fix:
                                                            var@(ExpName name) -> (BinOp var Sub (Lit (Int 1)), substVar (env inh) (decls inh) (NameLhs name) (BinOp var Add (Lit (Int 1))) . trans)
                                                            exp  -> (exp, trans)
    fPostDecrement e inh                                = let (e', trans) = e inh in
                                                          case e' of
                                                            -- incorrect
                                                            -- var@(ExpName name) -> (var, substVar (env inh) (decls inh) (NameLhs name) (BinOp var Sub (Lit (Int 1))) . trans)
                                                            var@(ExpName name) -> (BinOp var Add (Lit (Int 1)), substVar (env inh) (decls inh) (NameLhs name) (BinOp var Sub (Lit (Int 1))) . trans)
                                                            exp  -> (exp, trans)
    -- ++x increments x and evaluates to the new value of x
    fPreIncrement e inh                                 = let (e', trans) = e inh in 
                                                          case e' of
                                                            -- Wish: this is incorrect
                                                            -- var@(ExpName name) -> (BinOp var Add (Lit (Int 1)), substVar (env inh) (decls inh) (NameLhs name) (BinOp var Add (Lit (Int 1))) . trans)
                                                            -- fix:
                                                            var@(ExpName name) -> (var, substVar (env inh) (decls inh) (NameLhs name) (BinOp var Add (Lit (Int 1))) . trans)
                                                            exp  -> (BinOp exp Add (Lit (Int 1)), trans)
    fPreDecrement e inh                                 = let (e', trans) = e inh in 
                                                          case e' of
                                                            -- incorrect
                                                            -- var@(ExpName name) -> (BinOp var Sub (Lit (Int 1)), substVar (env inh) (decls inh) (NameLhs name) (BinOp var Sub (Lit (Int 1))) . trans)
                                                            var@(ExpName name) -> (var, substVar (env inh) (decls inh) (NameLhs name) (BinOp var Sub (Lit (Int 1))) . trans)
                                                            exp  -> (BinOp exp Sub (Lit (Int 1)), trans)
    fPrePlus e inh                                      = let (e', trans) = e inh in (e', trans)
    fPreMinus e inh                                     = let (e', trans) = e inh in (PreMinus e', trans)
    fPreBitCompl e inh                                  = let (e', trans) = e inh in (PreBitCompl e', trans)
    fPreNot e inh                                       = let (e', trans) = e inh in (PreNot e', trans)
    fCast t e inh                                       = let (e', trans) = e inh in (e', trans)
    fBinOp e1 op e2 inh                                 = let (e1', trans1) = e1 inh {acc = id}
                                                              (e2', trans2) = e2 inh {acc = id}
                                                              [var1, var2] = getVars 2
                                                          in (BinOp (ExpName (Name [var1])) op (ExpName (Name [var2])), trans1 . substVar' inh var1 e1' . trans2 . substVar' inh var2 e2' . acc inh) -- Side effects of the first expression are applied before the second is evaluated
    fInstanceOf                                         = error "instanceOf"
    fCond g e1 e2 inh                                   = let (e1', trans1) = e1 inh {acc = id}
                                                              (e2', trans2) = e2 inh {acc = id}
                                                              (g', transg)  = g inh {acc = id}
                                                          in (Cond g' e1' e2', (transg . (\q -> (g' &* trans1 q) |* (neg g' &* trans2 q)) . acc inh))
    fAssign lhs op e inh                                = let (lhs', lhsTrans) = foldLhs inh {acc = id} lhs
                                                              rhs' = desugarAssign lhs' op e'
                                                              (e', trans) = e inh {acc = id}
                                                          in  (rhs', lhsTrans . trans . substVar (env inh) (decls inh) lhs' rhs' . acc inh)
    fLambda                                             = error "lambda"
    fMethodRef                                          = error "method reference"
                            
    -- gets the transformer for array access (as array access may throw an error)
    arrayAccessWlp :: Exp -> [Exp] -> Inh -> Exp -> Exp
    arrayAccessWlp a i inh q =  
        let
        accessConstraint = (foldr (\(i, l) e -> e &* (BinOp i LThan l) &* (BinOp i GThanE (Lit (Int 0)))) true (zip i (dimLengths a)))
        arrayException   = InstanceCreation [] (ClassType [(Ident "ArrayIndexOutOfBoundsException", [])]) [] Nothing
        in
        case catch inh of
          [] -> {- no handler, then impose the constraint -} accessConstraint &* acc inh q
          _  -> (accessConstraint &* acc inh q) |* wlp' inh (Throw arrayException) q
                                
    dimLengths a = case a of
                    ArrayCreate t exps dim          -> exps
                    _                               -> map (\n -> MethodInv (MethodCall (Name [Ident "*length"]) [a, (Lit (Int n))])) [0..]
                    
    -- Edits a name expression to handle build-in constructs
    editName :: Inh -> Name -> Exp
    editName inh (Name name) | last name == Ident "length" = case lookupType (decls inh) (env inh) (Name (take (length name - 1) name)) of -- For arrays we know that "length" refers to the length of the array
                                                                RefType (ArrayType _) -> MethodInv (MethodCall (Name [Ident "*length"]) [ExpName (Name (take (length name - 1) name)), (Lit (Int 0))])

                                                                _ -> ExpName (Name name)
                             | otherwise = ExpName (Name name)
                    
    isLibraryMethod :: Inh -> MethodInvocation -> Bool
    isLibraryMethod inh (MethodCall name _)  = getMethod (decls inh) (getMethodId name) == Nothing
    isLibraryMethod inh (PrimaryMethodCall _ _ id _) = getMethod (decls inh) id == Nothing
                   
    -- Inlines a methodcall. Only non-library method should be inlined!
    -- This creates a variable to store the return value in
    inlineMethod :: Inh -> MethodInvocation -> Stmt
    inlineMethod inh invocation = StmtBlock (Block (getParams inh invocation ++ [BlockStmt (getBody inh invocation)])) where
        -- Gets the body of the method
        getBody :: Inh -> MethodInvocation -> Stmt
        getBody inh invocation = fromJust $ getMethod (decls inh) (invocationToId invocation)
        
        -- Assigns the supplied parameter values to the parameter variables
        getParams :: Inh -> MethodInvocation -> [BlockStmt]
        getParams inh (MethodCall name args)            = case getMethodParams (decls inh) (getMethodId name) of 
                                                            Nothing     -> []
                                                            Just params -> zipWith assignParam params args
        getParams inh (PrimaryMethodCall _ _ id args)   = case getMethodParams (decls inh) id of 
                                                            Nothing     -> []
                                                            Just params -> zipWith assignParam params args
        getParams inh _ = undefined
        -- Creates an assignment statement to a parameter variable
        assignParam :: FormalParam -> Exp -> BlockStmt
        assignParam (FormalParam mods t _ varId) e = LocalVars mods t [VarDecl varId (Just (InitExp e))]
    
    -- Gets the object a method is called from
    getObject :: Inh -> MethodInvocation -> Maybe Exp
    getObject inh (MethodCall name _)   | length (fromName name) > 1    = Just (ExpName (Name (take (length (fromName name) - 1) (fromName name))))
                                    | otherwise                         = Nothing
    getObject inh (PrimaryMethodCall e _ _ _)                           = case e of
                                                                            This -> object inh
                                                                            _    -> Just e
    getObject inh _                                                     = undefined
    
    -- Gets the name of the class as a string from the type
    getClassName :: ClassType -> String
    getClassName (ClassType xs) = let Ident s = fst (last xs) in s
    
    -- Gets the return type of a method
    getType :: Inh -> MethodInvocation -> Maybe Type
    getType inh invocation = getMethodType (decls inh) (invocationToId invocation)
    
    -- Folds the expression part of an lhs
    foldLhs :: Inh -> Lhs -> (Lhs, Syn)
    foldLhs inh lhs  = case lhs of
                            FieldLhs (PrimaryFieldAccess e id)  -> case foldExp wlpExpAlgebra e inh of
                                                                    (ExpName name, trans)   -> (NameLhs (Name (fromName name ++ [id])), trans)
                                                                    _                       -> error "foldLhs"
                            ArrayLhs (ArrayIndex a i)           ->  let (a', aTrans) = foldExp wlpExpAlgebra a inh
                                                                        i' = map (\x -> foldExp wlpExpAlgebra x inh) i
                                                                    in (ArrayLhs (ArrayIndex a' (map fst i')), foldl (\trans (_, iTrans) -> trans . iTrans) aTrans i' . arrayAccessWlp a' (map fst i') inh)
                            lhs'                                -> (lhs', id)
    
    -- Folds the expression part of a fieldaccess and simplifies it
    foldFieldAccess :: Inh -> FieldAccess -> Exp
    foldFieldAccess inh fieldAccess  = case fieldAccess of
                                            PrimaryFieldAccess e id     -> case fst (foldExp wlpExpAlgebra e inh) of
                                                                                ExpName name    -> ExpName (Name (fromName name ++ [id]))
                                                                                ArrayAccess (ArrayIndex a i) -> let (a', aTrans) = foldExp wlpExpAlgebra a inh
                                                                                                                    i' = map (\x -> foldExp wlpExpAlgebra x inh) i
                                                                                                                in MethodInv (MethodCall (Name [Ident "*length"]) [a, (Lit (Int (toEnum (length i'))))])
                                                                                x               -> error ("foldFieldAccess: " ++ show x ++ " . " ++ show id)
                                            SuperFieldAccess id         -> foldFieldAccess inh (PrimaryFieldAccess (fromJust' "foldFieldAccess" (object inh)) id)
                                            ClassFieldAccess name id    -> ExpName (Name (fromName name ++ [id]))
    
    
-- Simplified version of substVar, handy to use with introduced variables
substVar' :: Inh -> Ident -> Exp -> Syn
substVar' inh var e = substVar (env inh) (decls inh) (NameLhs (Name [var])) e

-- | Calculates the weakest liberal pre-condition of a statement and a given post-condition
wlp :: WLPConf -> [TypeDecl] -> Stmt -> Exp -> Exp
wlp config decls = wlpWithEnv config decls []

-- | wlp with a given type environment
wlpWithEnv :: WLPConf -> [TypeDecl] -> TypeEnv -> Stmt -> Exp -> Exp
wlpWithEnv config decls env = wlp' (Inh config id id id [] env decls [] (Just (Ident returnVarName)) (Just (ExpName (Name [Ident targetObjName]))))

-- wlp' lets you specify the inherited attributes
wlp' :: Inh -> Stmt -> Syn
wlp' inh s = foldStmt wlpStmtAlgebra s inh
