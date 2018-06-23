
module DDC.Driver.Command.Load
        ( cmdLoadFromFile
        , cmdLoadDiscusSourceFromFile
        , cmdLoadDiscusSourceFromString
        , cmdLoadCoreFromFile
        , cmdLoadCoreFromString
        , cmdLoadSimplifier
        , cmdLoadSimplifierIntoBundle)
where
import DDC.Driver.Command.Compile
import DDC.Driver.Command.Read
import DDC.Driver.Stage
import DDC.Driver.Config
import DDC.Driver.Interface.Source
import qualified DDC.Driver.Stage.Tetra                         as DE

import DDC.Build.Pipeline
import DDC.Build.Language
import DDC.Build.Interface.Store                                (Store)
import qualified DDC.Build.Interface.Store                      as Store
import qualified DDC.Build.Spec.Parser                          as Spec
import qualified DDC.Build.Language.Discus                      as Tetra
import qualified DDC.Build.Interface.Codec.Text.Encode          as IntText

import DDC.Core.Simplifier.Parser
import DDC.Core.Transform.Reannotate
import DDC.Core.Exp.Annot.AnTEC
import DDC.Core.Codec.Text.Pretty
import qualified DDC.Core.Check         as C
import qualified DDC.Core.Discus        as Tetra

import DDC.Data.SourcePos

import Control.Monad
import Control.Monad.Trans.Except
import Control.Monad.IO.Class
import Control.DeepSeq
import System.FilePath
import System.Directory
import qualified Data.Text              as T
import qualified Data.Map               as Map

---------------------------------------------------------------------------------------------------
-- | Load and transform source code, interface, or build file.
--
--   The source language is determined by inspecting the file extension.
--
--   The result is printed to @stdout@.
--   Any errors are thrown in the `ExceptT` monad.
--
cmdLoadFromFile
        :: Config               -- ^ Driver config.
        -> Store                -- ^ Interface store.
        -> Maybe String         -- ^ Simplifier specification.
        -> [FilePath]           -- ^ More modules to use as inliner templates.
        -> FilePath             -- ^ Module file name.
        -> ExceptT String IO ()

cmdLoadFromFile config store mStrSimpl fsTemplates filePath

 -- Load build file.
 | ".build"     <- takeExtension filePath
 = do   str     <- liftIO $ readFile filePath
        case Spec.parseBuildSpec filePath str of
         Left err       -> throwE $ show err
         Right spec     -> liftIO $ putStrLn $ show spec

 -- Load a text interface file and print it as text.
 | elem (takeExtension filePath) [".di", ".sms"]
 = do   iint    <- liftIO $ Store.load filePath
        case iint of
         Left err    -> throwE $ renderIndent $ ppr err
         Right iface -> liftIO $ putStrLn $ T.unpack $ IntText.encodeInterface iface

 -- Load a Discus Source module.
 | ".ds"        <- takeExtension filePath
 = case mStrSimpl of
        Nothing
         -> do  cmdLoadDiscusSourceFromFile config store Tetra.bundle filePath

        Just strSimpl
         -> do  -- Parse the specified simplifier.
                bundle' <- cmdLoadSimplifierIntoBundle config
                                Tetra.bundle strSimpl fsTemplates

                -- Load a simplify the target module.
                cmdLoadDiscusSourceFromFile config store bundle' filePath

 -- Load a module in some fragment of Disciple Core.
 | Just language <- languageOfExtension (takeExtension filePath)
 = case mStrSimpl of
        Nothing
         ->     cmdLoadCoreFromFile config language filePath

        Just strSimpl
         -> do  language' <- cmdLoadSimplifier config language strSimpl fsTemplates
                cmdLoadCoreFromFile config language' filePath

 -- Don't know how to load this file.
 | otherwise
 = let  ext     = takeExtension filePath
   in   throwE $ "Cannot load '" ++ ext ++ "' files."


---------------------------------------------------------------------------------------------------
-- | Load a Discus source module from a file.
--   The result is printed to @stdout@.
--   Any errors are thrown in the `ExceptT` monad.
cmdLoadDiscusSourceFromFile
        :: Config                               -- ^ Driver config.
        -> Store                                -- ^ Interface store.
        -> Bundle Int Tetra.Name Tetra.Error    -- ^ Tetra language bundle.
        -> FilePath                             -- ^ Module file path.
        -> ExceptT String IO ()

cmdLoadDiscusSourceFromFile config store bundle filePath
 = do
        -- Check that the file exists.
        exists  <- liftIO $ doesFileExist filePath
        when (not exists)
         $ throwE $ "No such file " ++ show filePath

        -- Call the compiler to build/load all dependent modules.
        cmdCompileRecursive config False store [filePath]

        -- Read in the source file.
        src     <- liftIO $ readFile filePath

        cmdLoadDiscusSourceFromString config store bundle
                (SourceFile filePath) src


---------------------------------------------------------------------------------------------------
-- | Load a Discus source module from a string.
--   The result is printed to @stdout@.
--   Any errors are thrown in the `ExceptT` monad.
cmdLoadDiscusSourceFromString
        :: Config                               -- ^ Driver config.
        -> Store                                -- ^ Interface store.
        -> Bundle Int Tetra.Name Tetra.Error    -- ^ Tetra language bundle.
        -> Source                               -- ^ Source of the code.
        -> String                               -- ^ Program module text.
        -> ExceptT String IO ()

cmdLoadDiscusSourceFromString config store bundle source str
 = withExceptT (renderIndent . vcat . map ppr)
 $ do
        let pmode   = prettyModeOfConfig $ configPretty config

        modTetra  <- DE.sourceLoadText config store source str

        errs     <- liftIO $ pipeCore modTetra
                 $ PipeCoreReannotate (\a -> a { annotTail = () })
                 [ PipeCoreSimplify   Tetra.fragment    (bundleStateInit  bundle)
                                                        (bundleSimplifier bundle)
                 [ PipeCoreOutput pmode SinkStdout ]]

        case errs of
         []     -> return ()
         _      -> throwE errs


---------------------------------------------------------------------------------------------------
-- | Load a Disciple Core module from a file.
--   The result is printed to @stdout@.
cmdLoadCoreFromFile
        :: Config               -- ^ Driver config.
        -> Language             -- ^ Core language definition.
        -> FilePath             -- ^ Module file path
        -> ExceptT String IO ()

cmdLoadCoreFromFile config language filePath
 = do
        -- Check that the file exists.
        exists  <- liftIO $ doesFileExist filePath
        when (not exists)
         $ throwE $ "No such file " ++ show filePath

        -- Read in the source file.
        src     <- liftIO $ readFile filePath

        cmdLoadCoreFromString config language (SourceFile filePath) src


---------------------------------------------------------------------------------------------------
-- | Load a Disciple Core module from a string.
--   The result it printed to @stdout@.
cmdLoadCoreFromString
        :: Config               -- ^ Driver config.
        -> Language             -- ^ Language definition
        -> Source               -- ^ Source of the code.
        -> String               -- ^ Program module text.
        -> ExceptT String IO ()

cmdLoadCoreFromString config language source str
 | Language bundle      <- language
 , fragment             <- bundleFragment   bundle
 = let
        pmode           = prettyModeOfConfig $ configPretty config

        pipeLoad
         = pipeText     (nameOfSource source) (lineStartOfSource source) str
         $ PipeTextLoadCore  fragment
                        (if configInferTypes config then C.Synth [] else C.Recon)
                        SinkDiscard
         [ PipeCoreReannotate (\a -> a { annotTail = () })
         [ PipeCoreSimplify  fragment (bundleStateInit bundle)
                                      (bundleSimplifier bundle)
         [ PipeCoreOutput    pmode SinkStdout ]]]

   in do
        errs    <- liftIO pipeLoad
        case errs of
         [] -> return ()
         es -> throwE $ renderIndent $ vcat $ map ppr es


---------------------------------------------------------------------------------------------------
-- | Parse the simplifier defined in this string,
--   and load it and all the inliner templates into the language bundle.
cmdLoadSimplifier
        :: Config               -- ^ Driver config.
        -> Language             -- ^ Language definition.
        -> String               -- ^ Simplifier specification.
        -> [FilePath]           -- ^ Modules to use as inliner templates.
        -> ExceptT String IO Language

cmdLoadSimplifier config language strSimpl fsTemplates
 | Language bundle      <- language
 = do   bundle' <- cmdLoadSimplifierIntoBundle config bundle strSimpl fsTemplates
        return  $ Language bundle'


-- | Parse the simplifier defined in this string,
--   and load it and all the inliner templates into the bundle
cmdLoadSimplifierIntoBundle
        :: (Ord n, Show n, NFData n, Pretty n, Pretty (err (AnTEC SourcePos n)))
        => Config               -- ^ Driver config.
        -> Bundle s n err       -- ^ Language bundle
        -> String               -- ^ Simplifier specification.
        -> [FilePath]           -- ^ Modules to use as inliner templates.
        -> ExceptT String IO (Bundle s n err)

cmdLoadSimplifierIntoBundle config bundle strSimpl fsTemplates
 | modules_bundle       <- bundleModules bundle
 , mkNamT               <- bundleMakeNamifierT bundle
 , mkNamX               <- bundleMakeNamifierX bundle
 , rules                <- bundleRewriteRules bundle
 , fragment             <- bundleFragment      bundle
 , readName             <- fragmentReadName    fragment
 = do
        -- Load all the modues that we're using for inliner templates.
        --  If any of these don't load then the 'cmdReadModule' function
        --  will display the errors.
        mModules
         <- liftM sequence
         $  mapM (liftIO . cmdReadModule config fragment)
                 fsTemplates

        modules_annot
         <- case mModules of
                 Nothing -> throwE $ "Cannot load inlined module."
                 Just ms -> return     $ ms

        -- Zap annotations on the loaded modules.
        -- Any type errors will already have been displayed, so we don't need
        -- the source position info any more.
        let zapAnnot annot = annot { annotTail = () }
        let modules_new    = map (reannotate zapAnnot) modules_annot

        -- Collect all definitions from modules
        let modules_all    = Map.elems modules_bundle ++ modules_new

        -- Wrap up the inliner templates and current rules into
        -- a SimplifierDetails, which we give to the Simplifier parser.
        let details
                = SimplifierDetails mkNamT mkNamX
                    [(n, reannotate zapAnnot rule) | (n, rule) <- Map.assocs rules]
                    modules_all

        -- Parse the simplifer string.
        case parseSimplifier readName details strSimpl of
         Left err    -> throwE $ renderIndent $ ppr err
         Right simpl -> return $ bundle { bundleSimplifier = simpl }

