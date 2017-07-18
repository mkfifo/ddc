
module DDC.Core.Flow.Convert.Base
        (  ConvertM
        ,  Error (..)
        ,  withRateXLAM, isRateXLAM
        ,  withSuspFns,   isSuspFn)
where
import DDC.Data.Pretty
import DDC.Core.Exp.Annot
import DDC.Core.Flow.Prim                       as F
import qualified DDC.Control.Check              as G

import qualified Data.Set                       as S
import Data.Maybe

-- | Conversion Monad
-- State contains
--  * names of function that have been converted to Suspended computations.
--    whenever these are called, we need to add a "run" cast.
--  * names of rate XLAMs that have been removed.
--    any reference to these must also be removed.
type ConvertM x = G.CheckM (S.Set F.Name, S.Set F.Name) Error x


withRateXLAM :: Bind F.Name -> ConvertM a -> ConvertM a
withRateXLAM r c
 | Just r' <- takeNameOfBind r
 = do   (fs,rs) <- G.get
        G.put (fs, S.insert r' rs)
        val <- c
        G.put (fs, rs)
        return $ val
 | otherwise
 = c


isRateXLAM :: F.Name -> ConvertM Bool
isRateXLAM r
 = do   (_,rs) <- G.get
        return $ S.member r rs


withSuspFns :: [Bind F.Name] -> ConvertM a -> ConvertM a
withSuspFns bs c
 = do   (fs,rs) <- G.get
        let ns = catMaybes $ map takeNameOfBind bs
        G.put (S.union (S.fromList ns) fs, rs)
        val <- c
        G.put (fs, rs)
        return $ val

isSuspFn :: F.Name -> ConvertM Bool
isSuspFn f
 = do   (fs,_) <- G.get
        return $ S.member f fs


-- | Things that can go wrong during the conversion.
data Error
        -- | An invalid name used in a binding position
        = ErrorInvalidBinder F.Name

        -- | A partially applied primitive, such as "Series"
        | ErrorPartialPrimitive F.Name

        -- | Something we can't convert, like "runKernel0#",
        -- but that shouldn't be created
        | ErrorNotSupported F.Name

        -- | Found an unexpected type sum.
        | ErrorUnexpectedSum


instance Pretty Error where
 ppr err
  = case err of
        ErrorInvalidBinder n
         -> vcat [ text "Invalid name used in binder '" <> ppr n <> text "'."]

        ErrorPartialPrimitive n
         -> vcat [ text "Cannot convert primitive " <> ppr n <> text "." ]

        ErrorNotSupported n
         -> vcat [ text "Cannot convert " <> ppr n <> text ", as it shouldn't be generated by flow transforms." ]

        ErrorUnexpectedSum
         -> vcat [ text "Unexpected type sum."]
