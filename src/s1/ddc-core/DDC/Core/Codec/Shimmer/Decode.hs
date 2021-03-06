
module DDC.Core.Codec.Shimmer.Decode
        ( Config (..)
        , decodeInterface
        , takeModuleDecls
        , takeTyCon)
where
import DDC.Data.Label
import qualified DDC.Core.Interface.Store       as C
import qualified DDC.Core.Module                as C
import qualified DDC.Core.Exp                   as C
import qualified DDC.Type.Exp.Simple.Compounds  as C
import qualified DDC.Core.Exp.Annot.Compounds   as C
import qualified DDC.Type.DataDef               as C
import qualified DDC.Type.Sum                   as Sum

import qualified SMR.Core.Exp                   as S
import qualified SMR.Prim.Name                  as S
import qualified SMR.Core.Codec                 as S

import Data.Time.Clock
import Data.IORef
import Data.Maybe
import Data.Text                                (Text)
import Data.Map                                 (Map)
import Data.Set                                 (Set)
import qualified Data.Text                      as T
import qualified System.IO.Unsafe               as System
import qualified Data.Map.Strict                as Map
import qualified Data.Set                       as Set
import qualified Data.ByteString                as BS
import Prelude hiding (read)

---------------------------------------------------------------------------------------------------
type SExp  = S.Exp  Text S.Prim
type SDecl = S.Decl Text S.Prim


-- | Config holding functions to extract various sorts of names from the tree.
data Config n
        = Config
        { configTakeRef         :: SExp -> Maybe n }

fromRef c ss
 = case configTakeRef c ss of
    Just r  -> r
    Nothing -> error "fromRef failed"


-- Interface --------------------------------------------------------------------------------------
decodeInterface
        :: (Show n, Ord n)
        => Config n             -- ^ Decode configuration.
        -> FilePath             -- ^ Path of interace file, for error messages.
        -> UTCTime              -- ^ Timestamp of interface file.
        -> BS.ByteString        -- ^ Interface file contents.
        -> Maybe (C.Interface n)

decodeInterface config filePath timeStamp bs
 | Just mm <- takeModuleDecls config $ S.unpackFileDecls bs
 = Just $ C.Interface
        { C.interfaceFilePath   = filePath
        , C.interfaceTimeStamp  = timeStamp
        , C.interfaceVersion    = "version"
        , C.interfaceModuleName = C.moduleName mm
        , C.interfaceModule     = mm }

 | otherwise
 = Nothing


-- Module -----------------------------------------------------------------------------------------
takeModuleDecls :: (Ord n, Show n) => Config n -> [SDecl] -> Maybe (C.Module () n)
takeModuleDecls c decls
 = let  col = collectModuleDecls decls

        Just mn
         = case colName col of
                [S.DeclSet _ ssModuleName]
                        -> Just $ fromModuleName ssModuleName
                _       -> Nothing

        mpT     = Map.fromList [(tx, ss) | S.DeclMac tx ss <- colDsT col]
        mpD     = Map.fromList [(tx, ss) | S.DeclMac tx ss <- colDsD col]
        mpS     = Map.fromList [(tx, ss) | S.DeclMac tx ss <- colDsS col]

   in   Just $ C.ModuleCore
         { C.moduleName            = mn
         , C.moduleIsHeader        = False
         , C.moduleTransitiveDeps  = Set.unions $ map (takeDeclDeps c) $ colDeps  col
         , C.moduleExportTypes     = concatMap (takeDeclExTyp c)     $ colExTyp col
         , C.moduleExportValues    = concatMap (takeDeclExVal c mpT) $ colExVal col
         , C.moduleImportModules   = concatMap (takeDeclImMod c)     $ colImMod col
         , C.moduleImportTypes     = concatMap (takeDeclImTyp c)     $ colImTyp col
         , C.moduleImportDataDefs  = concatMap (takeDeclDat   c mpD) $ colImDat col
         , C.moduleImportTypeDefs  = concatMap (takeDeclSyn   c mpS) $ colImSyn col
         , C.moduleImportCaps      = concatMap (takeDeclImCap c)     $ colImCap col
         , C.moduleImportValues    = concatMap (takeDeclImVal c mpT) $ colImVal col
         , C.moduleLocalDataDefs   = concatMap (takeDeclDat   c mpD) $ colLcDat col
         , C.moduleLocalTypeDefs   = concatMap (takeDeclSyn   c mpS) $ colLcSyn col
         , C.moduleBody            = C.xUnit () }


-- Collect ----------------------------------------------------------------------------------------
-- | Collect the different top level declarations into separate bins
--   for each type of module.
---
--   We do this via IORefs because we're a bit worried about the cost of
--   reallocating the Collect wrapper for every declaration.
--   The resulting code is still clunky, and we probably want a better module representation.
--
collectModuleDecls :: [SDecl] -> Collect
collectModuleDecls decls
 = System.unsafePerformIO
 $ do   let new  = newIORef []
        let read = readIORef
        let rev  = reverse

        refName  <- new; refDeps  <- new;
        refExTyp <- new; refExVal <- new;
        refImMod <- new; refImTyp <- new; refImDat <- new;
        refImSyn <- new; refImCap <- new; refImVal <- new
        refLcDat <- new; refLcSyn <- new
        refD     <- new; refS     <- new; refT     <- new; refX     <- new

        let eat (d@(S.DeclSet tx _ss) : ds)
             | T.isPrefixOf "m-name"   tx = do { modifyIORef' refName  (d :); eat ds }
             | T.isPrefixOf "m-deps"   tx = do { modifyIORef' refDeps  (d :); eat ds }
             | T.isPrefixOf "m-ex-typ" tx = do { modifyIORef' refExTyp (d :); eat ds }
             | T.isPrefixOf "m-ex-val" tx = do { modifyIORef' refExVal (d :); eat ds }
             | T.isPrefixOf "m-im-mod" tx = do { modifyIORef' refImMod (d :); eat ds }
             | T.isPrefixOf "m-im-typ" tx = do { modifyIORef' refImTyp (d :); eat ds }
             | T.isPrefixOf "m-im-dat" tx = do { modifyIORef' refImDat (d :); eat ds }
             | T.isPrefixOf "m-im-syn" tx = do { modifyIORef' refImSyn (d :); eat ds }
             | T.isPrefixOf "m-im-cap" tx = do { modifyIORef' refImCap (d :); eat ds }
             | T.isPrefixOf "m-im-val" tx = do { modifyIORef' refImVal (d :); eat ds }
             | T.isPrefixOf "m-lc-dat" tx = do { modifyIORef' refLcDat (d :); eat ds }
             | T.isPrefixOf "m-lc-syn" tx = do { modifyIORef' refLcSyn (d :); eat ds }
             | otherwise                  = error "ddc-core.collectModuleDecls: unexpected decl"

            eat (d@(S.DeclMac tx _ss) : ds)
             | T.isPrefixOf "d-"       tx = do { modifyIORef' refD     (d :); eat ds }
             | T.isPrefixOf "s-"       tx = do { modifyIORef' refS     (d :); eat ds }
             | T.isPrefixOf "t-"       tx = do { modifyIORef' refT     (d :); eat ds }
             | T.isPrefixOf "x-"       tx = do { modifyIORef' refX     (d :); eat ds }
             | otherwise                  = error "ddc-core.collectModuleDecls: unexpected decl"

            eat []                        = return ()

        eat decls

        dsName  <- read refName
        dsDeps  <- read refDeps
        dsExTyp <- read refExTyp; dsExVal <- read refExVal
        dsImMod <- read refImMod; dsImTyp <- read refImTyp; dsImDat <- read refImDat
        dsImSyn <- read refImSyn; dsImCap <- read refImCap; dsImVal <- read refImVal
        dsLcDat <- read refLcDat; dsLcSym <- read refLcSyn
        dsD     <- read refD;     dsS     <- read refS;     dsT     <- read refT
        dsX     <- read refX

        return  $ Collect
                { colName  = rev dsName,  colDeps  = rev dsDeps
                , colExTyp = rev dsExTyp, colExVal = rev dsExVal
                , colImMod = rev dsImMod, colImTyp = rev dsImTyp, colImDat = rev dsImDat
                , colImSyn = rev dsImSyn, colImCap = rev dsImCap, colImVal = rev dsImVal
                , colLcDat = rev dsLcDat, colLcSyn = rev dsLcSym
                , colDsD   = rev dsD,     colDsS   = rev dsS,     colDsT   = rev dsT
                , colDsX   = rev dsX }

data Collect
        = Collect
        { colName  :: [SDecl], colDeps  :: [SDecl]
        , colExTyp :: [SDecl], colExVal :: [SDecl]
        , colImMod :: [SDecl], colImTyp :: [SDecl], colImDat :: [SDecl]
        , colImSyn :: [SDecl], colImCap :: [SDecl], colImVal :: [SDecl]
        , colLcDat :: [SDecl], colLcSyn :: [SDecl]
        , colDsD   :: [SDecl], colDsS   :: [SDecl], colDsT   :: [SDecl], colDsX :: [SDecl] }


-- ModuleName -------------------------------------------------------------------------------------
fromModuleName :: SExp -> C.ModuleName
fromModuleName ss
 = case ss of
        XAps "module-name" ssParts
          |  Just txs     <- sequence $ map takeXTxt ssParts
          -> C.ModuleName $ map T.unpack txs
        _ -> failDecode "takeModuleName"


-- DeclExTyp --------------------------------------------------------------------------------------
takeDeclDeps  :: Config n -> SDecl -> Set C.ModuleName
takeDeclDeps _ dd
 = case dd of
        S.DeclSet "m-deps" ssListNames
          -> Set.fromList $ map fromModuleName $ fromList ssListNames
        _ -> failDecode "takeDeclDeps"


-- DeclExTyp --------------------------------------------------------------------------------------
takeDeclExTyp :: Ord n => Config n -> SDecl -> [(n, C.ExportType n (C.Type n))]
takeDeclExTyp c dd
 = case dd of
        S.DeclSet "m-ex-typ" ssListExTyp
          -> map takeExTyp $ fromList ssListExTyp
        _ -> failDecode "takeDeclExTyp"

 where
        takeExTyp (XAps "ex-typ" [ssName, ssKind])
         = let  nType = fromRef  c ssName
                tKind = fromType c ssKind
           in   (nType, C.ExportTypeLocal nType tKind)

        takeExTyp _ = failDecode "takeExTyp"


-- DeclExVal --------------------------------------------------------------------------------------
takeDeclExVal
        :: Ord n
        => Config n -> Map Text SExp
        -> SDecl -> [(n, C.ExportValue n (C.Type n))]

takeDeclExVal c mpT dd
 = case dd of
        S.DeclSet "m-ex-val" ssListExTrm
          -> map takeExVal $ fromList ssListExTrm
        _ -> failDecode "takeDeclExVal"

 where
        takeExVal (XAps "ex-val-loc"
                        [ ssModuleName, ssName
                        , XMac txMacTyp, XMac _txMacTrm])
         = let nName = fromRef c ssName
           in case Map.lookup txMacTyp mpT of
                Nothing     -> failDecode $ "takeDeclExVal missing declaration " ++ show txMacTyp
                Just ssType
                 -> (nName, C.ExportValueLocal
                        { C.exportValueLocalModuleName = fromModuleName ssModuleName
                        , C.exportValueLocalName       = nName
                        , C.exportValueLocalType       = fromType c ssType
                        , C.exportValueLocalArity      = Nothing })

        takeExVal (XAps "ex-val-loc"
                        [ ssModuleName, ssName
                        , XMac txMacTyp, XMac _txMacTrm
                        , XNat nT, XNat nX, XNat nB ])
         = let nName = fromRef c ssName
           in case Map.lookup txMacTyp mpT of
                Nothing     -> failDecode $ "takeDeclExVal missing declaration " ++ show txMacTyp
                Just ssType
                 -> (nName, C.ExportValueLocal
                        { C.exportValueLocalModuleName  = fromModuleName ssModuleName
                        , C.exportValueLocalName        = nName
                        , C.exportValueLocalType        = fromType c ssType
                        , C.exportValueLocalArity       = Just (fromI nT, fromI nX, fromI nB) })

        takeExVal (XAps "ex-val-sea"
                        [ssModuleName, ssNameInternal, XTxt txNameExternal, ssType])
         = let nInternal = fromRef c ssNameInternal
           in  (nInternal,  C.ExportValueSea
                        { C.exportValueSeaModuleName    = fromModuleName ssModuleName
                        , C.exportValueSeaNameInternal  = nInternal
                        , C.exportValueSeaNameExternal  = txNameExternal
                        , C.exportValueSeaType          = fromType c ssType })

        takeExVal _ = failDecode $ "takeExVal" ++ show dd


-- DeclImMod --------------------------------------------------------------------------------------
takeDeclImMod :: Ord n => Config n -> SDecl -> [C.ModuleName]
takeDeclImMod _c dd
 = case dd of
        S.DeclSet "m-im-mod" ssListImMod
          -> map takeImMod $ fromList ssListImMod
        _ -> failDecode "takeDeclImMod failed"
 where
        takeImMod ss    = fromModuleName ss


-- DeclImTyp --------------------------------------------------------------------------------------
takeDeclImTyp :: Ord n => Config n -> SDecl -> [(n, C.ImportType n (C.Type n))]
takeDeclImTyp c dd
 = case dd of
        S.DeclSet "m-im-typ" ssListImTyp
          -> map takeImTyp $ fromList ssListImTyp
        _ -> failDecode "takeDeclImTyp failed"

 where  takeImTyp (XAps "im-typ-abs" [ssName, ssKind])
         = let nType = fromRef  c ssName
               tKind = fromType c ssKind
           in  (nType, C.ImportTypeAbstract tKind)

        takeImTyp (XAps "im-typ-box" [ssName, ssKind])
         = let nType = fromRef  c ssName
               tKind = fromType c ssKind
           in  (nType, C.ImportTypeBoxed tKind)

        takeImTyp _ = failDecode "takeTyp failed"


-- DeclSyn ----------------------------------------------------------------------------------------
takeDeclSyn
        :: Ord n
        => Config n -> Map Text SExp
        -> SDecl -> [(n, (C.Kind n, C.Type n))]

takeDeclSyn c mpS dd
 = case dd of
        S.DeclSet "m-im-syn" ssListTypSyn
          -> map takeTypSyn $ fromList ssListTypSyn

        S.DeclSet "m-lc-syn" ssListTypSyn
          -> map takeTypSyn $ fromList ssListTypSyn

        _ -> failDecode "takeDeclSyn failed"

 where  takeTypSyn (XAps "typ-syn" [ssType, XMac txMacSyn])
         = let nType = fromRef c ssType
           in  case Map.lookup txMacSyn mpS of
                Nothing        -> failDecode $ "takeDeclSyn missing declaration " ++ show txMacSyn
                Just ssTypeSyn -> takeSynonym nType ssTypeSyn

        takeTypSyn _    = failDecode "takeTypSyn failed"

        takeSynonym nType (XAps "s-syn"  [ssKind, ssType])
         = (nType, (fromType c ssKind, fromType c ssType))

        takeSynonym _ _ = failDecode "takeSynonym failed"


-- DeclDat ----------------------------------------------------------------------------------------
takeDeclDat
        :: Ord n
        => Config n -> Map Text SExp
        -> SDecl -> [(n, C.DataDef n)]

takeDeclDat c mpD dd
 = case dd of
        S.DeclSet "m-im-dat" ssListTypDat
          -> map takeTypDat $ fromList ssListTypDat

        S.DeclSet "m-lc-dat" ssListTypDat
          -> map takeTypDat $ fromList ssListTypDat

        _ -> failDecode "takeDeclDat failed"

 where  takeTypDat  (XAps "typ-dat" [_modName, XTxt _nCon, XMac txMacDat])
         | Just ssDataDef <- Map.lookup txMacDat mpD
         = takeDataDef ssDataDef

        takeTypDat _ = failDecode "takeTypDat failed"

        takeDataDef (XAps "d-alg"   [ssModuleName, ssCon, ssListParam, XNone])
         | nType <- fromRef c ssCon
         = (nType, C.DataDef
                { C.dataDefModuleName   = fromModuleName ssModuleName
                , C.dataDefTypeName     = nType
                , C.dataDefParams       = map (fromBind c)  $ fromList ssListParam
                , C.dataDefCtors        = Nothing
                , C.dataDefIsAlgebraic  = True })

        takeDataDef (XAps "d-alg"   [ssModuleName, ssType, ssListParam, XSome ssCtors])
         | nType    <- fromRef c ssType
         , bsParam  <- map (fromBind c)  $ fromList ssListParam
         = (nType, C.DataDef
                { C.dataDefModuleName   = fromModuleName ssModuleName
                , C.dataDefTypeName     = nType
                , C.dataDefParams       = bsParam
                , C.dataDefCtors        = Just $ map (takeDataCtor nType bsParam) $ fromList ssCtors
                , C.dataDefIsAlgebraic  = True })

        takeDataDef _ = failDecode $ "takeDataDef failed"

        takeDataCtor nType bsParam (XAps "ctor"  (XNat nTag : ssModuleName : ssCtorName : ssRest))
         | (ssField, ssResult)  <- splitLast ssRest
         = C.DataCtor
            { C.dataCtorModuleName  = fromModuleName ssModuleName
            , C.dataCtorName        = fromRef c ssCtorName
            , C.dataCtorTag         = nTag
            , C.dataCtorFieldTypes  = map (fromType c) ssField
            , C.dataCtorResultType  = fromType c ssResult
            , C.dataCtorTypeName    = nType
            , C.dataCtorTypeParams  = bsParam }

        takeDataCtor _ _ _ = failDecode "takeDataCtor failed"


-- DeclImCap --------------------------------------------------------------------------------------
takeDeclImCap
        :: Ord n
        => Config n
        -> SDecl -> [(n, C.ImportCap n (C.Type n))]

takeDeclImCap c dd
 = case dd of
        S.DeclSet "m-im-cap" ssListImCap
          -> map takeImCap $ fromList ssListImCap
        _ -> failDecode "takeDeclCap failed"

 where  takeImCap (XAps "im-cap-abs" [ssVar, ssType])
         = (fromRef c ssVar, C.ImportCapAbstract $ fromType c ssType)
        takeImCap _ = failDecode "takeImCap failed"


-- DeclImVal --------------------------------------------------------------------------------------
takeDeclImVal
        :: Ord n
        => Config n
        -> Map Text SExp
        -> SDecl -> [(n, C.ImportValue n (C.Type n))]

takeDeclImVal c mpT dd
 = case dd of
        S.DeclSet "m-im-val" ssListImVal
          -> map takeImVal $ fromList ssListImVal
        _ -> failDecode "takeDeclVal failed"

 where  takeImVal (XAps "im-val-mod"
                        [ssModuleName, ssVar, XMac txMacType, XNat nT, XNat nX, XNat nB])
         | Just n      <- configTakeRef c (ssVar :: SExp)
         , Just ssType <- Map.lookup txMacType mpT
         = (n, C.ImportValueModule
                { C.importValueModuleName       = fromModuleName ssModuleName
                , C.importValueModuleVar        = n
                , C.importValueModuleType       = fromType c ssType
                , C.importValueModuleArity      = Just (fromI nT, fromI nX, fromI nB) })

        takeImVal (XAps "im-val-sea"
                        [ssModuleName, ssNameInternal, XTxt txNameExternal, XMac txMacType])
         | Just ssType  <- Map.lookup txMacType mpT
         , Just n       <- configTakeRef c ssNameInternal
         = (n, C.ImportValueSea
                { C.importValueSeaModuleName    = fromModuleName ssModuleName
                , C.importValueSeaNameInternal  = n
                , C.importValueSeaNameExternal  = txNameExternal
                , C.importValueSeaType          = fromType c ssType })

        takeImVal _
         = failDecode "takeImVal failed"


-- Type -------------------------------------------------------------------------------------------
fromType :: Ord n => Config n -> SExp -> C.Type n
fromType c ss
 = case ss of
        -- Applications of function type constructors.
        XAps "tf" ssParamResult
         -> let (ssParam, ssResult) = splitLast ssParamResult
                Just tf = takeTypeFun c ssParam (fromType c ssResult)
            in  tf

        -- Applications of a data type constructor.
        -- TODO: elim intermediate Bound
        XAps "tu" (ssBound : ssArgs)
         -> let C.UName n = fromBound c ssBound
            in  C.tApps (C.TCon $ C.TyConBound n)
                        (map (fromType c) ssArgs)

        -- Abstraction.
        XAps "tb" [ssBind, ssBody]
         -> C.TAbs (fromBind c ssBind) (fromType c ssBody)

        -- Application
        XAps "ta" ssArgs
         -> let (t1 : ts) = map (fromType c) ssArgs
            in  C.tApps t1 ts

        -- Forall
        XAps "tl" [ssBind, ssBody]
         -> C.TForall (fromBind c ssBind) (fromType c ssBody)

        -- Sum
        XAps "ts" (ssKind : ssArgs)
         -> C.TSum $ Sum.fromList (fromType c ssKind)
                   $ map (fromType c) ssArgs

        -- Row
        XAps "tr" ssElems
         -> C.TRow $ map (fromTypeRowElem c) ssElems

          -- Con
        _ |  Just tc    <- takeTyCon c ss
          -> C.TCon tc

          -- Bound
          |  Just u     <- takeBound c ss
          -> C.TVar u

          | otherwise   -> failDecode "fromType failed"


fromTypeRowElem :: Ord n => Config n -> SExp -> (Label, C.Type n)
fromTypeRowElem c ss
 = case ss of
        XAps "p" [ssLabel, ssType]
         -> (fromLabel ssLabel, fromType c ssType)

        _ -> failDecode "fromTypeRowElem failed"


fromLabel :: SExp -> Label
fromLabel ss
 = case ss of
        XTxt tx -> labelOfText tx
        _       -> failDecode "fromLabel failed"



takeTypeFun :: Ord n => Config n -> [SExp] -> C.Type n -> Maybe (C.Type n)
takeTypeFun c ssParam tResult
 = case ssParam of
        []      -> Just tResult

        -- Implicit function parameter.
        XAps "ni" [ssType] : ssParamRest
         |  Just tRest  <- takeTypeFun c ssParamRest tResult
         -> Just $ C.tApps (C.TCon $ C.TyConSpec C.TcConFunImplicit)
                        [fromType c ssType, tRest]

        -- Some other function constructor.
        XAps "nn" [ssTyCon, ssType] : ssParamRest
         |  Just tcFun  <- takeTyCon   c ssTyCon
         ,  Just tRest  <- takeTypeFun c ssParamRest tResult
         -> Just $ C.tApps (C.TCon tcFun) [fromType c ssType, tRest]

        -- Explicit function parameter.
        ssType : ssParamRest
         |  Just tRest  <- takeTypeFun c ssParamRest tResult
         -> Just $ C.tApps (C.TCon $ C.TyConSpec C.TcConFunExplicit)
                        [fromType c ssType, tRest]

        _ -> Nothing


-- Bind -------------------------------------------------------------------------------------------
fromBind :: Ord n => Config n -> SExp -> C.Bind n
fromBind c ss
 = fromMaybe (failDecode "fromBind failed")
 $ takeBind c ss

takeBind :: Ord n => Config n -> SExp -> Maybe (C.Bind n)
takeBind c ss
 = case ss of
        XAps "bo" [ssType]
         -> Just $ C.BNone $ fromType c ssType

        XAps "ba" [ssType]
         -> Just $ C.BAnon $ fromType c ssType

        XAps "bn" [ssRef, ssType]
         |  Just n      <- configTakeRef c ssRef
         -> Just $ C.BName n $ fromType c ssType

        _ -> Nothing


-- Bound ------------------------------------------------------------------------------------------
fromBound :: Ord n => Config n -> SExp -> C.Bound n
fromBound c ss
 = fromMaybe (failDecode "fromBound failed")
 $ takeBound c ss

takeBound :: Ord n => Config n -> SExp -> Maybe (C.Bound n)
takeBound c ss
 = case ss of
        XNat n  -> Just $ C.UIx $ fromIntegral n
        _       -> fmap C.UName $ configTakeRef c ss


-- TyCon ------------------------------------------------------------------------------------------
takeTyCon :: Ord n => Config n -> SExp -> Maybe (C.TyCon n)
takeTyCon c ss
 = case ss of

        -- TyConBound
        XApp (XSym "tcb") [ssBound]
         | Just (C.UName n) <- takeBound c ssBound
         -> Just $ C.TyConBound n

        -- TyConExists
        XApp (XSym "tcy") [XNat n, ssType]
         -> Just $ C.TyConExists (fromIntegral n) $ fromType c ssType

        -- TyConSort
        XSym "ts-prop"          -> Just $ C.TyConSort   C.SoConProp
        XSym "ts-comp"          -> Just $ C.TyConSort   C.SoConComp

        -- TyConKind
        XSym "tk-arr"           -> Just $ C.TyConKind   C.KiConFun
        XSym "tk-witness"       -> Just $ C.TyConKind   C.KiConWitness
        XSym "tk-data"          -> Just $ C.TyConKind   C.KiConData
        XSym "tk-region"        -> Just $ C.TyConKind   C.KiConRegion
        XSym "tk-effect"        -> Just $ C.TyConKind   C.KiConEffect
        XSym "tk-closure"       -> Just $ C.TyConKind   C.KiConClosure
        XSym "tk-row"           -> Just $ C.TyConKind   C.KiConRow

        -- TyConWitness
        XSym "tw-impl"          -> Just $ C.TyConWitness C.TwConImpl
        XSym "tw-pure"          -> Just $ C.TyConWitness C.TwConPure
        XSym "tw-const"         -> Just $ C.TyConWitness C.TwConConst
        XSym "tw-mutable"       -> Just $ C.TyConWitness C.TwConMutable
        XApp (XSym "tw-distinct") [XNat n]
                                -> Just $ C.TyConWitness $ C.TwConDistinct $ fromIntegral n
        XSym "tw-disjoint"      -> Just $ C.TyConWitness $ C.TwConDisjoint

        -- TyConSpec
        XSym "tc-unit"          -> Just $ C.TyConSpec   C.TcConUnit
        XSym "tc-fun"           -> Just $ C.TyConSpec   C.TcConFunExplicit
        XSym "tc-funi"          -> Just $ C.TyConSpec   C.TcConFunImplicit
        XSym "tc-susp"          -> Just $ C.TyConSpec   C.TcConSusp

        XApp (XSym "tc-record") sfs
         | Just ts <- sequence $ map takeXSym sfs
         -> Just $ C.TyConSpec $ C.TcConRecord ts

        XSym "tc-t"             -> Just $ C.TyConSpec   C.TcConT
        XSym "tc-r"             -> Just $ C.TyConSpec   C.TcConR
        XSym "tc-v"             -> Just $ C.TyConSpec   C.TcConV

        XSym "tc-read"          -> Just $ C.TyConSpec   C.TcConRead
        XSym "tc-write"         -> Just $ C.TyConSpec   C.TcConWrite
        XSym "tc-alloc"         -> Just $ C.TyConSpec   C.TcConAlloc

        -- Soz.
        _                       -> Nothing


-- Utils ------------------------------------------------------------------------------------------
takeXSym :: SExp -> Maybe Text
takeXSym (XSym tx) = Just tx
takeXSym _         = Nothing

takeXTxt :: SExp -> Maybe Text
takeXTxt (XTxt tx) = Just tx
takeXTxt _         = Nothing

pattern XNone           = S.XRef (S.RSym "n")
pattern XSome x         = S.XApp (S.XRef (S.RSym "s")) [x]
pattern XNat n          = S.XRef (S.RPrm (S.PrimLitNat n))

pattern XApp x1 xs      = S.XApp x1 xs
pattern XAps tx xs      = S.XApp (S.XRef (S.RSym tx)) xs
pattern XSym tx         = S.XRef (S.RSym tx)
pattern XMac tx         = S.XRef (S.RMac tx)
pattern XTxt tx         = S.XRef (S.RTxt tx)

splitLast :: [a] -> ([a], a)
splitLast xx
 = go [] xx
 where  go _   []       = failDecode "splitLast failed"
        go acc [x]      = (reverse acc, x)
        go acc (x : xs) = go (x : acc) xs


fromList  :: SExp -> [SExp]
fromList ss
 = case ss of
    S.XApp (S.XRef (S.RSym "l")) xs -> xs
    S.XRef (S.RSym "o") -> []
    _                   -> failDecode "takeList failed"

fromI = fromIntegral

failDecode str
 = error $ "ddc-core.Shimmer.Decode." ++ str
