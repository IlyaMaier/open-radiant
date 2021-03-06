module Model.Layer.Def exposing
    ( DefId, Index, JsIndex, Opacity(..)
    , makeIndex, getIndex
    , indexToString, indexToJs
    , Kind(..), Def
    , unit
    , passUpdate, bypass, singleView, initWith, noEncode, decodeTo, noSubscriptions
    )

import Gui.Def exposing (Nest)

import Json.Decode as D
import Json.Encode as E

import Model.Layer.Blend.WebGL as WebGL

import Model.Layer.Context exposing (Context)
import Model.Layer.Broadcast as Broadcast exposing (Msg)


type alias DefId = String


type Index = Index Int
type alias JsIndex = Int -- index for ports


type Opacity = Opacity Float


type Kind
    = Html
    | WebGL
    | Canvas
    | JS


type alias Def model view msg blend =
    { id : DefId
    , kind : Kind
    , init : Index -> Context -> ( model, Cmd msg )
    , encode : Context -> model -> E.Value
    , decode : Context -> D.Decoder model
    , update : Index -> Context -> msg -> model -> ( model, Cmd msg )
    -- maybe having Cmd to absorb to broadcast message is enough
    , absorb : Index -> Context -> Broadcast.Msg -> model -> ( model, Cmd msg )
    , view : Index -> Context -> ( Maybe blend, Opacity ) -> model -> view
    , subscribe : Context -> model -> Sub ( Index, msg )
    , gui : Maybe (Index -> model -> Nest msg)
    }


unit : Def () () () ()
unit =
    { id = "unit"
    , kind = JS
    , init = initWith ()
    , encode = noEncode
    , decode = decodeTo ()
    , update = passUpdate
    , absorb = bypass
    , view = singleView ()
    , subscribe = noSubscriptions
    , gui = Nothing
    }


passUpdate : Index -> Context -> msg -> model -> ( model, Cmd msg )
passUpdate = \_ _ _ model -> ( model, Cmd.none )


bypass : Index -> Context -> Broadcast.Msg -> model -> ( model, Cmd msg )
bypass = \_ _ _ model -> ( model, Cmd.none )


singleView : view -> Index -> Context -> ( Maybe blend, Opacity ) -> model -> view
singleView v = \_ _ _ _ -> v


initWith : model -> Index -> Context -> ( model, Cmd msg )
initWith m = \_ _ -> ( m, Cmd.none )


noEncode : Context -> model -> E.Value
noEncode = \_ _ -> E.object []


decodeTo : model -> Context -> D.Decoder model
decodeTo v = \_ -> D.succeed v


noSubscriptions : Context -> model -> Sub ( Index, msg )
noSubscriptions = \_ _ -> Sub.none


makeIndex : Int -> Index
makeIndex = Index


getIndex : Index -> Int
getIndex (Index index) = index


indexToString : Index -> String
indexToString = getIndex >> String.fromInt


indexToJs : Index -> JsIndex
indexToJs = getIndex


empty : DefId -> Kind -> model -> view -> Def model view () ()
empty id kind initialModel initalView =
    { id = id
    , kind = kind
    , init = initWith initialModel
    , encode = noEncode
    , decode = decodeTo initialModel
    , subscribe = noSubscriptions
    , update = passUpdate
    , absorb = bypass
    , view = singleView initalView
    , gui = Nothing
    }
