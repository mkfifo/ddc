
module DDCI.Core.Command
        ( Command(..)
        , commands
        , readCommand
        , handleCmd)
where
import DDCI.Core.Command.Help
import DDCI.Core.Command.Set
import DDCI.Core.Command.Load
import DDCI.Core.Command.Check
import DDCI.Core.Command.Eval
import DDCI.Core.Command.Trans
import DDCI.Core.Command.Ast
import DDCI.Core.Command.Sea
import DDCI.Core.Command.Llvm
import DDCI.Core.State
import Data.List


-- Command --------------------------------------------------------------------
-- | The commands that the interpreter supports.
data Command
        = CommandBlank          -- ^ No command was entered.
        | CommandUnknown        -- ^ Some unknown (invalid) command.
        | CommandHelp           -- ^ Display the interpreter help.
        | CommandSet            -- ^ Set a mode.
        | CommandLoad           -- ^ Load a module.
        | CommandKind           -- ^ Show the kind of a type.
        | CommandEquivType      -- ^ Check if two types are equivalent.
        | CommandWitType        -- ^ Show the type of a witness.
        | CommandExpCheck       -- ^ Check an expression.
        | CommandExpType        -- ^ Check an expression, showing its type.
        | CommandExpEffect      -- ^ Check an expression, showing its effect.
        | CommandExpClosure     -- ^ Check an expression, showing its closure.
        | CommandExpRecon       -- ^ Reconstruct type annotations on binders.
        | CommandEval           -- ^ Evaluate an expression.
        | CommandTrans          -- ^ Transform an expression.
        | CommandTransEval      -- ^ Transform then evaluate an expression.
        | CommandAst            -- ^ Show the AST of an expression.
        | CommandSea            -- ^ Convert a Sea core module to C code.
        | CommandLlvm           -- ^ Convert a Sea core module to LLVM code.
        deriving (Eq, Show)


-- | Names used to invoke each command.
commands :: [(String, Command)]
commands 
 =      [ (":help",     CommandHelp)
        , (":?",        CommandHelp)
        , (":set",      CommandSet)
        , (":load",     CommandLoad)
        , (":kind",     CommandKind)
        , (":tequiv",   CommandEquivType)
        , (":wtype",    CommandWitType)
        , (":check",    CommandExpCheck)
        , (":recon",    CommandExpRecon)
        , (":type",     CommandExpType)
        , (":effect",   CommandExpEffect)
        , (":closure",  CommandExpClosure)
        , (":eval",     CommandEval)
        , (":trans",    CommandTrans)
        , (":trun",     CommandTransEval)
        , (":ast",      CommandAst) 
        , (":sea",      CommandSea)
        , (":llvm",     CommandLlvm) ]


-- | Read the command from the front of a string.
readCommand :: String -> Maybe (Command, String)
readCommand ss
        | null $ words ss
        = Just (CommandBlank,   ss)

        | [(cmd, rest)] <- [ (cmd, drop (length str) ss) 
                                        | (str, cmd)      <- commands
                                        , isPrefixOf str ss ]
        = Just (cmd, rest)

        | ':' : _       <- ss
        = Just (CommandUnknown, ss)

        | otherwise
        = Nothing


        -- Commands -------------------------------------------------------------------
-- | Handle a single line of input.
handleCmd :: State -> Command -> Int -> String -> IO State
handleCmd state CommandBlank _ _
 = return state

handleCmd state cmd lineStart line
 = do   state'  <- handleCmd1 state cmd lineStart line
        return state'

handleCmd1 state cmd lineStart line
 = case cmd of
        CommandBlank
         -> return state

        CommandUnknown
         -> do  putStr $ unlines
                 [ "unknown command."
                 , "use :? for help." ]

                return state

        CommandHelp
         -> do  putStr help
                return state

        CommandSet        
         -> do  state'  <- cmdSet state line
                return state'

        CommandLoad
         -> do  cmdLoad state lineStart line
                return state

        CommandKind       
         -> do  cmdShowKind state lineStart line
                return state

        CommandEquivType
         -> do  cmdTypeEquiv state lineStart line
                return state

        CommandWitType    
         -> do  cmdShowWType state lineStart line
                return state

        CommandExpCheck   
         -> do  cmdShowType state ShowTypeAll     lineStart line
                return state

        CommandExpType  
         -> do  cmdShowType state ShowTypeValue   lineStart line
                return state

        CommandExpEffect  
         -> do  cmdShowType state ShowTypeEffect  lineStart line
                return state

        CommandExpClosure 
         -> do  cmdShowType state ShowTypeClosure lineStart line
                return state

        CommandExpRecon
         -> do  cmdExpRecon state lineStart line
                return state

        CommandEval       
         -> do  cmdEval state lineStart line
                return state

        CommandTrans
         -> do  cmdTrans state lineStart line
                return state
        
        CommandTransEval
         -> do  cmdTransEval state lineStart line
                return state
        
        CommandAst
         -> do  cmdAst state lineStart line
                return state

        CommandSea
         -> do  cmdSeaOut state lineStart line
                return state

        CommandLlvm
         -> do  cmdLlvmOut state lineStart line
                return state