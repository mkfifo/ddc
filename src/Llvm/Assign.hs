{-# OPTIONS -fno-warn-unused-binds -fno-warn-type-defaults -cpp #-}

module Llvm.Assign
	(llvmOfAssign)
where

import DDC.Base.DataFormat
import DDC.Base.Literal
import DDC.Main.Error
import DDC.Sea.Exp
import DDC.Sea.Pretty

import Llvm
import LlvmM
import Llvm.Runtime
import Llvm.Util
import Llvm.Var
import Llvm.Exp


stage = "Llvm.Assign"

debug = True

llvmOfAssign :: Exp a -> Type -> Exp a -> LlvmM ()

-- Special case NULL pointer assignment
llvmOfAssign (XVar v1@NCafPtr{} t1) t@(TPtr (TCon TyConObj)) (XLit (LLit (LiteralFmt (LInt 0) Unboxed)))
 | t1 == t
 = do	dst		<- newUniqueReg $ pLift $ toLlvmType t1
	addBlock	[ Assignment dst (loadAddress (pVarLift (toLlvmCafVar (varOfName v1) t1)))
			, Store (LMLitVar (LMNullLit (toLlvmType t1))) dst ]

llvmOfAssign dst@(XVar n@NAuto{} t) tc src
 | t == tc
 = do	reg		<- llvmOfExp src
	alloc		<- newNamedReg (seaVar True $ varOfName n) $ toLlvmType t
	addBlock	[ Assignment alloc (Alloca (toLlvmType t) 1)
			, Store reg (pVarLift alloc) ]

llvmOfAssign (XVar (NSlot v i) tv@(TPtr (TCon TyConObj))) tc src
 | tv == tc
 = do	reg		<- llvmOfExp src
	writeSlot	reg i

llvmOfAssign (XVar v1@NCaf{} tv@(TPtr (TPtr (TCon TyConObj)))) tc src
 | tv == tc
 = do	reg		<- llvmOfExp src
	addBlock	[ Store reg (pVarLift (toLlvmCafVar (varOfName v1) tv)) ]

llvmOfAssign (XVar v1@NCafPtr{} tv@(TPtr (TCon TyConObj))) tc src
 | tv == tc
 = do	reg		<- llvmOfExp src
	dest		<- newUniqueReg $ toLlvmType tv
	addBlock	[ Assignment dest (loadAddress (pVarLift (toLlvmCafVar (varOfName v1) tv)))
			, Store reg (pVarLift dest) ]

llvmOfAssign (XVar v@NRts{} tv) tc src
 = do	reg		<- llvmOfExp src
	addBlock	[ Store reg (pVarLift (toLlvmRtsVar (varOfName v) tv)) ]



llvmOfAssign a b c
 = panic stage $ "llvmOfAssign (" ++ (show __LINE__) ++ ") Unhandled : \n"
	++ {- take 150 -} (show a) ++ "\n"
	++ {- take 150 -} (show b) ++ "\n"
	++ {- take 150 -} (show c) ++ "\n"

