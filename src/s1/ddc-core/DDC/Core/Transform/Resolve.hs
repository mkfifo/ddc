
-- | Resolve elaborations in a module.
module DDC.Core.Transform.Resolve
        ( resolveModule
        , Error (..))
where
import DDC.Core.Transform.Resolve.Context
import DDC.Core.Transform.Resolve.Build
import DDC.Core.Transform.Resolve.Base
import DDC.Core.Interface.Oracle                (Oracle)
import qualified DDC.Core.Interface.Oracle      as Oracle
import DDC.Core.Fragment                        (Profile (..))
import DDC.Core.Codec.Text.Pretty               hiding ((<$>))
import Control.Monad.IO.Class


-- | Resolve elaborations in a module.
resolveModule
        :: (Ord n, Pretty n, Show n)
        => Profile n -> Oracle n -> Module a n
        -> IO (Either (Error a n) (Module a n))

resolveModule profile oracle mm
 = runExceptT $ resolveModuleM profile oracle mm


-- | Resolve elaborations in a module.
resolveModuleM
        :: (Ord n, Pretty n, Show n)
        => Profile n -> Oracle n -> Module a n
        -> S a n (Module a n)

resolveModuleM profile oracle mm
 = do
        -- Make the imported modules visible to the resolver.
        oracle' <- liftIO $ Oracle.importModules oracle
                $  moduleImportModules mm

        -- Build the initial context.
        ctx     <- makeContextOfModule profile oracle' mm

        -- Decend into the expression.
        --  We push local bindings onto the context as we go,
        --  and resolve elaborations using all bindings currently in scope.
        xBody'  <- resolveExp ctx (moduleBody mm)

        -- Return the resolved module.
        return  $ mm { moduleBody = xBody' }


-- | Resolve elaborations in an expression.
resolveExp
        :: (Ord n, Pretty n, Show n)
        => Context n
        -> Exp a n -> S a n (Exp a n)

resolveExp !ctx xx
 = case xx of
        -- Try to resolve an elaboration.
        XApp a (XPrim _ PElaborate) (RType tWant)
         -> contextResolve a ctx tWant

        -- Boilerplate traversal.
        XPrim{} -> return xx
        XCon{}  -> return xx
        XVar{}  -> return xx

        XAbs  a p x
         -> XAbs  a p <$> resolveExp (contextPushParam p ctx) x

        XApp  a x1 a2
         -> XApp  a   <$> resolveExp ctx x1
                      <*> resolveArg ctx a2

        XLet  a lts x
         -> XLet  a   <$> resolveLts ctx lts
                      <*> resolveExp (contextPushLets lts ctx) x

        XCase a x alts
         -> XCase a   <$> resolveExp ctx x
                      <*> mapM (resolveAlt ctx) alts

        XCast a c x
         -> XCast a c <$> resolveExp ctx x


-- | Resolve elaborations in an argument.
resolveArg
        :: (Ord n, Pretty n, Show n)
        => Context n
        -> Arg a n -> S a n (Arg a n)

resolveArg !ctx arg
 = case arg of
        RType{}         -> return arg
        RTerm x         -> RTerm     <$> resolveExp ctx x
        RWitness{}      -> return arg
        RImplicit arg'  -> RImplicit <$> resolveArg ctx arg'


-- | Resolve elaborations in some let bindings.
resolveLts
        :: (Ord n, Pretty n, Show n)
        => Context n
        -> Lets a n -> S a n (Lets a n)

resolveLts !ctx lts
 = case lts of
        LLet b x
         -> LLet b <$> resolveExp ctx x

        LRec bxs
         -> do  let (bs, xs)    = unzip bxs
                let ctx'        = contextPushBinds bs ctx
                xs'             <- mapM (resolveExp ctx') xs
                let bxs'        = zip bs xs'
                return $ LRec bxs'

        LPrivate{}      -> return lts


-- | Resolve elaborations in an alternative.
resolveAlt
        :: (Ord n, Pretty n, Show n)
        => Context n
        -> Alt a n -> S a n (Alt a n)

resolveAlt !ctx alt
 = case alt of
        AAlt w x        -> AAlt w <$> resolveExp (contextPushPat w ctx) x

