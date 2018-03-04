{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Model where

import Data.List (isSuffixOf)
import qualified Data.Map as M
import Data.String
import GHC.Generics
import Text.Parsec hiding (runP)
import Text.Parsec.Language
import Text.Parsec.String
import qualified Text.Parsec.Token as Tokens

import LogicIR.ParserUtils

-- | Response type.
data Response = Equivalent | NotEquivalent Model | ErrorResponse String | Undefined | Timeout
                deriving (Eq)

(<>) :: Response -> Response -> Response
ErrorResponse e <> _ = ErrorResponse e
_ <> ErrorResponse e = ErrorResponse e
Equivalent <> r = r
NotEquivalent s <> _ = NotEquivalent s
Timeout <> _ = Timeout
Undefined <> _ = Undefined

instance Show Response where
  show Equivalent = "Formulas are equivalent"
  show (NotEquivalent model) = "Not equivalent: " ++ show model
  show (ErrorResponse e) = "*** Error: " ++ show e
  show Undefined = "Oops... could not determine if formulas are equivalent"
  show Timeout = "Timeout occured"


-- | Model type.
data ModelVal = BoolVal Bool
              | IntVal Integer
              | RealVal Double
              | ManyVal [ModelVal]
              deriving (Eq, Generic)

type Model = M.Map String ModelVal

emptyModel :: Model
emptyModel = M.empty

-- | Pretty-printing.
instance Show ModelVal where
  show (BoolVal b)  = show b
  show (IntVal i)   = show i
  show (RealVal i)  = show i
  show (ManyVal vs) = show vs

-- | Crop arrays until their specified length.
sanitize :: Model -> Model
sanitize model =
  M.filterWithKey isNotLen $ M.filterWithKey isNotNull $ M.mapWithKey f model
  where f k (ManyVal array) = ManyVal $ take (counts k) array
        f _ x               = x
        counts k = fromInteger $
          case model M.! (k ++ "?length") of
            (IntVal i) -> i
            _          -> error "non-int length"
        isNotNull k _ =
          ((k ++ "?null") `M.notMember` model) ||
          case model M.! (k ++ "?null") of
            (BoolVal b) -> not b
            _           -> error "non-bool null"
        isNotLen k _ = not $ "?length" `isSuffixOf` k

-- | Parsers.
modelP :: Parser ModelVal
modelP = try (BoolVal <$> boolP)
     <|> try (RealVal <$> realP)
     <|> (IntVal <$> intP)

realP :: Parser Double
realP =  try negRealP <|> try divRealP <|> Tokens.float haskell
  where divRealP = do
          v <- "(/" ~> realP
          v' <- realP <~ ")"
          return $ v / v'
        negRealP = do
          v <- "(-" ~> realP <~ ")"
          return $ -v

intP :: Parser Integer
intP = try negIntP <|> Tokens.integer haskell
  where negIntP = do v <- "(-" ~> intP <~ ")"
                     return $ -v

indexP :: Parser Integer
indexP = Tokens.natural haskell

boolP :: Parser Bool
boolP = (True <$ str "true") <|> (False <$ str "false")

-- | Implicit conversion from strings.
instance IsString ModelVal where
  fromString = runP modelP