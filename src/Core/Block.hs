{-# OPTIONS -fwarn-incomplete-patterns #-}

-----
-- Core.Block
--	Ensures that the expression in lambdas, top level bindings, and RHS of case 
--	alternatives are all XDo's
--
--	This makes the Core.Snip's job easier because now it can just snip 
--	[Stmt] -> [Stmt] without worring about introducing more XDo's to hold snipped
--	statements.
--
--
module Core.Block
(
	blockTree
)

where

import Util
import Shared.Error
import Core.Exp
import Core.Plate.Trans

-----
-- stage	= "Core.Block"

-----
blockTree :: Tree -> Tree
blockTree tree
	= transZ 
		transTableId 
			{ transX	= \x -> return $ blockTreeX x 
			, transA	= \a -> return $ blockTreeA a 
			, transP	= \p -> return $ blockTreeP p 
			, transG	= \g -> return $ blockTreeG g }
		tree

-----	
blockTreeX xx
 = case xx of
	XLAM	v k x		-> XLAM v k (blockXL x)
 	XLam	v t x eff clo	-> XLam v t (blockXL x) eff clo
	_			-> xx

blockTreeA aa
 = case aa of
 	AAlt gs x		-> AAlt gs  (blockXF x)

blockTreeG gg
 = case gg of
 	GExp w x		-> GExp w (blockX x)

blockTreeP pp
 = case pp of
 	PBind v x		-> PBind v (blockXL x)
	_			-> pp


-- | force this expression to be an XDo
--	but allow XTau and XTet wrappers.
blockXF xx
 = case xx of
 	XDo{}			-> xx
	XTau t x		-> XTau t	$ blockXF x
	XTet vts x		-> XTet vts	$ blockXF x
	_			-> XDo [ SBind Nothing xx]

-- | force this expression to be an XDo
--	but allow XTau, XTet, XLam XLAM wrappers
blockX xx
 = case xx of
	XDo{}			-> xx
	XTau t x		-> blockXL xx
	XTet vts x		-> blockXL xx
	_			-> XDo [ SBind Nothing xx ]



blockXL xx
 = case xx of
  	XLAM{}			-> xx
	XLam{}			-> xx
	XTau   t x		-> XTau t 	(blockXL x)
	XTet   vts x		-> XTet vts 	(blockXL x)
	XDo{}			-> xx
	_			-> XDo [ SBind Nothing xx ]


