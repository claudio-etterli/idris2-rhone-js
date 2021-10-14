||| This module provides the reference implementation of
||| `Control.Monad.Dom.Interface.MonadDom`.
module Control.Monad.Dom.DomIO

import Control.MonadRec
import Control.Monad.Dom.Event
import Control.Monad.Dom.Interface
import Control.WellFounded
import Data.Contravariant
import Data.MSF
import Data.IORef
import JS
import Text.Html
import Web.Dom
import Web.Html

%default total

--------------------------------------------------------------------------------
--          Implementation Utilities
--------------------------------------------------------------------------------

||| The environment needed to perform the necessary `MonadDom event`
||| operations: A mutable counter of natural number plus a string prefix
||| to generate unique IDs for reactive components, plus
||| an event handler to be registered at interactive elements.
public export
record DomEnv (event : Type) where
  constructor MkDomEnv
  pre      : String
  unique   : IORef Nat
  handler  : event -> JSIO ()

export
Contravariant DomEnv where
  contramap f  = record {handler $= (. f) }


-- how to listen to a DOMEvent
registerImpl : (ref : ElemRef t) -> DOMEvent e -> DomEnv e -> JSIO ()
registerImpl r@(MkRef {tag} _ id) de (MkDomEnv _ _ h) = do
  -- first, we look up the interactive HTML elemnt
  t <- strictGetHTMLElementById tag id
  -- next, we inspect the DOM event and register our handler
  -- accordingly
  case de of
    Input f      => oninput      t !> handle inputInfo f
    Change f     => onchange     t !> handle changeInfo f
    Click f      => onclick      t !> handle mouseInfo f
    DblClick f   => ondblclick   t !> handle mouseInfo f
    KeyDown f    => onkeydown    t !> handle keyInfo f
    KeyUp f      => onkeyup      t !> handle keyInfo f
    MouseDown f  => onmousedown  t !> handle mouseInfo f
    MouseUp f    => onmouseup    t !> handle mouseInfo f
    MouseEnter f => onmouseenter t !> handle mouseInfo f
    MouseLeave f => onmouseleave t !> handle mouseInfo f
    MouseOver f  => onmouseover  t !> handle mouseInfo f
    MouseOut f   => onmouseout   t !> handle mouseInfo f
    MouseMove f  => onmousemove  t !> handle mouseInfo f
  where handle : {0 a,b : _} -> (a -> JSIO b) -> (b -> Maybe e) -> a -> JSIO ()
        handle conv f va = conv va >>= maybe (pure ()) h . f

createId : DomEnv e -> JSIO String
createId (MkDomEnv pre u _) = do
  n <- readIORef u
  writeIORef u (S n)
  pure $ pre ++ show n

--------------------------------------------------------------------------------
--          Implementation
--------------------------------------------------------------------------------

||| Reference implementation of `MonadDom event`. This is just
||| a reader monad under the hood.
public export
record DomIO (event : Type) (io : Type -> Type) (a : Type) where
  constructor MkDom
  runDom : DomEnv event -> io a

export
mapEvent : {0 a : _} -> (ev1 -> ev2) -> DomIO ev1 io a -> DomIO ev2 io a
mapEvent f (MkDom runDom) = MkDom $ runDom . contramap f

export
env : Monad m => DomIO ev m (DomEnv ev)
env = MkDom pure

export
Functor io => Functor (DomIO ev io) where
  map f dom = MkDom (map f . dom.runDom)

export
Applicative io => Applicative (DomIO ev io) where
  pure v = MkDom $ \_ => pure v
  f <*> v = MkDom $ \ref => f.runDom ref <*> v.runDom ref

export
Monad io => Monad (DomIO ev io) where
  v >>= f = MkDom $ \ref => v.runDom ref >>= (`runDom` ref) . f


convR :  {0 a,e,b,st : Type}
      -> {0 rel : a -> a -> Type}
      -> (f : (v : a) -> st -> DomIO e m (Step rel v st b))
      -> (env : DomEnv e)
      -> (v : a)
      -> (ini : st)
      -> m (Step rel v st b)
convR f env v s1 = runDom (f v s1) env

export
MonadRec io => MonadRec (DomIO e io) where
  tailRecM f x ini acc =
    MkDom $ \env => tailRecM (convR f env) x ini acc

export
HasIO io => HasIO (DomIO ev io) where
  liftIO act = MkDom $ \_ => liftIO act

export
LiftJSIO io => LiftJSIO (DomIO ev io) where
  liftJSIO act = MkDom $ \_ => liftJSIO act

export %inline
LiftJSIO io => MonadDom ev (DomIO ev io) where
  registerEvent ref e = MkDom $ liftJSIO . registerImpl ref e
  uniqueId = MkDom $ liftJSIO . createId

--------------------------------------------------------------------------------
--          Reactimate
--------------------------------------------------------------------------------

-- initialEvent: If `Just e`, evaluate the given `MSF` once with `e` to
-- properly initialize all components.
-- idPrefix: prefix for uniqe ids
reactimateDom_ :  (initialEvent : Maybe ev)
               -> (idPrefix     : String)
               -> DomIO ev JSIO (MSF (DomIO ev JSIO) ev (), JSIO ())
               -> (idRef        : IORef Nat)
               -> JSIO (JSIO ())
reactimateDom_ ie pre mkMSF idRef = do

  -- here we will put the properevent handler, once everyting
  -- is ready. This is not Haskell, so we can't define
  -- the handler lazily and satisfy the totality checker at
  -- the same time
  hRef  <- newIORef {a = Maybe $ ev -> JSIO ()} Nothing

  -- the `DomEnv` needed to run `mkMSF`
  let env = MkDomEnv pre idRef $ \ev => do
              Just h <- readIORef hRef | Nothing => pure ()
              h ev

  -- effectfully create the monadic streaming function
  -- this will typically set up (a part of) the visible
  -- user interface, hence the need for `env` with its
  -- event handler and ability to generate unique IDs
  (sf,cl) <- mkMSF.runDom env

  -- the current application state consists of the current
  -- monadic streaming function, which will be stored in a
  -- mutable ref
  sfRef  <- newIORef sf

  -- we can now implement the *real* event handler:
  -- when an event is being fired, we evaluate the current
  -- MSF and put the resulting continuation in the mutable ref
  -- to be used when the next event occurs.
  let handle : ev -> JSIO ()
      handle = \e => do
        sf1      <- readIORef sfRef
        (_, sf2) <- runDom (step sf1 e) env
        writeIORef sfRef sf2

  -- we need to register the correct event handler, otherwise
  -- nothing will run
  writeIORef hRef . Just $ handle

  -- finally, we run the initial event (if any)
  traverse_ handle ie

  pure cl

||| Sets up an event handler to invoke the given `MSF`
||| whenever the handler is called with a new event
||| value.
|||
||| Uses `idPrefix` as a prefix when generating unique IDs.
||| If you need to properly setup all components by running
||| the MSF with an initial event, use `reactimateDomIni`.
export %inline
reactimateDom : (idPrefix : String)
              -> DomIO ev JSIO (MSF (DomIO ev JSIO) ev (), JSIO ())
              -> JSIO (JSIO ())
reactimateDom pre sf = newIORef 0 >>= reactimateDom_ Nothing pre sf

||| Sets up an event handler to invoke the given `MSF`
||| whenever the handler is called with a new event
||| value.
|||
||| Uses the ID prefix and unique counter generator from
||| the calling `DomIO` environment.
export %inline
reactimateInDom :  DomIO ev JSIO (MSF (DomIO ev JSIO) ev (), JSIO ())
                -> DomIO ev2 JSIO (JSIO ())
reactimateInDom sf =
  MkDom $ \env => reactimateDom_ Nothing env.pre sf env.unique

||| Sets up an event handler to invoke the given `MSF`
||| whenever the handler is called with a new event
||| value.
|||
||| Uses `idPrefix` as a prefix when generating unique IDs.
|||
||| A first evaluation step is run with the given event value
||| to properly setup all components.
export %inline
reactimateDomIni :  ev
                 -> (idPrefix : String)
                 -> DomIO ev JSIO (MSF (DomIO ev JSIO) ev (), JSIO ())
                 -> JSIO (JSIO ())
reactimateDomIni e pre sf =
  newIORef 0 >>= reactimateDom_ (Just e) pre sf

||| Sets up an event handler to invoke the given `MSF`
||| whenever the handler is called with a new event
||| value.
|||
||| Uses the ID prefix and unique counter generator from
||| the calling `DomIO` environment.
|||
||| A first evaluation step is run with the given event value
||| to properly setup all components.
export %inline
reactimateInDomIni :  ev
                   -> DomIO ev JSIO (MSF (DomIO ev JSIO) ev (), JSIO())
                   -> DomIO ev2 JSIO (JSIO ())
reactimateInDomIni v sf =
  MkDom $ \env => reactimateDom_ (Just v) env.pre sf env.unique
