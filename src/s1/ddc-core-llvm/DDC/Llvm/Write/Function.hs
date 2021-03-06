
module DDC.Llvm.Write.Function where
import DDC.Llvm.Syntax.Function
import DDC.Llvm.Syntax.Type
import DDC.Llvm.Write.Type      ()
import DDC.Llvm.Write.Attr      ()
import DDC.Llvm.Write.Instr     ()
import DDC.Llvm.Write.Base
import Data.Text                (Text)
import qualified Data.Text      as T


instance Write Config Function where
 write o (Function decl nsParam attrs sec blocks)
  = do
        text o "define "
        writeFunctionDeclWithNames o decl (Just $ map T.pack nsParam)

        space o
        punc  o " " attrs

        space o
        (case sec of
          SectionAuto           -> return ()
          SectionSpecific s
           -> do text o "section "; dquotes o (string o s))

        space o; text  o "{"; line o
        vwrite o blocks
        line  o; text  o "}"; line  o


writeFunctionDeclWithNames :: Config -> FunctionDecl -> Maybe [Text] -> IO ()
writeFunctionDeclWithNames o
        (FunctionDecl name linkage callConv tReturn varg params align mGcStrat)
        mnsParams
 = do
        write o linkage;  space o
        write o callConv; space o
        write o tReturn
        text  o " @"; string o name

        parens o $ do
            (case mnsParams of
              Nothing
               -> punc' o ", "
                    [ do write o t
                         (case attrs of
                            []      -> return ()
                            as      -> do space o; punc o " " as)
                    | Param t attrs <- params ]

              Just nsParams
               -> punc' o ", "
                    [ do write o t
                         (case attrs of
                            []      -> return ()
                            as      -> do space o; punc o " " as)
                         text o " %"; text o nParam
                    | Param t attrs <- params
                    | nParam <- nsParams ])

            (case varg of
              VarArgs | null params -> text o "..."
                      | otherwise   -> text o ", ..."
              _                     -> return ())

        (case align of
                AlignNone       -> return ()
                AlignBytes b    -> do text o " align "; write o b)

        (case mGcStrat of
                Nothing         -> return ()
                Just sStrat     -> do text o " gc "; dquotes o (string o sStrat))

