{-# OPTIONS -fwarn-incomplete-patterns -fwarn-unused-matches -fwarn-name-shadowing #-}

-- | Stripping fetters from types.
module DDC.Type.Strip
	( stripFWheresT_all
	, stripFWheresT_mono
	, stripForallContextT
	, stripToBodyT)
where
import DDC.Main.Error
import DDC.Type.Exp
import DDC.Type.Predicates
import DDC.Type.Compounds
import DDC.Type.Pretty		()
import qualified Data.Map	as Map

stage	= "DDC.Type.StripFetters"

-- | Strip all fetters from this type, returning just the body.
stripFWheresT_all  :: Type -> Type
stripFWheresT_all  = stripFWheresT False


-- | Strip the monomorphic FWhere fetters (the ones with cids as the RHS) 
--	leaving the others still attached.
stripFWheresT_mono :: Type -> Type
stripFWheresT_mono = stripFWheresT True


-- | Worker function for above
stripFWheresT 
	:: Bool 		-- ^ whether to only stip monomorphic FWhere fetters
	-> Type			-- ^ the type to strip
	-> Type

stripFWheresT justMono	tt
 = case tt of
	TNil		-> tt
	TFetters{}	-> panic stage $ "stripFWheresT: no match for TFetters"

	TError{} -> tt

	TForall b k t
	 -> TForall b k $ stripFWheresT justMono t

	TConstrain t crs
	 -- Just take the monomorphic FWheres
	 | justMono
	 -> let	t'	= stripFWheresT justMono t
		crs'	= Constraints
				(Map.filterWithKey (\t1 _ -> not $ isTClass t1) $ crsEq crs)
				(crsMore  crs)
				(crsOther crs)
	
	    in	makeTConstrain t' crs'
	
         -- Take all of thw FWheres
         | otherwise
	 -> let	t'	= stripFWheresT justMono t
	    	crs'	= Constraints
				Map.empty
				(crsMore crs)
				(crsOther crs)

	    in	makeTConstrain t' crs'
	
	TSum k ts
	 -> TSum k $ map (stripFWheresT justMono) ts

	TApp t1 t2
	 -> let	t1'	= stripFWheresT justMono t1
	 	t2'	= stripFWheresT justMono t2
	    in	TApp t1' t2'

	TCon _	-> tt

 	TVar{}	-> tt


-- | Strip foralls and contexts from the front of this type.
stripForallContextT :: Type -> ([(Bind, Kind)], [Kind], Type)
stripForallContextT tt
 = case tt of
	TForall BNil k1 t2	
	 -> let ( bks, ks, tBody) = stripForallContextT t2
	    in	( bks
	        , k1 : ks
		, tBody)

 	TForall b k t2	
	 -> let	(bks, ks, tBody) = stripForallContextT t2
	    in	( (b, k) : bks
	    	, ks
		, tBody)
		
	TConstrain t1 _
	 -> stripForallContextT t1

	TFetters t1 _
	 -> stripForallContextT t1

	_		
	 -> ([], [], tt)


-- | Strip TForalls and TFetters from a type to get the body.
stripToBodyT :: Type -> Type
stripToBodyT tt
 = case tt of
 	TForall  _ _ t		-> stripToBodyT t
	TFetters t _		-> stripToBodyT t
	_			-> tt
