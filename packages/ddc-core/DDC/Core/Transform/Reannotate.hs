
module DDC.Core.Transform.Reannotate
        (Reannotate (..))
where
import DDC.Core.Module
import DDC.Core.Exp


class Reannotate c where
 reannotate :: (a -> b) -> c a n -> c b n


instance Reannotate Module where
 reannotate f
     (ModuleCore name 
                 exportKinds exportTypes 
                 importKinds importTypes
                 body)
  =   ModuleCore name
                 exportKinds exportTypes
                 importKinds importTypes
                 (reannotate f body)


instance Reannotate Exp where
 reannotate f xx
  = let down    = reannotate f
    in case xx of
        XVar  a u       -> XVar  (f a) u
        XCon  a u       -> XCon  (f a) u
        XLAM  a b x     -> XLAM  (f a) b (down x)
        XLam  a b x     -> XLam  (f a) b (down x)
        XApp  a x1 x2   -> XApp  (f a) (down x1)  (down x2)
        XLet  a lts x   -> XLet  (f a) (down lts) (down x)
        XCase a x alts  -> XCase (f a) (down x)   (map down alts)
        XCast a c x     -> XCast (f a) c          (down x)
        XType t         -> XType t
        XWitness w      -> XWitness w


instance Reannotate Lets where
 reannotate f xx
  = let down    = reannotate f
    in case xx of
        LLet m b x       -> LLet m b (down x)
        LRec bxs         -> LRec [(b, down x) | (b, x) <- bxs]
        LLetRegion  b bs -> LLetRegion  b bs
        LWithRegion b    -> LWithRegion b


instance Reannotate Alt where
 reannotate f aa
  = case aa of
        AAlt w x        -> AAlt w (reannotate f x)



