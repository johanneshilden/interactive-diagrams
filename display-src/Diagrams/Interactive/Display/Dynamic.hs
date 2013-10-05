{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE CPP                        #-}
module Diagrams.Interactive.Display.Dynamic where

import           Control.Applicative                  hiding (empty)
import           Control.Arrow                        ((***))
import           Control.Error
import           Control.Monad
import           Control.Monad.Cont                   hiding (mapM_)
import           Data.Default
import           Data.Foldable                        hiding (find, mapM_)
import           Data.Function
import           Data.Either
import           Data.Int
import           Data.IORef
import           Data.List                            (lookup,sortBy)
import           Data.Maybe
import           Data.Monoid
import           Data.Ord
import           Data.Serialize                       hiding (Result) 
import qualified Data.Text                            as T
import qualified Data.Text.Lazy                       as TL
import           Data.Word
import           Diagrams.Prelude                     hiding (Renderable, Result,
                                                       render, with, (<>))
import           GHC.Generics

import           Diagrams.Interactive.Display.Static
import           Diagrams.Interactive.Display.Orphans ()

#if __GHCJS__
    
import           Diagrams.Backend.GHCJS               hiding (Renderable,
                                                       render)
import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.Types
import           JavaScript.Canvas                    (getContext)
import           JavaScript.JQuery                    hiding (on)
import           JavaScript.JQuery.UI
import           JavaScript.JQuery.UI.Class
import           JavaScript.JQuery.UI.Internal
    
#endif    

import           Debug.Trace


newtype DynamicResult = DynamicResult T.Text
                      deriving (Generic, Show, Read, Monoid)

instance Serialize DynamicResult

-- | The end result of a function
type family Result x where
  Result (a -> b) = Result b
  Result a        = a

#if __GHCJS__

--------------------------------------------------
-- Main classes

-- | Values of type 'a' can be 'inputted'
class Input a where
  input :: JQuery     -- container;
        -> IO (IO (Either String a))  -- outer IO: prepare the container/form,
                      -- inner IO: get input
        
  inputList :: JQuery -> IO (IO (Either String [a]))
  default inputList :: (Output a)
                    => JQuery -> IO (IO (Either String [a]))
  inputList = defInputList

-- | Values of type 'a' can be 'outputted'
class Output a where
  output :: JQuery          -- container;
         -> IO (a -> IO ()) -- outer IO: prepare the container
                            -- IO () -- update the output
  default output :: (Display a)
                 => JQuery -> IO (a -> IO ())
  output w = output w >>= \f -> return (f . JSDisplay)  

-- | 'Interctive a b' means that it's possible to
-- interctively execute 'a' to reach 'b'
class (Result a ~ b) => Interactive a b where
  interactive :: JQuery -> IO (Either String a) -> IO (IO (Either String b))

-- | If we can reach 'c' from 'b' and if it's possible to input 'a',
-- then we can reach 'c' from '(a -> b)'
instance (Input a, Interactive b c) => Interactive (a -> b) c where
  interactive env f = do
    a <- input env
    -- f :: IO (String + (a -> b))
    -- ap :: m (a -> b) -> (m a -> m b)
    -- fmap ap f :: IO (String + a -> String + b)
    interactive env ((fmap ap f) <*> a) 

-- | Base case        
instance (Result a ~ a) => Interactive a a where
  interactive env x = return x

runInteractive :: (Interactive a b, Result a ~ b, Output b)
               => JQuery -> a -> IO ( IO () )
runInteractive env f = do
    val <- interactive env (return (Right f))
    o   <- output env
    return $ do
        v <- val
        case v of
            Left str -> error str
            Right b  -> o b

-- class Inputable a where
--     inputable :: JQuery -> ContT JQuery IO (JQuery, IO (Either String a))
--     default inputable :: (Generic a, GInputable (Rep a))
--                       => JQuery
--                       -> ContT JQuery IO (JQuery, IO (Either String a))
--     inputable jq = do
--         (jq', act) <- ginputable jq
--         jq'' <- lift $ postprocess jq
--         return (jq', tto act)
--       --   (id *** tto) <$> ginputable jq
--       where tto = liftM $ liftM to
--     inputableList :: JQuery -> ContT JQuery IO (JQuery, IO (Either String [a]))
--     default inputableList :: (Renderable a)
--                           => JQuery
--                           -> ContT JQuery IO (JQuery, IO (Either String [a]))
--     inputableList = defInputableList


newtype JSDisplay a = JSDisplay a

instance (Display a) => Output (JSDisplay a) where
    output w = do
        area <- select "<div>" >>= appendToJQuery w
        return $ \(JSDisplay a) -> void $ do
            setText (txt a) area
            wrapInner "<code>" area
      where
        txt a = displayText (display a)


defInputList :: (Output a, Input a)
             => JQuery
             -> IO (IO (Either String [a]))
defInputList jq = do
    area <- select "<div>" >>= appendToJQuery jq
    msgarea <- select "<p>" >>= appendToJQuery area
    listUl <- select "<ul class=\"sortable\">"
              >>= appendToJQuery area
    initWidget listUl Sortable def
    inpAct <- input area
    addBtn <- newBtn "Add"
               >>= appendToJQuery area
    listData <- newIORef (0::Int, []) -- list size, list itself
    onClick addBtn $ \_ -> do
        setText "" msgarea
        res <- inpAct
        case res of
            Left str -> void $
                let errmsg = "<font color=red>" <> (T.pack str) <> "</font>"
                in setHtml errmsg msgarea
            Right a -> void $ addItem a listUl listData
    let -- act :: IO (Either String [a])
        act = do
            (positions :: [Int]) <- mapM (liftM fromJust . fromJSRef . castRef)
                         =<< fromArray . castRef
                         =<< widgetMethod listUl Sortable "toArray"
            (_, elems) <- readIORef listData
            let lst = map fst
                    $ sortBy (compare `on` (Down . snd))
                    $ zip elems positions                    
            return (Right lst)
    return act
  where
    newBtn t = select $ "<button>" <> t <> "</button>"
    appendBtn t place = do
            btn <- newBtn t
            appendJQuery btn place
            initWidget btn Button with { buttonLabel = t }
            return btn
    addItem a ul dat = do
        (n, elems) <- readIORef dat
        li <- select ("<li class=\"ui-state-default\" id=\""
                             <> T.pack (show n)
                             <> "\">")
                   >>= appendToJQuery ul
        span <- select "<span class=\"ui-icon ui-icon-arrowthick-2-n-s\">"
                      >>= appendToJQuery li
        writeIORef dat (n+1, a:elems)
        join $ output li `ap` (return a)

-- --------------------------------------------------
-- -- Inputtable instances

inputString w = do
    inputBox <- newInputBox
    let act = return . T.unpack <$> getVal inputBox
    div <- select "<div>"
    appendJQuery inputBox div
        >>= appendToJQuery w
    return act
  where
    newInputBox = select "<input type=\"text\" class=\"input-xmedium\" />"

inputRead :: (String -> Either String a)
          -> JQuery
          -> IO (IO (Either String a))
inputRead readF w = do
    act <- inputString w
    let act' = (=<<) <$> pure readF <*> (act :: IO (Either String String))
    return act'

inputNum :: (Num a, Read a)
         => JQuery -> IO (IO (Either String a))
inputNum w = do
    act <- inputRead (readErr "Cannot read a number") w
    -- jq' <- lift $ find "input" jq
    -- initWidget jq' Spinner with { spinnerPage = 5 }
    return act


-- -- -- Useful for enums
-- -- inputableSelect :: [(T.Text, a)]
-- --                 -> JQuery
-- --                 -> ContT JQuery IO (JQuery, IO (Either String a))
-- -- inputableSelect options w = do
-- --     sel <- lift $ newSelect
-- --     lift $ mapM_ (appendToJQuery sel <=< (mkOpt . fst)) options
-- --     let act = maybe (Left "Unknown option") Right
-- --                .  (`lookup` options)
-- --               <$> getVal sel
-- --     div <- lift $ select "<div>"
-- --     lift $ appendJQuery sel div
-- --            >>= appendToJQuery w
-- --     return (div, act)
-- --   where
-- --     mkOpt s = select "<option>"
-- --               >>= setText s
-- --     newSelect = select "<select>"

instance Input Char where
    input     = inputRead (headErr "Cannot read a char")                
    inputList = inputString

instance (Input a, Output a, Display a) => Input [a] where
    input = inputList

instance Input Int     where { input = inputNum }
instance Input Int8    where { input = inputNum }
instance Input Int16   where { input = inputNum }
instance Input Int32   where { input = inputNum }
instance Input Int64   where { input = inputNum }
instance Input Word    where { input = inputNum }
instance Input Word8   where { input = inputNum }
instance Input Word16  where { input = inputNum }
instance Input Word32  where { input = inputNum }
instance Input Word64  where { input = inputNum }
instance Input Integer where { input = inputNum }
instance Input Float   where { input = inputNum }
instance Input Double  where { input = inputNum }

instance Input T.Text  where { input = inputRead (Right . T.pack)  }
instance Input TL.Text where { input = inputRead (Right . TL.pack) }

-- instance Inputable Bool where
--     inputable = inputableSelect [("True", True), ("False", False)]
-- instance Inputable Ordering where
--     inputable = inputableSelect [("<", LT), ("=", EQ), (">", GT)]    
-- instance (Inputable a, Inputable b,
--           Display a, Display b) => Inputable (Either a b)
-- instance (Inputable a, Display a) => Inputable (Maybe a)

-- instance (Inputable a, Inputable b,
--           Display a, Display b,
--           Renderable a, Renderable b)
--          => Inputable (a,b)
-- instance (Inputable a, Inputable b, Inputable c,
--           Display a, Display b, Display c,
--           Renderable a, Renderable b, Renderable c)
--          => Inputable (a,b,c)

-- --------------------------------------------------
-- -- Outputable instances

-- instance (b ~ Canvas) => Output (Diagram b R2) where
--     output w = do
--         let nm = "testcanvas"
--         canvas <- select $
--                   "<canvas id=\"" <> nm <> "\" width=\"200\" height=\"200\""
--                   <> "style=\"border:1px solid #d3d3d3;\">"
--                   <> "</canvas><br />"
--         area <- select "<div>" >>= appendJQuery canvas 
--         appendJQuery area w
--         return $ \d -> do
--             ctx <- getContext
--                    =<< indexArray 0 (castRef canvas)
--             renderDia Canvas (CanvasOptions (Dims 200 200) ctx) d

instance Output Int
instance Output Int8
instance Output Int16
instance Output Int32
instance Output Int64
instance Output Word
instance Output Word8
instance Output Word16
instance Output Word32
instance Output Word64
instance Output Integer
instance Output Float
instance Output Double
instance Output Char
instance Output T.Text
instance Output TL.Text
instance Output ()

instance (Output a, Display a) => Output [a]

instance Output Bool
instance Output Ordering
instance Display a => Output (Maybe a)
instance (Display a, Display b) => Output (Either a b)

-- instance (Display a, Display b)
--          => Output (a, b)
-- instance (Display a, Display b, Display c) => Output (a,b,c)

-- ------------------------------------------------------------
-- -- Helpers

onClick jq a = click a def jq

displayText (StaticResult drs) = foldMap result drs

-- -- -- * GInputable

-- -- type GInputCont f a = ContT JQuery IO (JQuery, IO (Either String (f a)))

-- -- class GInputable f where
-- --     ginputable :: JQuery
-- --                -> ContT JQuery IO (JQuery, IO (Either String (f a)))

-- -- instance GInputable U1 where
-- --     ginputable jq = do
-- --         codeblock <- lift $ select "<div><code></code></div>"
-- --         lift $ appendJQuery codeblock jq
-- --         return (codeblock, return (Right U1))

-- -- instance (Inputable c) => GInputable (K1 i c) where
-- --     ginputable = liftM (id *** ((fmap . fmap) K1)) . inputable

-- -- instance (GInputable f) => GInputable (M1 i c f) where
-- --     ginputable = liftM (id *** ((fmap . fmap) M1)) . ginputable

-- -- instance (GInputable f, GInputable g) => GInputable (f :*: g) where
-- --     ginputable jq = do
-- --         (inpArea1, inpAct1) <- ginputable jq
-- --         (inpArea2, inpAct2) <- ginputable jq
-- --         let act = runEitherT $ do
-- --                 res1 <- EitherT inpAct1
-- --                 res2 <- EitherT inpAct2
-- --                 return (res1 :*: res2)
-- --         return (jq, act)


-- -- instance (GInputable f, GInputable g)
-- --          => GInputable (f :+: g) where
-- --     ginputable jq = do
-- --         area <- lift $ do
-- --             sumDiv <- parent jq >>= find ".sum"
-- --             found <- (>0) <$> lengthArray (castRef sumDiv)
-- --             if found
-- --                 then return sumDiv
-- --                 else newDiv
-- --         (inpArea1, inpAct1) <- ginputable area
-- --         (inpArea2, inpAct2) <- ginputable area
-- --         lift $ initWidget area Accordion def
-- --         let act = do
-- --                 (Just n) <- fromJSRef =<< jq_getOptWidget "accordion" "active" area
-- --                 divs <- find "div" area
-- --                 len <- lengthArray (castRef divs)
-- --                 let mid = floor $ ((fromIntegral len)/2) - 1
-- --                 if (n::Int) <= mid
-- --                     then do
-- --                       (n'::JSRef Int) <- toJSRef (n+1)
-- --                       jq_setOptWidget "accordion" "active" n' area
-- --                       liftM L1 <$> inpAct1
-- --                     else do
-- --                       (n'::JSRef Int) <- toJSRef (n-1)
-- --                       jq_setOptWidget "accordion" "active" n' area
-- --                       liftM R1 <$> inpAct2
-- --         return (area, act)
-- --         where newDiv = do
-- --                   accord <- select "<div class=\"sum\">"
-- --                   appendJQuery accord jq
-- --                   return accord


-- -- | XXX: this is a hack
-- postprocess jq = do
--     sum <- find ".sum" jq
--     find "div" sum
--         >>= before "<h3>Option</h3>"
--     widgetMethod sum Accordion "destroy"
--     initWidget sum Accordion def
--     return sum    
    
#else

class Input a where
class Output a where

#endif    
