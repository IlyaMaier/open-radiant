module Model.Core exposing
    ( Msg(..)
    , Model
    , PortModel
    , init
    , getContext
    , getOrigin, adaptSize
    , extractTimeShift, adaptTimeShift
    -- , getLayerModel, getLayerModels
    -- , updateLayer, updateLayerDef, updateLayerBlend, updateLayerWithItsModel, updateAllLayerModels
    , CreateGui
    , hasErrors, addError, addErrors
    , TimeDelta, Pos, Size
    )


import Array
import Array exposing (Array)
import Dict exposing (get)

import Browser.Navigation as Nav
import Url exposing (..)

import WebGL.Texture exposing (Texture)

import Algorithm.Gaussian as Gaussian exposing (Variety)

import Model.Layer.Layer exposing (..)
import Model.Layer.Layer as Layer exposing (Registry)
import Model.Layer.Def as Layer exposing (PortDef, Index)
import Model.Layer.Context as Layer exposing (Context)
import Model.Layer.Layers exposing (Layers)
import Model.AppMode exposing (..)
import Model.Error exposing (..)
import Model.SizeRule exposing (..)
import Model.SizeRule as SizeRule exposing (default)
import Model.Product as Product exposing (Product)
import Model.Product
import Model.Layer.Blend.Html as HtmlBlend
import Model.Layer.Blend.WebGL as WGLBlend

import Gradient exposing (..)

import Gui.Gui as Gui


sizeCoef : Float
sizeCoef = 1.0


timeShiftRange : Float
timeShiftRange = 500.0


type alias TimeNow = Float
type alias TimeDelta = Float


type alias Pos = (Int, Int)
type alias Size = (Int, Int)
type alias CreateGui = Model -> Gui.Model Msg


type Msg
    = Bang
    | ChangeMode AppMode
    | ApplyUrl Url
    | Animate TimeDelta
    | GuiMessage (Gui.Msg Msg)
    | Resize SizeRule
    | RequestFitToWindow
    | Locate Pos
    | Rotate Float
    | Import String
    | Export
    | ExportZip
    | TimeTravel Float
    | BackToNow
    | Pause
    | Continue
    | TriggerPause
    | HideControls
    | ChangeProduct Product
    | TurnOn Layer.Index
    | TurnOff Layer.Index
    -- | MirrorOn Layer.Index
    -- | MirrorOff Layer.Index
    -- | Configure Layer.Index Layer.Model
    | TriggerFeelLucky
    | ToLayer Layer.Index Layer.Msg
    | ChangeWGLBlend Layer.Index WGLBlend.Blend
    | AlterWGLBlend Layer.Index WGLBlend.BlendChange
    | ChangeHtmlBlend Layer.Index HtmlBlend.Blend
    --| ToFss Layer.Index FSS.Msg
    | Randomize
    | ApplyRandomizer PortModel
    | SavePng
    | AddError Error
    | AddErrors Errors
    | NoOp


type alias Model = -- TODO: Result Error { ... }
    { background: String
    , mode : AppMode
    , gui : Maybe (Gui.Model Msg)
    , paused : Bool
    , autoRotate : Bool
    , fps : Int
    , theta : Float
    , omega : Float
    , layers : Layers
    , size : SizeRule
    , origin : Pos
    , mouse : Pos
    , now : TimeNow
    , timeShift : TimeDelta
    , product : Product
    , controlsVisible : Bool
    , errors : Errors
    , navKey : Nav.Key
    , url : Maybe Url
    , registry : Layer.Registry
    -- voronoi : Voronoi.Config
    -- fractal : Fractal.Config
    -- , lights (taken from product)
    -- , material TODO
    }


type alias PortModel =
    { background : String
    , layers : List Layer.PortDef
    , mode : String
    , mouse : ( Int, Int )
    , now : Float
    , origin : (Int, Int)
    , size : (Int, Int)
    , sizeRule : Maybe String
    , theta : Float
    , omega : Float
    , product : String
    , palette : List String
    }


{-
init
    :  Nav.Key
    -> AppMode
    -> Layers.Initial
    -> CreateGui
    -> ( Model, Cmd Msg )
init navKey appMode initialLayers createGui =
    let
        emptyModel = initEmpty navKey appMode
        modelWithLayers =
            { emptyModel
            | layers = initialLayers
            }
    in
        { modelWithLayers
        | gui =
            case appMode of
                TronUi innerAppMode ->
                    Just <| createGui { modelWithLayers | mode = innerAppMode }
                _ -> Nothing
        }
-}


init : Nav.Key -> AppMode -> Model
init navKey mode =
    { background = "rgba(0, 0, 0, 0)" -- FIXME: get rid of this property thanks to Background layer
    , mode = mode
    , gui = Nothing
    , paused = False
    , autoRotate = False
    , fps = 0
    , theta = 0.1
    , omega = 0.0
    , layers = []
    , size = SizeRule.default
    , origin = ( 0, 0 )
    , mouse = ( 0, 0 )
    , now = 0.0
    , timeShift = 0.0
    --, range = ( 0.8, 1.0 )
    , product = Product.default
    , controlsVisible = True
    , errors = Errors [ ]
    , navKey = navKey
    , url = Nothing
    , registry = Layer.registry
    }


getContext : Model -> Layer.Context
getContext model =
    { viewport = ()
    , product = model.product
    , mode = model.mode
    , size = getRuleSizeOrZeroes model.size
    , palette = Product.getPalette model.product
    }


hasErrors : Model -> Bool
hasErrors model =
    case model.errors of
        Errors errorsList ->
            not <| List.isEmpty errorsList


addError : String -> Model -> Model
addError errorStr =
    addErrors (errorStr |> List.singleton |> Errors)


addErrors : Errors -> Model -> Model
addErrors (Errors newErrors) model =
    { model
    | errors =
        case model.errors of
            Errors currentErrors ->
                Errors <| currentErrors ++ newErrors
    }


noticeResult : (a -> Model -> Model) -> (x -> String) -> Result x a -> Model -> Model
noticeResult addValue errorToString result model =
    case result of
        Ok v -> model |> addValue v
        Err error -> model |> addError (errorToString error)


noticeResult_ : (a -> Model -> Model) -> (x -> String) -> Result (List x) a -> Model -> Model
noticeResult_ addValue errorToString result model =
    case result of
        Ok v -> model |> addValue v
        Err errors -> model |> addErrors (errors |> List.map errorToString |> Errors)


{-
tryToCreateLayers
     : List ( LayerKind, String, LayerModel )
    -> CreateLayer
    -> Result (List ( Int, LayerKind, String )) (List LayerDef)
tryToCreateLayers source createLayer =
    source
        |> List.indexedMap
            (\index (kind, name, layerModel) ->
                layerModel
                    |> createLayer kind
                    |> Maybe.map
                        (\layer ->
                            { kind = kind
                            , layer = layer
                            , name = name
                            , model = layerModel
                            , on = True
                            }
                        )
                    |> Result.fromMaybe (index, kind, name)
            )
        |> List.foldl
            (\layerResult mainResult ->
                case ( mainResult, layerResult ) of
                    ( Ok allDefs, Ok layerDef ) -> Ok <| layerDef :: allDefs
                    ( Ok _, Err layerError ) -> Err <| List.singleton layerError
                    ( Err allErrors, Ok _ ) -> Err allErrors
                    ( Err allErrors, Err layerError ) -> Err <| layerError :: allErrors
            )
            (Ok [])
-}


{-
replaceLayers
     : List ( LayerKind, String, LayerModel )
    -> CreateLayer
    -> Model
    -> Model
replaceLayers source createLayer model =
    model
        |> (tryToCreateLayers source createLayer |>
                noticeResult_
                    (\layers model_ -> { model_ | layers = layers })
                    (\(index, kind, name) ->
                        "Failed to create layer: (" ++ String.fromInt index ++ ", "
                            ++ encodeKind kind ++ ") "
                            ++ name))
-}


{-
getLayerModel : Layer.Index -> Model -> Maybe LayerModel
getLayerModel index model =
    model.layers
        |> Array.fromList
        |> Array.get index
        |> Maybe.map .model
-}


{-
getLayerModels : (LayerKind -> Bool) -> Model -> List LayerModel
getLayerModels test model =
    model.layers
        |> List.filter (\layer -> True)
        |> List.map .model
-}


{-
updateLayer
    :  Int
    -> (Layer -> LayerModel -> Layer)
    -> Model
    -> Model
updateLayer index f model =
    model |> updateLayerDef index
        (\layerDef ->
            { layerDef
            | layer = f layerDef.layer layerDef.model
            })
-}


{-
updateLayerDef
    :  Int
    -> (LayerDef -> LayerDef)
    -> Model
    -> Model
updateLayerDef index f model =
    let
        layersArray = Array.fromList model.layers
    in
        case layersArray |> Array.get index of
            Just layerDef ->
                { model
                | layers = layersArray
                    |> Array.set index (f layerDef)
                    |> Array.toList
                }
            Nothing -> model
-}


{-
updateLayerWithItsModel
    :  Int
    -> (( Layer, LayerModel ) -> ( Layer, LayerModel ))
    -> Model
    -> Model
updateLayerWithItsModel index f model =
    model |> updateLayerDef index
        (\layerDef ->
            case f (layerDef.layer, layerDef.model) of
                ( newLayer, newModel ) ->
                    { layerDef
                    | layer = newLayer
                    , model = newModel
                    })
-}


{-
updateAllLayerModels
    :  (Int -> LayerKind -> LayerModel -> LayerModel)
    -> Model
    -> Model
updateAllLayerModels f model =
    model.layers
        |> List.indexedMap
            (\layerIndex layerDef ->
                { layerDef
                | model = f layerIndex layerDef.kind layerDef.model
                }
            )
        |> (\layers -> { model | layers = layers }) -- .layers?
-}


{-
updateLayerBlend
    :  Int
    -> (WGLBlend.Blend -> Maybe WGLBlend.Blend)
    -> (HtmlBlend.Blend -> Maybe HtmlBlend.Blend)
    -> Model
    -> Model
updateLayerBlend index ifWebgl ifHtml model =
    model |> updateLayerDef index
        (\layerDef ->
            { layerDef
            | layer = case layerDef.layer of
                WebGLLayer webglLayer webglBlend ->
                    ifWebgl webglBlend
                        |> Maybe.withDefault webglBlend
                        |> WebGLLayer webglLayer
                HtmlLayer htmlLayer htmlBlend ->
                    ifHtml htmlBlend
                        |> Maybe.withDefault htmlBlend
                        |> HtmlLayer htmlLayer
            })
-}


getOrigin : Size -> Pos
getOrigin (width, height) =
    ( toFloat width  * (1 - sizeCoef) / 2 |> ceiling
    , toFloat height * (1 - sizeCoef) / 2 |> ceiling
    )


adaptSize : Size -> Size
adaptSize (width, height) =
    ( toFloat width  * sizeCoef |> floor
    , toFloat height * sizeCoef |> floor
    )


adaptTimeShift : String -> TimeDelta
adaptTimeShift v =
    let floatV = String.toFloat v
         |> Maybe.withDefault 0.0
    in (floatV - 50.0) / 100.0 * timeShiftRange


extractTimeShift : TimeDelta -> String
extractTimeShift v =
    (v / timeShiftRange * 100.0) + 50.0 |> String.fromFloat
