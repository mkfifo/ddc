
-- | Lambda lifter state.
module Core.Lift.Base
	( LiftS(..)
	, LiftM
	, initLiftS
	, bindType
	, getType
	, getKind
	, newVar
	, addChopped
	, getChopped)
where
import Core.Exp
import Util
import Type.Exp
import DDC.Main.Error
import DDC.Main.Pretty
import DDC.Var
import qualified Shared.Unique	as Unique
import qualified Data.Map	as Map
import qualified Data.Set	as Set

-----
stage	= "Core.Lift.Base"


-- | Lifter state
type LiftM = State LiftS	
data LiftS
	= LiftS
	{ stateVarGen		:: VarId

	, stateTypes		:: Map Var Type

	-- | Vars defined at top level,
	--	grows as new supers are lifted out.
	, stateTopVars		:: Set Var			


	-- | A list of bindings chopped out on this pass
	--	old name, new (top level) name, expression
	--
	, stateChopped		:: [(Var, Var, Top)] 		
								
	}	
								
initLiftS
	= LiftS
	{ stateVarGen		= VarId ("v" ++ Unique.coreLift) 0
	, stateTypes		= Map.empty
	, stateTopVars		= Set.empty
	, stateChopped		= [] 
	}



-- | Add a typed variable to the state
bindType :: Var -> Type -> LiftM ()
bindType v t
 	= modify (\s -> s 
		{ stateTypes 	= Map.insert v t (stateTypes s) })
		

-- | Get the type of some variable from the state.
getType :: Var -> LiftM Type
getType	 v
 = case varNameSpace v of
	NameValue	
	 -> do	t	<- liftM (fromMaybe TNil)
			$  liftM (Map.lookup v)
			$  gets stateTypes
			
		return t
	
	_ -> panic stage $ "getType: no type for " % v % " space = " % show (varNameSpace v)
	

-- | Get the kind of some variable by examining its namespace.
getKind :: Var -> LiftM Kind
getKind	 v
 = case varNameSpace v of
	NameType	-> return kValue
 	NameRegion	-> return kRegion
	NameEffect	-> return kEffect
	NameClosure	-> return kClosure

	-- doh
	NameClass	-> return KNil
	

-- | Create a new var in a certain namespace
newVar :: NameSpace -> LiftM Var
newVar	space
 = do
 	gen		<- gets stateVarGen
	let gen'	= incVarId gen
	let var		= (varWithName $ pprStrPlain gen) 
				{ varId 		= gen 
				, varNameSpace		= space }
	
	modify (\s -> s { stateVarGen = gen' })
	
	return	var
	
	
-----
addChopped :: Var -> Var -> Top -> LiftM ()
addChopped old new x
 	= modify (\s -> s { stateChopped =  stateChopped s ++ [(old, new, x)]})

getChopped :: LiftM [(Var, Var, Top)]
getChopped	
 = do 	cs	<- gets stateChopped
	modify (\s -> s { stateChopped = [] })
	
	return cs


