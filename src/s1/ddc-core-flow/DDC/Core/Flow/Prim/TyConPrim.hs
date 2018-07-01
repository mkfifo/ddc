
module DDC.Core.Flow.Prim.TyConPrim
        ( kindPrimTyCon
        , tVoid
        , tBool
        , tNat
        , tInt
        , tFloat
        , tWord
        , tVec)
where
import DDC.Core.Flow.Prim.Base
import DDC.Core.Flow.Exp.Simple.Compounds
import DDC.Core.Flow.Exp.Simple.Exp


-- | Yield the kind of a type constructor.
kindPrimTyCon :: PrimTyCon -> Kind Name
kindPrimTyCon tc
 = case tc of
        PrimTyConVoid    -> kData
        PrimTyConPtr     -> kRegion `kFun` kData `kFun` kData
        PrimTyConAddr    -> kData
        PrimTyConBool    -> kData
        PrimTyConNat     -> kData
        PrimTyConInt     -> kData
        PrimTyConSize    -> kData
        PrimTyConWord  _ -> kData
        PrimTyConFloat _ -> kData
        PrimTyConTag     -> kData
        PrimTyConTextLit -> kData
        PrimTyConVec   _ -> kData `kFun` kData


-- Compounds ------------------------------------------------------------------
-- | Primitive `Void#` type.
tVoid   = TCon (TyConBound (UName (NamePrimTyCon PrimTyConVoid)) kData)


-- | Primitive `Bool#` type.
tBool :: Type Name
tBool   = TCon (TyConBound (UName (NamePrimTyCon PrimTyConBool)) kData)


-- | Primitive Nat# type.
tNat ::  Type Name
tNat    = TCon (TyConBound (UName (NamePrimTyCon PrimTyConNat)) kData)


-- | Primitive `Int#` type.
tInt ::  Type Name
tInt    = TCon (TyConBound (UName (NamePrimTyCon PrimTyConInt)) kData)


-- | Primitive `FloatN#` type of the given width.
tFloat :: Int -> Type Name
tFloat bits
        = TCon (TyConBound (UName (NamePrimTyCon (PrimTyConFloat bits))) kData)


-- | Primitive `WordN#` type of the given width.
tWord :: Int -> Type Name
tWord bits
        = TCon (TyConBound (UName (NamePrimTyCon (PrimTyConWord bits))) kData)


-- | Primitive @VecN# a@.
tVec  :: Int -> Type Name -> Type Name
tVec n tA = TApp (tConPrimTyCon (PrimTyConVec n)) tA


-- Utils ----------------------------------------------------------------------
tConPrimTyCon :: PrimTyCon -> Type Name
tConPrimTyCon tcp
 = let  k       = kindPrimTyCon tcp
        u       = UName (NamePrimTyCon tcp)
        tc      = TyConBound u k
   in   TCon tc
