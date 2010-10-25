-- {-# OPTIONS -fwarn-unused-imports -fwarn-incomplete-patterns -fno-warn-type-defaults #-}
{-# OPTIONS -fno-warn-unused-binds -fno-warn-type-defaults #-}

-- | Wrappers for compiler stages dealing with LLVM code.
module Main.Llvm
	(compileViaLlvm)
where

-- main stages
import Main.Setup
import Main.Sea
import Main.Util

import DDC.Base.DataFormat
import DDC.Base.Literal
import DDC.Base.SourcePos
import DDC.Main.Error
import DDC.Main.Pretty
import DDC.Var
import DDC.Var.PrimId

import qualified Module.Scrape		as M
import qualified DDC.Main.Arg		as Arg
import qualified DDC.Config.Version	as Version

import Llvm
import LlvmM
import Llvm.GhcReplace.Unique
import Llvm.Invoke
import Llvm.Runtime
import Llvm.Util

import DDC.Sea.Exp
import Sea.Util				(eraseAnnotsTree)
import DDC.Sea.Pretty

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

	llvmSource	<- evalStateT (outLlvm modName eTree pathSource) initLlvmState

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
	-> LlvmM LlvmModule

outLlvm moduleName eTree pathThis
 = do
	-- Break up the sea into parts.
	let 	([ 	_seaProtos, 		seaSupers
		 , 	_seaCafProtos,		seaCafSlots,		seaCafInits
		 ,	_seaData
		 , 	_seaHashDefs ],		junk)

		 = partitionFs
			[ (=@=) PProto{}, 	(=@=) PSuper{}
			, (=@=) PCafProto{},	(=@=) PCafSlot{},	(=@=) PCafInit{}
			, (=@=) PData{}
			, (=@=) PHashDef{} ]
			eTree

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

	renderModule	comments



llvmOfSeaDecls :: Top (Maybe a) -> LlvmM ()
llvmOfSeaDecls (PSuper v p t ss)
 = do	startFunction
	llvmOfFunc ss
	endFunction
		(LlvmFunctionDecl (seaVar False v) External CC_Ccc (toLlvmType t) FixedArgs (map llvmOfParams p) Nothing)
		-- (toLlvmFuncDecl linkage v t [])
		(map (seaVar True . fst) p)	-- funcArgs
		[]				-- funcAttrs
		Nothing				-- funcSect


llvmOfSeaDecls (PCafInit v t ss)
 = panic stage "Implement 'llvmOfSeaDecls (PCafInit v t ss)'"

llvmOfSeaDecls x
 = panic stage $ "Implement 'llvmOfSeaDecls (" ++ show x ++ ")'"



llvmOfParams :: (Var, Type) -> LlvmParameter
llvmOfParams (v, t) = (toLlvmType t, [])


llvmOfSeaGlobal :: Top (Maybe a) -> LMGlobal
llvmOfSeaGlobal (PCafSlot v t)
 | t == TPtr (TCon TyConObj)
 =	let	tt = pLift $ toLlvmType t
		var = LMGlobalVar
			("_ddcCAF_" ++ seaVar False v)	-- Variable name
			tt				-- LlvmType
			ExternallyVisible		-- LlvmLinkageType
			Nothing				-- LMSection
			ptrAlign			-- LMAlign
			False				-- LMConst
	in (var, Just (LMStaticLit (LMNullLit tt)))

 | otherwise
 = panic stage $ "llvmOfSeaGlobal on : \n\tVar  : " ++ seaVar False v ++ "\n\tType : " ++ show t

llvmOfSeaGlobal x
 = panic stage $ "llvmOfSeaGlobal on : " ++ show x

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

	-- LLVM is SSA so auto variables do not need to be declared.
	SAuto v t	-> addComment $ "SAuto " ++ seaVar True v ++ " " ++ show t

	_
	  -> panic stage $ "llvmOfStmt " ++ (take 150 $ show stmt)

--------------------------------------------------------------------------------

llvmSwitch :: Exp a -> [Alt a] -> LlvmM ()
llvmSwitch (XTag (XVar (NSlot v i) tPtrObj)) alt
 = do	addComment	$ "llvmSwitch : " ++ seaVar False v
	reg		<- readSlot i
	tag		<- getObjTag reg
	addComment	"-------------------------"

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

llvmSwitch e _
 = 	panic stage $ "llvmSwitch : " ++ show e


genAltVars :: LlvmVar -> Alt a -> LlvmM ((LlvmVar, LlvmVar), Alt a)
genAltVars switchEnd alt@(ASwitch (XLit (LDataTag v)) [])
 | varName v == "True"
 =	return ((i32LitVar 1, switchEnd), alt)

 | varName v == "Unit"
 =	return ((i32LitVar 0, switchEnd), alt)

genAltVars _ alt@(ACaseSusp (XVar (NSlot v i) t) label)
 = do	lab	<- newUniqueLabel "susp"
	return	((tagSusp, lab), alt)

genAltVars _ alt@(ACaseIndir (XVar (NSlot v i) t) label)
 = do	lab	<- newUniqueLabel "indir"
	return	((tagIndir, lab), alt)

genAltVars _ (ADefault _)
 = panic stage "getAltVars : found ADefault."

genAltVars _ x
 = panic stage $ "getAltVars : found " ++ show x


genAltBlock :: ((LlvmVar, LlvmVar), Alt a) -> LlvmM ()
genAltBlock ((_, lab), ACaseSusp (XVar (NSlot v i) t) label)
 = do	addBlock	[ MkLabel (uniqueOfLlvmVar lab) ]
	obj		<- readSlot i
	forced		<- forceObj obj
	writeSlot	forced i
	addBlock	[ Branch lab ]

genAltBlock ((_, lab), ACaseIndir (XVar (NSlot v i) t) label)
 = do	addBlock [ MkLabel (uniqueOfLlvmVar lab) ]
	obj		<- readSlot i
	followed	<- followObj obj
	writeSlot	followed i
	addBlock	[ Branch lab ]

genAltBlock ((_, lab), ASwitch (XLit (LDataTag _)) [])
 =	addBlock [ Branch lab ]

genAltBlock ((_, lab), x)
 = do	panic stage $ "getAltBlock : " ++ show x


genAltDefault :: LlvmVar -> Alt a -> LlvmM ()
genAltDefault label (ADefault ss)
 = do	addBlock [ MkLabel (uniqueOfLlvmVar label) ]
	mapM_ llvmOfStmt ss

genAltDefault label (ACaseDeath s@(SourcePos (n,l,c)))
 = do	addComment "deathCase goes here"
	gname	<- newUniqueName "str"
	let name = LMGlobalVar gname (typeOfString n) Internal Nothing ptrAlign True

	addGlobalVar ( name, Just (LMStaticStr n (typeOfString n)) )
	addBlock
		[ MkLabel (uniqueOfLlvmVar label)
		, Expr (Call StdCall (funcVarOfDecl deathCase) [name, i32LitVar l, i32LitVar c] [])
		, Unreachable
		]

genAltDefault _ def
 =	panic stage $ "getAltDefault : " ++ show def

--------------------------------------------------------------------------------

llvmOfAssign :: Exp a -> Type -> Exp a -> LlvmM ()
llvmOfAssign (XVar (NSlot v i) (TPtr (TCon TyConObj))) t@(TPtr (TCon TyConObj)) src
 = do	reg	<- loadExp t src
	writeSlot reg i

llvmOfAssign (XVar n1@NAuto{} t1) t@(TPtr (TCon TyConObj)) (XVar n2@NSlot{} t2)
 | t1 == t && t2 == t
 =	readSlotVar (nameSlotNum n2) $ toLlvmVar (varOfName n1) t


llvmOfAssign (XVar v1@NCaf{} t1) t@(TPtr (TPtr (TCon TyConObj))) (XVar v2@NRts{} t2)
 | t1 == t && t2 == t
 = do	src		<- newUniqueReg $ toLlvmType t
	addBlock	[ Assignment src (loadAddress (toLlvmCafVar (varOfName v2) t2))
			, Store src (pVarLift (toLlvmCafVar (varOfName v1) t1)) ]



llvmOfAssign (XVar v1@NCafPtr{} t1) t@(TPtr (TCon TyConObj)) (XLit (LLit (LiteralFmt (LInt 0) Unboxed)))
 | t1 == t
 = do	dst		<- newUniqueReg $ pLift $ toLlvmType t1
	addBlock	[ Assignment dst (loadAddress (pVarLift (toLlvmCafVar (varOfName v1) t1)))
			, Store (LMLitVar (LMNullLit (toLlvmType t1))) dst ]


llvmOfAssign (XVar v1@NCafPtr{} t1) t@(TPtr (TCon TyConObj)) x@(XPrim op args)
 | t1 == t
 = do	result		<- llvmOfXPrim op args
	addBlock	[ Store result (pVarLift (toLlvmCafVar (varOfName v1) t)) ]



llvmOfAssign (XVar v1@NRts{} t1) _ b@(XPrim op args)
 =	panic stage  ("llvmOfAssign .....\n" ++ (show v1) ++ "\n" ++ (show b) ++ "\n")




llvmOfAssign a b c
 = panic stage $ "Unhandled : llvmOfAssign \n"
	++ {- take 150 -} (show a) ++ "\n"
	++ {- take 150 -} (show b) ++ "\n"
	++ {- take 150 -} (show c) ++ "\n"

--------------------------------------------------------------------------------

loadExp :: Type -> Exp a -> LlvmM LlvmVar
loadExp (TPtr (TCon TyConObj)) (XVar n t@(TPtr (TCon TyConObj)))
 = 	return $ toLlvmVar (varOfName n) t

loadExp (TPtr (TCon TyConObj)) (XPrim op args)
 =	llvmOfXPrim op args

loadExp t src
 = panic stage $ "loadExp\n"
	++ show t ++ "\n"
	++ show src ++ "\n"

--------------------------------------------------------------------------------


llvmFunApply :: LlvmVar -> Type -> [Exp a] -> LlvmM LlvmVar
llvmFunApply fptr typ args
 = do	params	<- mapM llvmFunParam args
	addComment $ "llvmFunApply : " ++ show fptr
	applyN fptr params



llvmFunParam :: Exp a -> LlvmM LlvmVar

llvmFunParam (XVar (NSlot v i) _)
 = 	readSlot i

llvmFunParam (XVar n t)
 =	return $ toLlvmVar (varOfName n) t

llvmFunParam p
 = panic stage $ "llvmFunParam " ++ show p



pFunctionVar :: Var -> LlvmVar
pFunctionVar v
 = case isGlobalVar v of
	True -> LMGlobalVar (seaVar False v) pFunction External Nothing ptrAlign False
	False -> LMNLocalVar (seaVar True v) pFunction







boxExp :: Type -> Exp a -> LlvmM LlvmVar
boxExp t (XLit lit@(LLit (LiteralFmt (LInt value) (UnboxedBits 32))))
 = do	addComment $ "boxing1 " ++ show t
	boxInt32 $ i32LitVar value


boxExp t lit@(XLit (LLit (LiteralFmt (LString s) Unboxed)))
 = do	addComment $ "boxing2 " ++ show t
	gname	<- newUniqueName "str"
	let svar	= LMGlobalVar gname (typeOfString s) Internal Nothing ptrAlign True
	addGlobalVar	( svar, Just (LMStaticStr s (typeOfString s)) )
	-- panic stage $ "boxAny2 " ++ show svar
	boxAny		svar

boxExp t x
 = panic stage $ "Unhandled : boxExp\n    " ++ show t ++ "\n    " ++ (show x)


--------------------------------------------------------------------------------

-- LLVM does not allow implicit fall through to a label, so explicitly branch
-- to the label immediately following.
branchLabel :: String -> LlvmM ()
branchLabel name
 = do	let label = fakeUnique name
	addBlock [ Branch (LMLocalVar label LMLabel), MkLabel label ]

--------------------------------------------------------------------------------

llvmOfReturn :: Exp a -> LlvmM ()
llvmOfReturn (XVar n t)
 = do	addComment $ "Return type " ++ show t
	addBlock [ Return (Just (toLlvmVar (varOfName n) t)) ]

llvmOfReturn x
 = 	panic stage $ "llvmOfReturn " ++ (takeWhile (/= ' ') (show x))

--------------------------------------------------------------------------------

primMapFunc
	:: LlvmType
	-> (LlvmVar -> LlvmVar -> LlvmExpression)
	-> LlvmVar
	-> Exp a
	-> LlvmM LlvmVar

primMapFunc t build sofar exp
 = do	val		<- llvmVarOfExp exp
	dst		<- newUniqueNamedReg "prim.fold" t
	addBlock	[ Assignment dst (build sofar val) ]
	return		dst




llvmOfPtrManip :: LlvmType -> Prim -> [Exp a] -> LlvmM LlvmVar
llvmOfPtrManip t (MOp OpAdd) args
 = case args of
	[l@(XVar n t), XLit (LLit (LiteralFmt (LInt i) Unboxed))]
	 ->	do	addComment "llvmOfPtrManip"
			src		<- newUniqueReg $ toLlvmType t
			dst		<- newUniqueReg $ toLlvmType t
			addBlock	[ Assignment src (loadAddress (toLlvmVar (varOfName n) t))
					, Assignment dst (GetElemPtr True src [llvmWordLitVar i]) ]
			return dst

	_ ->	do	lift $ mapM_ (\a -> putStrLn ("\n    " ++ show a)) args
			panic stage $ "Unhandled : llvmOfPtrManip"

llvmOfPtrManip _ op _
 = panic stage $ "Unhandled : llvmOfPtrManip " ++ show op

--------------------------------------------------------------------------------

llvmOfXPrim :: Prim -> [Exp a] -> LlvmM LlvmVar
llvmOfXPrim (MBox (TCon (TyConUnboxed v))) [ XLit (LLit (LiteralFmt (LInt i) (UnboxedBits 32))) ]
 | varId v == VarIdPrim (TInt (UnboxedBits 32))
 =	boxInt32 $ i32LitVar i

llvmOfXPrim (MApp PAppCall) ((XVar (NSuper fv) ftype@(TFun pt rt)):args)
 | rt == TPtr (TCon TyConObj)
 = do	let func	= toLlvmFuncDecl External fv rt args
	addGlobalFuncDecl func
	params		<- mapM llvmFunParam args
	result		<- newUniqueNamedReg "result" pObj
	addBlock	[ Assignment result (Call TailCall (funcVarOfDecl func) params []) ]
	return		result

llvmOfXPrim (MApp PAppCall) ((XVar (NSuper fv) rt@(TPtr (TCon TyConObj))):[])
 = do	let func	= toLlvmFuncDecl External fv rt []
	addGlobalFuncDecl func
	result		<- newUniqueNamedReg "result" pObj
	addBlock	[ Assignment result (Call TailCall (funcVarOfDecl func) [] []) ]
	return		result


llvmOfXPrim (MOp OpAdd) [XVar v@NRts{} (TPtr t), XLit (LLit (LiteralFmt (LInt i) Unboxed)) ]
 = do	src		<- newUniqueReg (toLlvmType t)
	next		<- newUniqueReg (toLlvmType t)
	addBlock	[ Assignment src (loadAddress (toLlvmVar (varOfName v) t))
			, Assignment next (GetElemPtr True src [llvmWordLitVar i]) ]
	return		next

llvmOfXPrim (MBox t@(TCon (TyConAbstract tt))) [ x ]
 | varName tt == "String#"
 =	boxExp t x

llvmOfXPrim op args
 = panic stage $ "llvmOfXPrim\n"
	++ show op ++ "\n"
	++ show args ++ "\n"




llvmXPrimOne p e
 = panic stage $ "llvmXPrimOne\n    " ++ show p ++ "\n    " ++ show e



llvmVarOfExp :: Exp a -> LlvmM LlvmVar
llvmVarOfExp (XVar n t@TCon{})
 = do	addComment "llvmVarOfExp (XVar v Int32#)"
	return	$ toLlvmVar (varOfName n) t

llvmVarOfExp (XVar n t)
 = do	reg	<- newUniqueReg pObj
	addBlock [ Comment ["llvmVarOfExp (XVar v t)"]
		 , Assignment reg (Load (toLlvmVar (varOfName n) t)) ]
	return	reg

llvmVarOfExp (XLit (LLit (LiteralFmt (LInt i) Unboxed)))
 = do	reg	<- newUniqueReg i32
	addBlock [ Comment ["llvmVarOfExp (XInt i)"]
		 , Assignment reg (Load (llvmWordLitVar i)) ]
	return	reg

llvmVarOfExp x
 = panic stage $ "llvmVarOfExp : " ++ show x




llvmOpOfPrim :: Prim -> (LlvmVar -> LlvmVar -> LlvmExpression)
llvmOpOfPrim p
 = case p of
	MOp OpAdd	-> LlvmOp LM_MO_Add
	MOp OpSub	-> LlvmOp LM_MO_Sub
	MOp OpMul	-> LlvmOp LM_MO_Mul

	MOp OpEq	-> Compare LM_CMP_Eq
	_		-> panic stage $ "llvmOpOfPrim : Unhandled op : " ++ show p


-- | Convert a Sea type to an LlvmType.
toLlvmType :: Type -> LlvmType
toLlvmType (TPtr t)		= LMPointer (toLlvmType t)
toLlvmType (TCon TyConObj)	= structObj
toLlvmType TVoid		= LMVoid

toLlvmType (TCon (TyConUnboxed v))
 = case varName v of
	"Bool#"		-> i1
	"Int32#"	-> i32
	"Int64#"	-> i64
	name		-> panic stage $ "toLlvmType unboxed " ++ name ++ "\n"

toLlvmType (TFun r TVoid)
 = pFunction

toLlvmType t
 = panic stage $ "toLlvmType " ++ show t ++ "\n"


typeOfString :: String -> LlvmType
typeOfString s = LMArray (length s + 1) i8

-- | Convert a Sea Var (wit a Type) to a typed LlvmVar.
toLlvmVar :: Var -> Type -> LlvmVar
toLlvmVar v t@(TFun r TVoid)
 = LMNLocalVar (seaVar True v) (toLlvmType t)

toLlvmVar v t@(TFun _ _ )
 = panic stage $ "toLlvmVar type : " ++ show t

toLlvmVar v t
 = case isGlobalVar v of
	True -> LMGlobalVar (seaVar False v) (toLlvmType t) External Nothing (alignOfType t) False
	False -> LMNLocalVar (seaVar True v) (toLlvmType t)

alignOfType :: Type -> Maybe Int
alignOfType (TPtr _) = ptrAlign
alignOfType _ = Nothing

toLlvmCafVar :: Var -> Type -> LlvmVar
toLlvmCafVar v t
 = LMGlobalVar ("_ddcCAF_" ++ seaVar False v) (toLlvmType t) External Nothing Nothing False

toLlvmFuncDecl :: LlvmLinkageType -> Var -> Type -> [Exp a] -> LlvmFunctionDecl
toLlvmFuncDecl linkage v t args
 = LlvmFunctionDecl {
	--  Unique identifier of the function
	decName = seaVar False v,
	--  LinkageType of the function
	funcLinkage = linkage,
	--  The calling convention of the function
	funcCc = CC_Ccc,
	--  Type of the returned value
	decReturnType = toLlvmType t,
	--  Indicates if this function uses varargs
	decVarargs = FixedArgs,
	--  Parameter types and attributes
	decParams = map toDeclParam args,
	--  Function align value, must be power of 2
	funcAlign = ptrAlign
	}


toDeclParam :: Exp a -> LlvmParameter
toDeclParam (XVar (NSlot v i) t)
 = (toLlvmType t, [])

toDeclParam x
 = panic stage $ "toDeclParam " ++ show x


-- | Does the given Sea variable have global scope? TODO: Move this to the Sea stuff.
isGlobalVar :: Var -> Bool
isGlobalVar v
 -- If the variable is explicitly set as global use the given name.
 | bool : _	<- [global | ISeaGlobal global <- varInfo v]
 = bool

 | file : _	<- [sfile | ISourcePos (SourcePos (sfile, _, _))
		<-  concat [varInfo bound | IBoundBy bound <- varInfo v]]
 = isSuffixOf ".di" file

 | otherwise
 = False

