module Rhone.Canvas.Style

import Data.SOP
import JS
import Text.CSS.Color
import Text.CSS.Render
import Web.Html

%default total

public export
data Style : Type where
  Fill         : Color -> Style
  Stroke       : Color -> Style
  LineWidth    : Double -> Style
  Font         : String -> Style
  Direction    : CanvasDirection -> Style
  TextAlign    : CanvasTextAlign -> Style
  TextBaseline : CanvasTextBaseline -> Style

--------------------------------------------------------------------------------
--          IO
--------------------------------------------------------------------------------

export
apply : CanvasRenderingContext2D -> Style -> JSIO ()
apply ctxt (Fill c)         = fillStyle ctxt    .= inject (render c)
apply ctxt (Stroke c)       = strokeStyle ctxt  .= inject (render c)
apply ctxt (LineWidth v)    = lineWidth ctxt    .= v
apply ctxt (Font v)         = font ctxt         .= v
apply ctxt (Direction v)    = direction ctxt    .= v
apply ctxt (TextAlign v)    = textAlign ctxt    .= v
apply ctxt (TextBaseline v) = textBaseline ctxt .= v
