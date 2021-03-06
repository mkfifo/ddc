{-# OPTIONS_HADDOCK hide #-}

module DDC.Core.Interface.Store.Fetch where
import DDC.Core.Interface.Store.Base
import DDC.Core.Interface.Store.Construct
import DDC.Core.Module
import Data.IORef
import Data.Set                         (Set)
import qualified Data.Map.Strict        as Map


---------------------------------------------------------------------------------------------------
-- | Get metadata of interfaces currently in the store.
getMeta :: Store n -> IO [Meta]
getMeta store
 = do   mm      <- readIORef (storeMeta store)
        return  $ Map.elems mm


-- | Get names of the modules currently in the store.
getModuleNames :: Store n -> IO [ModuleName]
getModuleNames store
 = do   metas   <- readIORef (storeMeta store)
        return  $ Map.keys metas


---------------------------------------------------------------------------------------------------
-- | Lookup a module interface from the store.
lookupInterface :: Store n -> ModuleName -> IO (Maybe (Interface n))
lookupInterface store nModule
 = do   ints    <- readIORef (storeInterfaces store)
        return  $ Map.lookup nModule ints


-- | If we already have the given interface in the store then return
--   it directly, otherwise try to load it from the file system.
--
--   The load function checks whether the interface file is fresh relative
--   to the source files, so we don't need to check that again here.
--
fetchInterface
        :: (Ord n, Show n)
        => Store n -> ModuleName
        -> IO (Maybe (Interface n))

fetchInterface store nModule
 | Just load    <- storeLoadInterface store
 = let
        -- Check if we've already got it in the store.
        goCheck
         = do   iis     <- readIORef $ storeInterfaces store
                case Map.lookup nModule iis of
                 Just ii -> return (Just ii)
                 Nothing -> goLoad

        -- Try to load it from the file system.
        goLoad
         = do   result  <- load nModule
                case result of
                 Nothing  -> return Nothing
                 Just ii
                  -> do addInterface store ii
                        return (Just ii)
   in   goCheck

 | otherwise
 = return Nothing


---------------------------------------------------------------------------------------------------
-- | Extract the set of of transitively imported modules from the interface store.
--   Doing this will force load of needed interface files.
--
--   FIXME: we particularly want to avoid loading the complete interface
--          files just to get the list of .o files we need to link with.
--
--   Store the list of transitive imports directly in each module,
--   so we don't need to load the complete graph of imports.
--
fetchModuleTransitiveDeps
        :: (Ord n, Show n)
        => Store n -> ModuleName -> IO (Maybe (Set ModuleName))

fetchModuleTransitiveDeps store nModule
 = goCheck
 where
        -- Check if we've alredy got the info in the store.
        goCheck
         = do   deps   <- readIORef $ storeModuleTransitiveDeps store
                case Map.lookup nModule deps of
                 Just mns -> return $ Just mns
                 Nothing  -> goLoad

        -- Try to load the interface from the file system.
        goLoad
         = do   mInt <- fetchInterface store nModule
                case mInt of
                 Just ii  -> return $ Just $ moduleTransitiveDeps $ interfaceModule ii
                 Nothing  -> return Nothing


-- Caps -------------------------------------------------------------------------------------------
{- FIXME: load the caps.
importCapsOfInterface
        :: Ord n => Interface
        -> Map ModuleName (Map n (ImportCap n (Type n)))
= let
        importOfExport
-}

