{-# OPTIONS -fno-warn-unused-binds -fno-warn-type-defaults -cpp #-}

-- | Wrappers for compiler stages dealing with LLVM code.
module Main.Llvm
	(compileViaLlvm)
where

-- main stages
import Main.Setup
import Main.Sea
import Main.Util

import DDC.Base.SourcePos
import DDC.Main.Error
import DDC.Main.Pretty
import DDC.Sea.Exp
import DDC.Sea.Pretty
import DDC.Var

import qualified DDC.Module.Scrape	as M
import qualified DDC.Main.Arg		as Arg
import qualified DDC.Config.Version	as Version

import Llvm
import LlvmM
import Llvm.Assign
import Llvm.Exp
import Llvm.Func
import Llvm.GhcReplace.Unique
import Llvm.Invoke
import Llvm.Runtime
import Llvm.Util
import Llvm.Var

import Sea.Util				(eraseAnnotsTree)

import Util
import qualified Data.Map		as Map

import qualified Debug.Trace		as Debug


stage = "Main.Llvm"

debug = True

_trace s v
 =	if debug
	  then Debug.trace s v
	  else v


compileViaLlvm
	:: (?verbose :: Bool, ?pathSourceBase :: FilePath)
	=> Setup			-- ^ Compile setup.
	-> ModuleId			-- ^ Module to compile, must also be in the scrape graph.
	-> Tree ()			-- ^ The Tree for the module.
	-> FilePath			-- ^ FilePath of source file.
	-> [FilePath]			-- ^ C import directories.
	-> [FilePath]			-- ^ C include files.
	-> Map ModuleId [a]		-- ^ Module import map.
	-> Bool				-- ^ Module defines 'main' function.
	-> M.Scrape			-- ^ ScrapeGraph of this Module.
	-> Map ModuleId M.Scrape	-- ^ Scrape graph of all modules reachable from the root.
	-> Bool				-- ^ Whether to treat a 'main' function defined by this module
					--	as the program entry point.
	-> IO Bool

compileViaLlvm
	setup modName eTree pathSource importDirs includeFilesHere importsExp
	modDefinesMainFn sRoot scrapes_noRoot blessMain
 = do
	let ?args		= setupArgs setup

	outVerb $ ppr $ "  * Write C header\n"
	writeFile (?pathSourceBase ++ ".ddc.h")
		$ makeSeaHeader
			eTree
			pathSource
			(map (fromJust . M.scrapePathHeader) $ Map.elems scrapes_noRoot)
			includeFilesHere

	outVerb $ ppr $ "  * Generating LLVM IR code\n"

	llvmSource	<- evalStateT (outLlvm modName eTree pathSource importsExp modDefinesMainFn) initLlvmState

	writeFile (?pathSourceBase ++ ".ddc.ll")
			$ ppLlvmModule llvmSource

	invokeLlvmCompiler ?pathSourceBase []
	invokeLlvmAssembler ?pathSourceBase []

	return modDefinesMainFn


-- | Create LLVM source files
outLlvm
	:: (?args :: [Arg.Arg])
	=> ModuleId
	-> (Tree ())		-- sea source
	-> FilePath		-- path of the source file
	-> Map ModuleId [a]
	-> Bool			-- is main module
	-> LlvmM LlvmModule

outLlvm moduleName eTree pathThis importsExp modDefinesMainFn
 = do
	-- Break up the sea into parts.
	let 	([ 	_seaProtos, 		seaSupers
		 , 	_seaCafProtos,		seaCafSlots,		seaCafInits
		 ,	_seaData
		 , 	seaCtorTags ],		junk)

		 = partitionBy
			[ (=@=) PProto{}, 	(=@=) PSuper{}
			, (=@=) PCafProto{},	(=@=) PCafSlot{},	(=@=) PCafInit{}
			, (=@=) PData{}
			, (=@=) PCtorTag{} ]
			eTree

	setTags		$ map (\(PCtorTag s i) -> (s, i)) seaCtorTags

	when (not $ null junk)
		$ panic stage $ "junk sea bits = " ++ show junk ++ "\n"

	-- Build the LLVM code
	let comments =	[ "---------------------------------------------------------------"
			, "      source: " ++ pathThis
			, "generated by: " ++ Version.ddcName
			, "" ]

	addAlias	("struct.Obj", ddcObj)

	mapM_		addGlobalVar
				$ moduleGlobals
				++ (map llvmOfSeaGlobal $ eraseAnnotsTree seaCafSlots)

	mapM_		llvmOfSeaDecls $ eraseAnnotsTree $ seaCafInits ++ seaSupers

	let mainType	= foldl findMainType LMVoid seaSupers

	when modDefinesMainFn
			$ llvmMainModule moduleName (map fst $ Map.toList importsExp) mainType

	renderModule	comments


findMainType :: LlvmType -> Top () -> LlvmType
findMainType _ (PSuper v _ t _)
 | varName v == "main"
 = toLlvmType t

findMainType t _
 = t


llvmOfSeaDecls :: Top (Maybe a) -> LlvmM ()
llvmOfSeaDecls (PSuper v p t ss)
 = do	startFunction
	mapM_ allocForParam p
	llvmOfFunc ss
	endFunction
		(LlvmFunctionDecl (seaVar False v) External CC_Ccc (toLlvmType t) FixedArgs (map llvmOfParams p) Nothing)
		(map (\ (v, _) -> "_p" ++ seaVar True v) p)	-- funcArgs
		[]				-- funcAttrs
		Nothing				-- funcSect


llvmOfSeaDecls (PCafInit v t ss)
 = panic stage "Implement 'llvmOfSeaDecls (PCafInit v t ss)'"

llvmOfSeaDecls x
 = panic stage $ "Implement 'llvmOfSeaDecls (" ++ show x ++ ")'"



llvmOfParams :: (Var, Type) -> LlvmParameter
llvmOfParams (v, t) = (toLlvmType t, [])


-- All SAuto vars need to be alloca-ed on the stack. There are two reasons for
-- this:
--
--    a) According to the comments in src/Sea/Slot.hs, in compiled tail
--       recursive functions there may be assignments to arguments in the
--       parameter list.
--
--    b) Nauto variables can appear on the LHS of an assignment requiring Nauto
--       vars to be handled differently whether they are on the LHS or RHS of
--       the assignment. Handling them differently would make LLVM code gen
--       difficult.
--
-- The should be no performance penalty to using alloca-ed vars because,
-- fortunately, the LLVM compiler will convert alloca-ed variables into SSA
-- registers on-the-fly early in the optimisation pipeline.
--
-- For a function parameter in the Sea AST called 'X', the variable in the code
-- will be called '_vX' and the function parameter called '_p_vX'. The function
-- allocForParam generates the alloca required for the given variable.

allocForParam :: (Var, Type) -> LlvmM ()
allocForParam (v, t)
 = do	reg		<- newNamedReg ("_p" ++ seaVar True v) $ toLlvmType t
	alloc		<- newNamedReg (seaVar True v) $ toLlvmType t
	addBlock	[ Assignment alloc (Alloca (toLlvmType t) 1)
			, Store reg (pVarLift alloc) ]



llvmOfSeaGlobal :: Top (Maybe a) -> LMGlobal
llvmOfSeaGlobal (PCafSlot v t@(TPtr (TCon TyConObj)))
 =	let	tt = pLift $ toLlvmType t
		var = LMGlobalVar
			("_ddcCAF_" ++ seaVar False v)	-- Variable name
			tt				-- LlvmType
			ExternallyVisible		-- LlvmLinkageType
			Nothing				-- LMSection
			ptrAlign			-- LMAlign
			False				-- LMConst
	in (var, Just (LMStaticLit (LMNullLit tt)))

llvmOfSeaGlobal (PCafSlot v t@(TCon (TyConUnboxed tv)))
 =	let	tt = toLlvmType t
		var = LMGlobalVar
			("_ddcCAF_" ++ seaVar False v)
			tt
			ExternallyVisible
			Nothing
			ptrAlign
			False
	in (var, Just (LMStaticLit (initLiteral tt)))

llvmOfSeaGlobal x
 = panic stage $ "llvmOfSeaGlobal (" ++ show __LINE__ ++ ")\n\n"
		++ show x ++ "\n"


initLiteral :: LlvmType -> LlvmLit
initLiteral t
 = case t of
	LMPointer _	-> LMNullLit t
	LMInt _		-> LMIntLit 0 t
	LMFloat		-> LMFloatLit 0.0 t
	LMDouble	-> LMFloatLit 0.0 t


moduleGlobals :: [LMGlobal]
moduleGlobals
 = 	[ ( ddcSlotPtr	, Nothing )
	, ( ddcSlotMax	, Nothing )
	, ( ddcSlotBase	, Nothing )
	, ( ddcHeapPtr	, Nothing )
	, ( ddcHeapMax	, Nothing ) ]


llvmOfFunc :: [Stmt a] -> LlvmM ()
llvmOfFunc ss
 =	mapM_ llvmOfStmt ss


llvmOfStmt :: Stmt a -> LlvmM ()
llvmOfStmt stmt
 = case stmt of
	SBlank		-> addComment "Blank"
	SEnter n	-> runtimeEnter n
	SLeave n	-> runtimeLeave n
	SComment s	-> addComment s
	SGoto loc	-> addBlock [Branch (LMNLocalVar (seaVar False loc) LMLabel)]
	SAssign v1 t v2 -> llvmOfAssign v1 t v2
	SReturn v	-> llvmOfReturn v
	SSwitch e a	-> llvmSwitch e a
	SLabel l	-> branchLabel (seaVar False l)
	SIf e s		-> llvmOfSIf e s

	-- LLVM is SSA bu SAuto variables can be reused, so we need to Alloca for them.
	SAuto v t	-> llvmSAuto v t
	SStmt exp	-> llvmOfSStmt exp
	SCaseFail	-> caseDeath "?" 0 0
	_
	  -> panic stage $ "llvmOfStmt (" ++ show __LINE__ ++ ")\n\n" ++ show stmt ++ "\n"


--------------------------------------------------------------------------------

llvmSAuto :: Var -> Type -> LlvmM ()
llvmSAuto v t
 = do	reg		<- newNamedReg (seaVar True v) $ toLlvmType t
	addBlock	[ Assignment reg (Alloca (toLlvmType t) 1) ]


llvmOfSStmt :: Exp a -> LlvmM ()
llvmOfSStmt (XPrim (MApp PAppCall) (fexp:args))
 = do	let func	= funcDeclOfExp fexp
	addGlobalFuncDecl func
	params		<- mapM llvmOfExp args
	addBlock	[ Expr (Call TailCall (funcVarOfDecl func) params []) ]

llvmOfSStmt x@(XPrim op@(MApp PAppApply) args)
 = do	_		<- llvmOfExp x
	addComment	"Ignore last value."

llvmOfSStmt x
 = panic stage $ "llvmOfSStmt:" ++ show __LINE__ ++ "\n\n" ++ show x ++ "\n"

--------------------------------------------------------------------------------

llvmOfSIf :: Exp a -> [Stmt a] -> LlvmM ()
llvmOfSIf exp@XPrim{} stmts
 = do	true	<- llvmOfExp exp
	bTrue	<- newUniqueLabel "bt"
	bFalse	<- newUniqueLabel "bf"
	addBlock
		[ BranchIf true bTrue bFalse
		, MkLabel (uniqueOfLlvmVar bTrue) ]
	llvmOfFunc stmts
	addBlock
		[ MkLabel (uniqueOfLlvmVar bFalse) ]

--------------------------------------------------------------------------------

llvmSwitch :: Exp a -> [Alt a] -> LlvmM ()
llvmSwitch (XTag xv@(XVar _ t)) alt
 | t == TPtr (TCon TyConObj)
 = do	addComment	$ "llvmSwitch : " ++ show xv
	reg		<-llvmOfExp xv
	doSwitch	reg alt

llvmSwitch e _
 = 	panic stage $ "llvmSwitch (" ++ (show __LINE__) ++ ") : " ++ show e


doSwitch :: LlvmVar -> [Alt a] -> LlvmM ()
doSwitch reg alt
 = do	tag		<- getObjTag reg

	switchEnd	<- newUniqueLabel "switch.end"
	switchDef	<- newUniqueLabel "switch.default"

	let (def, rest)
			= partition (\ s -> s =@= ADefault{} || s =@= ACaseDeath{}) alt

	alts		<- mapM (genAltVars switchEnd) rest
	addBlock	[ Switch tag switchDef (map fst alts) ]
	mapM_		genAltBlock alts

	if null def
	  then	addBlock [ Branch switchEnd ]
	  else	mapM_ (genAltDefault switchDef) def

	addBlock	[ MkLabel (uniqueOfLlvmVar switchEnd) ]


--------------------------------------------------------------------------------

genAltVars :: LlvmVar -> Alt a -> LlvmM ((LlvmVar, LlvmVar), Alt a)
genAltVars switchEnd alt@(ASwitch (XLit (LDataTag v)) [])
 = case seaVar False v of
	"Base_Unit"	-> return ((i32LitVar 0, switchEnd), alt)
	"Base_False"	-> return ((i32LitVar 0, switchEnd), alt)
	"Base_True"	-> return ((i32LitVar 1, switchEnd), alt)
	tag		-> do	value	<- getTag tag
				return	((i32LitVar value, switchEnd), alt)

genAltVars _ alt@(ACaseSusp (XVar _ t) label)
 = do	lab	<- newUniqueLabel "susp"
	return	((tagSusp, lab), alt)

genAltVars _ alt@(ACaseIndir (XVar _ t) label)
 = do	lab	<- newUniqueLabel "indir"
	return	((tagIndir, lab), alt)

genAltVars _ (ADefault _)
 = panic stage $ "getAltVars (" ++ (show __LINE__) ++ ") : found ADefault."

genAltVars _ x
 = panic stage $ "getAltVars (" ++ (show __LINE__) ++ ") : found " ++ show x


genAltBlock :: ((LlvmVar, LlvmVar), Alt a) -> LlvmM ()
genAltBlock ((_, lab), ACaseSusp (XVar (NSlot v i) t) label)
 = do	addComment $ "genAltBlock " ++ show __LINE__
	addBlock	[ MkLabel (uniqueOfLlvmVar lab) ]
	obj		<- readSlot i
	forced		<- forceObj obj
	writeSlot	forced i
	addBlock	[ Branch lab ]

genAltBlock ((_, lab), ACaseIndir (XVar (NSlot v i) t) label)
 = do	addComment $ "genAltBlock " ++ show __LINE__
	addBlock [ MkLabel (uniqueOfLlvmVar lab) ]
	obj		<- readSlot i
	followed	<- followObj obj
	writeSlot	followed i
	addBlock	[ Branch lab ]

genAltBlock ((_, lab), ACaseSusp exp@(XVar n@NCafPtr{} t) label)
 = do	addComment $ "genAltBlock " ++ show __LINE__
	addBlock	[ MkLabel (uniqueOfLlvmVar lab) ]
	obj		<- llvmOfExp exp
	forced		<- forceObj obj
	addBlock	[ Branch lab ]

genAltBlock ((_, lab), ACaseIndir exp@(XVar n@NCafPtr{} t) label)
 = do	addComment $ "genAltBlock " ++ show __LINE__
	addBlock [ MkLabel (uniqueOfLlvmVar lab) ]
	obj		<- llvmOfExp exp
	followed	<- followObj obj
	addBlock	[ Branch lab ]

genAltBlock ((_, lab), ASwitch (XLit (LDataTag _)) [])
 = do	addComment $ "genAltBlock " ++ show __LINE__
	addBlock [ Branch lab ]

genAltBlock ((_, lab), x)
 =	panic stage $ "getAltBlock (" ++ (show __LINE__) ++ ") : " ++ show x


genAltDefault :: LlvmVar -> Alt a -> LlvmM ()
genAltDefault label (ADefault ss)
 = do	addBlock [ MkLabel (uniqueOfLlvmVar label) ]
	mapM_ llvmOfStmt ss

genAltDefault label (ACaseDeath s@(SourcePos (n,l,c)))
 = do	addBlock [ MkLabel (uniqueOfLlvmVar label) ]
	caseDeath n l c

genAltDefault _ def
 =	panic stage $ "getAltDefault (" ++ (show __LINE__) ++ ") : " ++ show def


caseDeath :: String -> Int -> Int -> LlvmM ()
caseDeath file line column
 = do	addGlobalFuncDecl deathCase

	gname	<- newUniqueName "str.src.file"
	let name = LMGlobalVar gname (typeOfString file) Internal Nothing ptrAlign True
	addGlobalVar ( name, Just (LMStaticStr file (typeOfString file)) )
	pstr	<- newUniqueNamedReg "pstr" pChar

	addBlock
		[ Assignment pstr (GetElemPtr True (pVarLift name) [llvmWordLitVar 0, llvmWordLitVar 0])
		, Expr (Call StdCall (funcVarOfDecl deathCase) [pstr, i32LitVar line, i32LitVar column] [])
		, Unreachable
		]

--------------------------------------------------------------------------------

-- LLVM does not allow implicit fall through to a label, so explicitly branch
-- to the label immediately following.
branchLabel :: String -> LlvmM ()
branchLabel name
 = do	let label = fakeUnique name
	addBlock [ Branch (LMLocalVar label LMLabel), MkLabel label ]

--------------------------------------------------------------------------------

llvmOfReturn :: Exp a -> LlvmM ()

llvmOfReturn (XVar n@(NAuto v) t)
 = do	addComment	$ "Return NAuto " ++ show v
	reg		<- newUniqueReg $ toLlvmType t
	addBlock	[ Assignment reg (loadAddress (toLlvmVar (varOfName n) t))
			, Return (Just reg) ]

llvmOfReturn (XVar n t)
 = do	addComment $ "Return " ++ show n
	addBlock [ Return (Just (toLlvmVar (varOfName n) t)) ]

llvmOfReturn x
 = 	panic stage $ "llvmOfReturn (" ++ (show __LINE__) ++ ") " ++ (takeWhile (/= ' ') (show x))

