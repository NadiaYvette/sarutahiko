{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module: Fluent.Polytropos.TH
-- Description: Template Haskell deriveFluentCatalog for compile-time SumRow synthesis
--
-- Derives closed @polytropos@ 'SumRow' types from Project Fluent (@.ftl@) resource
-- files, guaranteeing at compile time that every referenced message and its typed
-- parameters exist in the catalog.
module Fluent.Polytropos.TH
  ( deriveFluentCatalog
  ) where

import Data.Char (toLower)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Fluent.Polytropos.Schema
  ( CatalogSchema (..)
  , MessageSchema (..)
  , ParamType (..)
  , extractInlineTags
  , parseParamAnnotations
  )
import Language.Haskell.TH
  ( Body (..)
  , Dec (..)
  , Exp (..)
  , Lit (..)
  , Pat (..)
  , Q
  , TyLit (..)
  , Type (..)
  , mkName
  , runIO
  )
import Language.Haskell.TH.Syntax (addDependentFile)
import Polytropos.Core (Pair (..))

-- | Derives a type synonym representing a closed @polytropos@ 'SumRow'
-- for the given catalog file, plus a metadata witness value.
deriveFluentCatalog :: String -> FilePath -> Q [Dec]
deriveFluentCatalog typeNameStr path = do
  addDependentFile path
  rawContent <- runIO (TIO.readFile path)
  let schema = parseFtlCatalog "en" rawContent
  let typeName = mkName typeNameStr
  let schemaWitnessName = mkName (toLowerFirst typeNameStr ++ "CatalogSchema")

  -- Generate type <TypeName> = '[ "msg1" ':= '[ "var" ':= Type, ... ], ... ]
  let rowType = buildCatalogSumRow (csMessages schema)
  let typeSynDec = TySynD typeName [] rowType

  -- Generate witness value <name>CatalogSchema :: CatalogSchema
  let witnessDec = ValD (VarP schemaWitnessName) (NormalB (reifyCatalogExp schema)) []

  pure [typeSynDec, witnessDec]
  where
    toLowerFirst [] = []
    toLowerFirst (c : cs) = toLower c : cs

buildCatalogSumRow :: Map.Map Text MessageSchema -> Type
buildCatalogSumRow msgs = foldr consRow PromotedNilT (Map.toList msgs)
  where
    consRow (msgId, mSchema) rest =
      let msgSymbol = LitT (StrTyLit (T.unpack msgId))
          paramsRow = buildParamsRow (msParams mSchema)
          pairTy = AppT (AppT (PromotedT '(:=)) msgSymbol) paramsRow
      in AppT (AppT PromotedConsT pairTy) rest

buildParamsRow :: Map.Map Text ParamType -> Type
buildParamsRow params = foldr consParam PromotedNilT (Map.toList params)
  where
    consParam (pName, pType) rest =
      let pSymbol = LitT (StrTyLit (T.unpack pName))
          pValTy = paramTypeToHaskell pType
          pairTy = AppT (AppT (PromotedT '(:=)) pSymbol) pValTy
      in AppT (AppT PromotedConsT pairTy) rest

paramTypeToHaskell :: ParamType -> Type
paramTypeToHaskell ParamText        = ConT (mkName "Data.Text.Text")
paramTypeToHaskell ParamVerbatim    = ConT (mkName "Data.Text.Text")
paramTypeToHaskell ParamNumber      = ConT (mkName "Prelude.Int")
paramTypeToHaskell ParamDateTime    = ConT (mkName "Data.Time.UTCTime")
paramTypeToHaskell (ParamCustom ty) = ConT (mkName (T.unpack ty))

-- | Very minimal pure FTL line parser for catalog schemas.
parseFtlCatalog :: Text -> Text -> CatalogSchema
parseFtlCatalog loc raw =
  let linesOf = T.lines raw
      (msgs, _) = foldl step (Map.empty, []) linesOf
  in CatalogSchema loc msgs mempty
  where
    step (acc, commentBuf) line
      | "#" `T.isPrefixOf` T.stripStart line =
          (acc, commentBuf ++ [line])
      | "=" `T.isInfixOf` line && not ("-" `T.isPrefixOf` T.stripStart line) =
          let (keyPart, valPart) = T.breakOn "=" line
              msgId = T.strip keyPart
              val = T.strip (T.drop 1 valPart)
              params = parseParamAnnotations commentBuf
              tags = extractInlineTags val
              mSchema = MessageSchema msgId params tags mempty
          in if not (T.null msgId)
               then (Map.insert msgId mSchema acc, [])
               else (acc, [])
      | otherwise = (acc, commentBuf)

reifyCatalogExp :: CatalogSchema -> Exp
reifyCatalogExp (CatalogSchema loc _ _) =
  AppE (VarE (mkName "Fluent.Polytropos.Schema.mkEmptyCatalog"))
    (AppE (VarE (mkName "Data.Text.pack")) (LitE (StringL (T.unpack loc))))
