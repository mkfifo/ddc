
-- | Parser for Source Tetra modules.
module DDC.Source.Tetra.Parser.Module
        ( -- * Modules
          pModule
        , pTypeSig
        
          -- * Top-level things
        , pTop)
where
import DDC.Source.Tetra.Parser.Exp
import DDC.Source.Tetra.Compounds
import DDC.Source.Tetra.DataDef
import DDC.Source.Tetra.Module
import DDC.Source.Tetra.Prim
import DDC.Source.Tetra.Exp.Annot
import DDC.Core.Lexer.Tokens
import DDC.Base.Pretty
import Control.Monad
import qualified DDC.Type.Exp           as T
import qualified DDC.Base.Parser        as P
import DDC.Base.Parser                  ((<?>))

import DDC.Core.Parser
        ( Parser
        , Context       (..)
        , pModuleName
        , pName
        , pVar
        , pTok,         pTokSP)

type SP = P.SourcePos


-- Module -----------------------------------------------------------------------------------------
-- | Parse a source tetra module.
pModule :: Context Name -> Parser Name (Module (Annot SP))
pModule c
 = do   
        _sp     <- pTokSP KModule
        name    <- pModuleName <?> "a module name"

        -- export { VAR;+ }
        tExports 
         <- P.choice
            [do pTok KExport
                pTok KBraceBra
                vars    <- P.sepEndBy1 pVar (pTok KSemiColon)
                pTok KBraceKet
                return vars

            ,   return []]

        -- import { SIG;+ }
        tImports
         <- liftM concat $ P.many (pImportSpecs c)

        -- top-level declarations.
        tops    
         <- P.choice
            [do pTok KWhere
                pTok KBraceBra

                -- TOP;+
                tops    <- P.sepEndBy (pTop c) (pTok KSemiColon)

                pTok KBraceKet
                return tops

            ,do return [] ]


        -- ISSUE #295: Check for duplicate exported names in module parser.
        --  The names are added to a unique map, so later ones with the same
        --  name will replace earlier ones.
        return  $ Module
                { moduleName            = name
                , moduleExportTypes     = []
                , moduleExportValues    = tExports
                , moduleImportModules   = [mn     | ImportModule mn  <- tImports]
                , moduleImportTypes     = [(n, s) | ImportType  n s  <- tImports]
                , moduleImportCaps      = [(n, s) | ImportCap   n s  <- tImports]
                , moduleImportValues    = [(n, s) | ImportValue n s  <- tImports]
                , moduleTops            = tops }


-- | Parse a type signature.
pTypeSig :: Context Name -> Parser Name (Name, T.Type Name)
pTypeSig c
 = do   var     <- pVar
        pTokSP (KOp ":")
        t       <- pType c
        return  (var, t)


---------------------------------------------------------------------------------------------------
-- | An imported foreign type or foreign value.
data ImportSpec n
        = ImportModule  ModuleName
        | ImportType    n (ImportType  n (T.Type n))
        | ImportCap     n (ImportCap   n (T.Type n))
        | ImportValue   n (ImportValue n (T.Type n))
        deriving Show
        

-- | Parse some import specs.
pImportSpecs :: Context Name -> Parser Name [ImportSpec Name]
pImportSpecs c
 = do   pTok KImport

        P.choice
                -- import foreign ...
         [ do   pTok KForeign
                src    <- liftM (renderIndent . ppr) pName

                P.choice
                 [      -- import foreign X type (NAME :: TYPE)+ 
                  do    pTok KType
                        pTok KBraceBra

                        sigs <- P.sepEndBy1 (pImportType c src) (pTok KSemiColon)
                        pTok KBraceKet
                        return sigs

                        -- import foreign X capability (NAME :: TYPE)+
                 , do   pTok KCapability
                        pTok KBraceBra

                        sigs <- P.sepEndBy1 (pImportCapability c src) (pTok KSemiColon)
                        pTok KBraceKet
                        return sigs

                        -- import foreign X value (NAME :: TYPE)+
                 , do   pTok KValue
                        pTok KBraceBra

                        sigs <- P.sepEndBy1 (pImportValue c src) (pTok KSemiColon)
                        pTok KBraceKet
                        return sigs
                 ]

         , do   pTok KBraceBra
                names   <- P.sepEndBy1 pModuleName (pTok KSemiColon) 
                                <?> "module names"
                pTok KBraceKet
                return  [ImportModule n | n <- names]
         ]


-- | Parse a type import spec.
pImportType :: Context Name -> String -> Parser Name (ImportSpec Name)
pImportType c src
        | "abstract"    <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                k       <- pType c
                return  (ImportType n (ImportTypeAbstract k))

        | "boxed"        <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                k       <- pType c
                return  (ImportType n (ImportTypeBoxed k))

        | otherwise
        = P.unexpected "import mode for foreign type"


-- | Parse a capability import.
pImportCapability :: Context Name -> String -> Parser Name (ImportSpec Name)
pImportCapability c src
        | "abstract"    <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                t       <- pType c
                return  (ImportCap n (ImportCapAbstract t))

        | otherwise
        = P.unexpected "import mode for foreign capability"


-- | Parse a value import spec.
pImportValue :: Context Name -> String -> Parser Name (ImportSpec Name)
pImportValue c src
        | "c"           <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                k       <- pType c

                -- ISSUE #327: Allow external symbol to be specified 
                --             with foreign C imports and exports.
                let symbol = renderIndent (ppr n)

                return  (ImportValue n (ImportValueSea symbol k))

        | otherwise
        = P.unexpected "import mode for foreign value"


-- Top Level --------------------------------------------------------------------------------------
pTop    :: Context Name -> Parser Name (Top (Annot SP))
pTop c
 = P.choice
 [ do   -- A top-level, possibly recursive binding.
        (l, sp)         <- pClauseSP c
        return  $ TopClause sp l
 
        -- A data type declaration
 , do   pData c
 ]


-- Data -------------------------------------------------------------------------------------------
-- | Parse a data type declaration.
pData   :: Context Name -> Parser Name (Top (Annot SP))
pData c
 = do   sp      <- pTokSP KData
        n       <- pName
        ps      <- liftM concat $ P.many (pDataParam c)
             
        P.choice
         [ -- Data declaration with constructors that have explicit types.
           do   pTok KWhere
                pTok KBraceBra
                ctors   <- P.sepEndBy1 (pDataCtor c) (pTok KSemiColon)
                pTok KBraceKet
                return  $ TopData sp (DataDef n ps ctors)
         
           -- Data declaration with no data constructors.
         , do   return  $ TopData sp (DataDef n ps [])
         ]


-- | Parse a type parameter to a data type.
pDataParam :: Context Name -> Parser Name [Bind]
pDataParam c 
 = do   pTok KRoundBra
        ns      <- P.many1 pName
        pTokSP (KOp ":")
        k       <- pType c
        pTok KRoundKet
        return  [T.BName n k | n <- ns]


-- | Parse a data constructor declaration.
pDataCtor :: Context Name -> Parser Name (DataCtor Name)
pDataCtor c
 = do   n       <- pName
        pTokSP (KOp ":")
        t       <- pType c
        let (tsArg, tResult)    
                = takeTFunArgResult t

        return  $ DataCtor
                { dataCtorName          = n
                , dataCtorFieldTypes    = tsArg
                , dataCtorResultType    = tResult }

