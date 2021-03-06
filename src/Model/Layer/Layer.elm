port module Model.Layer.Layer exposing (..)


import Html exposing (Html)
import Html as H exposing (..)

import Array exposing (Array)

import Dict
import Dict exposing (Dict)

import Json.Decode as D
import Json.Encode as E

import Random

import WebGL as WebGL

import Model.Layer.Def exposing (..)
import Model.Layer.Def as Def exposing (Index)

import Model.Layer.Blend.Html as Html exposing (Blend)
import Model.Layer.Blend.Html as HtmlBlend exposing (random)
import Model.Layer.Blend.WebGL as WebGL exposing (Blend, BlendChange)
import Model.Layer.Blend.WebGL as WebGLBlend exposing (random)

import Layer.Background.Background as Background exposing (..)
import Layer.Cover.Cover as Cover exposing (..)
import Layer.NativeMetaballs.NativeMetaballs as NativeMetaballs exposing (..)


type ZOrder = ZOrder Int


type Layer =
    Layer
        { index : Int
        , visibility : Visibility
        , blend : Blend
        , zOrder : Int
        , opacity : Float
        }
        Model


type View
    = ToHtml (Html Msg)
    | ToWebGL WebGL.Entity


-- type alias CreateLayer = Kind {- -> Model -} -> Maybe Layer


type Blend
    = ForWebGL WebGL.Blend
    | ForHtml Html.Blend
    | NoBlend


type Visibility
    = Visible
    | Hidden
    | Locked


type Model
    = Background Background.Model
    | Cover Cover.Model
    | NativeMetaballs NativeMetaballs.Model
    | Unknown
    -- TODO: add mirrored FSS


type Msg
    = BackgroundMsg Background.Msg
    | CoverMsg Cover.Msg
    | NativeMetaballsMsg NativeMetaballs.Msg


type Adaptation model view msg blend =
    Adaptation
        { convertModel : model -> Model
        , convertMsg : msg -> Msg
        , extractModel : Model -> Maybe model
        , extractMsg : Msg -> Maybe msg
        , convertView : view -> View
        -- , extractView : View -> Maybe view
        -- , convertBlend : blend -> Blend
        , extractBlend : Blend -> Maybe blend
        }


type alias Registry =
    { byId : DefId -> Maybe (Def Model View Msg Blend)
    , byModel : Model -> Maybe (Def Model View Msg Blend)
    , byMsg : Msg -> Maybe (Def Model View Msg Blend)
    }



-- kinda Either, but for ports:
--    ( Just WebGLBlend, Nothing ) --> WebGL Blend
--    ( Nothing, Just String ) --> HTML Blend
--    ( Nothing, Nothing ) --> None
--    ( Just WebGLBlend, Just String ) --> ¯\_(ツ)_/¯
type alias PortBlend =
    ( Maybe WebGL.Blend, Maybe String )


type alias PortLayer =
    { def : String
    , kind : String
    , blend : PortBlend
    , visible : String
    , opacity : Float
    , zOrder : Int
    , index : Int
    , isOn : Bool
    , model : E.Value
    }


layer : Index -> ZOrder -> Visibility -> Blend -> Model -> Layer
layer index (ZOrder zOrder) visibility blend model =
    Layer
        { visibility = visibility
        , blend = blend
        , zOrder = zOrder
        , index = getIndex index
        , opacity = 1.0
        }
        model


isVisible : Layer -> Bool
isVisible (Layer { visibility } _)  = visibility /= Hidden


getId : Layer -> Maybe DefId
getId (Layer _ model) =
    registry.byModel model |> Maybe.map .id


isDef : DefId -> Layer -> Bool
isDef idToCheck someLayer =
    case getId someLayer of
        Just someId -> someId == idToCheck
        Nothing -> False


getModel : Layer -> Model
getModel (Layer _ model) =
    model


isOn : Layer -> Bool
isOn (Layer { visibility } _) =
    case visibility of
        Visible -> True
        Locked -> True
        Hidden -> False


hide : Layer -> Layer
hide (Layer cfg model) =
    Layer
        { cfg
        | visibility = Hidden
        }
        model


show : Layer -> Layer
show (Layer cfg model) =
    Layer
        { cfg
        | visibility = Visible
        }
        model


lock : Layer -> Layer
lock (Layer cfg model) =
    Layer
        { cfg
        | visibility = Locked
        }
        model


unlock : Layer -> Layer
unlock = show


replaceModel : Model -> Layer -> Layer
replaceModel newModel (Layer cfg _) =
    Layer cfg newModel


changeBlend : Blend -> Layer -> Layer
changeBlend newBlend (Layer cfg model) =
    Layer
        { cfg
        | blend = newBlend
        }
        model


changeOpacity : Float -> Layer -> Layer
changeOpacity value (Layer cfg model) =
    Layer
        { cfg
        | opacity = value
        }
        model


alterBlend : (Blend -> Blend) -> Layer -> Layer
alterBlend changeF (Layer ({ blend } as cfg) model) =
    Layer
        { cfg
        | blend = changeF blend
        }
        model


alterWebGlBlend : WebGL.BlendChange -> Layer -> Layer
alterWebGlBlend changeF =
    alterBlend
        (\blend ->
            case blend of
                ForWebGL wglBlend -> changeF wglBlend |> ForWebGL
                _ -> blend
        )

extractHtmlBlend : Blend -> Maybe Html.Blend
extractHtmlBlend blend =
    case blend of
        ForHtml htmlBlend -> Just htmlBlend
        _ -> Nothing


extractWebGLBlend : Blend -> Maybe WebGL.Blend
extractWebGLBlend blend =
    case blend of
        ForWebGL webGlBlend -> Just webGlBlend
        _ -> Nothing


adapt
     : Adaptation model view msg blend
    -> Def model view msg blend
    -> Def Model View Msg Blend
adapt
    (Adaptation a)
    source =
    let
        adaptUpdateTuple f =
            f |> Tuple.mapFirst a.convertModel
              |> Tuple.mapSecond (Cmd.map a.convertMsg)
    in
        { id = source.id
        , kind = source.kind
        -- , init = adaptUpdateTuple << source.init
        , init =
            \index ctx ->
                adaptUpdateTuple <| source.init index ctx
        , encode =
            \ctx layerModel ->
                case a.extractModel layerModel of
                    Just m -> source.encode ctx m
                    Nothing -> E.string <| "wrong encoder for " ++ source.id
        , decode = D.map a.convertModel << source.decode
        , update =
            \index ctx mainMsg layerModel ->
                case ( a.extractMsg mainMsg, a.extractModel layerModel ) of
                    ( Just msg, Just model ) ->
                        adaptUpdateTuple <|
                            source.update index ctx msg model
                    _ -> -- FIXME: return Maybe/Result for the case when message / model doesn't match
                        adaptUpdateTuple <| source.init index ctx
        , view =
            \index ctx ( maybeBlend, opacity ) layerModel  ->
                case a.extractModel layerModel of
                    Just model ->
                        a.convertView
                            <| source.view
                                index
                                ctx
                                ( a.extractBlend <| Maybe.withDefault NoBlend maybeBlend
                                , opacity
                                )
                                model
                    Nothing -> ToHtml <| H.div [] []
        , subscribe =
            \ctx layerModel ->
                case a.extractModel layerModel of
                    Just model ->
                        source.subscribe ctx model
                            |> Sub.map (Tuple.mapSecond a.convertMsg)
                    Nothing -> Sub.none
        , absorb =
            \index ctx broadcastMsg layerModel ->
                case ( a.extractModel layerModel ) of
                    Just model ->
                        adaptUpdateTuple <|
                            source.absorb index ctx broadcastMsg model
                    _ -> -- FIXME: return Maybe/Result for the case when message / model doesn't match
                        adaptUpdateTuple <| source.init index ctx
        , gui = Nothing -- FIXME
        }


randomStats : Blend -> Random.Generator ( Blend, Opacity )
randomStats curBlend =
    let
        randomBlend =
            case curBlend of
                NoBlend -> Random.constant NoBlend
                ForWebGL _ ->
                    WebGLBlend.random
                        |> Random.map ForWebGL
                ForHtml _ ->
                    HtmlBlend.random
                        |> Random.map ForHtml
        randomOpacity =
            Random.float 0.2 1
                |> Random.map Opacity
    in
        Random.map2
            Tuple.pair
            randomBlend
            randomOpacity


register
    :  Def model view msg blend
    -> Adaptation model view msg blend
    -> Registry
    -> Registry
register def (Adaptation adaptation) registerAt =
    let
        adaptedDef = adapt (Adaptation adaptation) def
    in
        { registerAt
        | byId = \otherId ->
            if otherId == def.id
                then Just adaptedDef
                else registerAt.byId otherId
        , byModel = \model ->
            case adaptation.extractModel model of
                Just _ -> Just adaptedDef
                _ -> registerAt.byModel model
        , byMsg = \msg ->
            case adaptation.extractMsg msg of
                Just _ -> Just adaptedDef
                _ -> registerAt.byMsg msg
        }


htmlAdaptation
    :  (model -> Model)
    -> (msg -> Msg)
    -> (Model -> Maybe model)
    -> (Msg -> Maybe msg)
    -> Adaptation model (Html msg) msg Html.Blend
htmlAdaptation
    convertModel
    convertMsg
    extractModel
    extractMsg =
    (Adaptation
            { convertModel = convertModel
            , convertMsg = convertMsg
            , extractModel = extractModel
            , extractMsg = extractMsg
            , convertView = (\htmlView ->
                Html.map convertMsg htmlView
                    |> ToHtml)
            , extractBlend =
                extractHtmlBlend
            }
        )


registry : Registry
registry =
    { byId = always Nothing
    , byModel = always Nothing
    , byMsg = always Nothing
    }

    |> register Background.def
        (htmlAdaptation
            Background
            BackgroundMsg
            (\model ->
                case model of
                    Background bgModel -> Just bgModel
                    _ -> Nothing)
            (\msg ->
                case msg of
                    BackgroundMsg bgMsg -> Just bgMsg
                    _ -> Nothing)
        )

    |> register Cover.def
        (htmlAdaptation
            Cover
            CoverMsg
            (\model ->
                case model of
                    Cover coverModel -> Just coverModel
                    _ -> Nothing)
            (\msg ->
                case msg of
                    CoverMsg coverMsg -> Just coverMsg
                    _ -> Nothing)
        )

    |> register NativeMetaballs.def
        (htmlAdaptation
            NativeMetaballs
            NativeMetaballsMsg
            (\model ->
                case model of
                    NativeMetaballs nmModel -> Just nmModel
                    _ -> Nothing)
            (\msg ->
                case msg of
                    NativeMetaballsMsg nmMsg -> Just nmMsg
                    _ -> Nothing)
        )


encodeBlend : Blend -> String
encodeBlend blend =
    case blend of
        ForWebGL webglBlend ->
            WebGLBlend.encodeOne webglBlend
        ForHtml htmlBlend ->
            HtmlBlend.encode htmlBlend
        _ -> "unknown"


encodePortBlend : Blend -> PortBlend
encodePortBlend blend =
    case blend of
        ForWebGL webglBlend ->
            ( Just webglBlend, Nothing )
        ForHtml htmlBlend ->
            ( Nothing, HtmlBlend.encode htmlBlend |> Just )
        _ ->
            ( Nothing, Nothing )


encodeBlendDesc : Blend -> String
encodeBlendDesc blend =
    case blend of
        ForWebGL webglBlend ->
            webglBlend
                |> WebGLBlend.encodeHumanOne
                    { delim = "; ", space = "> " }
        ForHtml htmlBlend ->
            HtmlBlend.encode htmlBlend
        _ -> "unknown"


port updateLayerStats :
    { layer: JsIndex
    , blend : PortBlend
    , opacity : Float
    }
    -> Cmd msg
