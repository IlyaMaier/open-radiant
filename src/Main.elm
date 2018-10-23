port module Main exposing (main)

import Array exposing (Array)
import Html exposing (Html, text, div, span, input)
import Html.Attributes as H
    exposing (class, width, height, style, class, type_, min, max, value, id)
import Html.Events exposing (on, onInput, onMouseUp, onClick)
import AnimationFrame
import Time exposing (Time)
import Window
import Mouse exposing (clicks, moves, Position)
import Task exposing (Task)
import WebGL exposing (Mesh, Option)
import WebGL.Settings.Blend as B
import WebGL.Settings exposing (sampleAlphaToCoverage)
import WebGL.Settings.DepthTest as DepthTest

import Viewport exposing (Viewport)
import WebGL.Blend as WGLBlend
import Svg.Blend as SVGBlend
import Controls
import ImportExport as IE exposing (EncodedState)
import Product exposing (Product)
import Product as Product

import Layer.Lorenz as Lorenz
import Layer.Fractal as Fractal
import Layer.Voronoi as Voronoi
import Layer.FSS as FSS
import Layer.Template as Template
import Layer.JbText as JbText
import Layer.SVGImage as SVGImage
import Layer.Vignette as Vignette


type alias LayerIndex = Int

type alias Size = (Int, Int)
type alias Pos = (Int, Int)


type LayerKind
    = Lorenz
    | Fractal
    | Template
    | Voronoi
    | Fss (Maybe FSS.Clip)
    | Text
    | SvgImage
    | Vignette


type LayerConfig
    -- FIXME: use type variable for that, or just a function!
    = LorenzConfig Lorenz.Config
    | FractalConfig Fractal.Config
    | VoronoiConfig Voronoi.Config
    | FssConfig FSS.Model
    | MirroredFssConfig FSS.Model
    | TemplateConfig Template.Config


type Layer
    -- FIXME: use type variable for that, or just a function!
    = LorenzLayer Lorenz.Config WGLBlend.Blend Lorenz.Mesh
    | FractalLayer Fractal.Config WGLBlend.Blend Fractal.Mesh
    | VoronoiLayer Voronoi.Config WGLBlend.Blend Voronoi.Mesh
    | TemplateLayer Template.Config WGLBlend.Blend Template.Mesh
    | FssLayer FSS.Model WGLBlend.Blend (Maybe FSS.SerializedScene) FSS.Mesh
    | VignetteLayer Vignette.Config WGLBlend.Blend
    | TextLayer SVGBlend.Blend
    | SvgImageLayer SVGBlend.Blend
    | Unknown
    -- | CanvasLayer (\_ -> )


initialLayers : List LayerKind
initialLayers =
    [ Fss <| Nothing
    , Fss <| Just (0.5, 1)
    -- , Vignette
    , Text
    , SvgImage
    ]


type alias Model =
    { paused : Bool
    , autoRotate : Bool
    , fps : Int
    , theta : Float
    , layers : List Layer
    , size : Size
    , origin : Pos
    , mouse : Pos
    , now : Time
    , timeShift : Time
    , faces : ( Int, Int )
    , range : ( Float, Float )
    , amplitude : FSS.Amplitude
    , lightSpeed : Int
    , product : Product
    , vignette : Float
    -- , lights (taken from product)
    -- , material TODO
    }


type alias FssBuildOptions = GuiConfig

type alias GuiConfig =
    { product : String
    , palette : List String
    , layers : List
        { kind: String
        , blend : IE.PortBlend
        , webglOrSvg: String
        }
    , size : ( Int, Int )
    , facesX : Int
    , facesY : Int
    , lightSpeed: Int
    , vignette: Float
    , amplitude : FSS.AmplitudeChange
    , customSize : Maybe (Int, Int)
    }


type Msg
    = Bang
    | Animate Time
    | Resize Window.Size
    | Configure LayerIndex LayerConfig
    | ChangeWGLBlend LayerIndex WGLBlend.Blend
    | ChangeSVGBlend LayerIndex SVGBlend.Blend
    | RebuildFss LayerIndex FSS.SerializedScene
    --| RebuildOnClient LayerIndex FSS.SerializedScene
    | Rotate Float
    | ChangeFacesX Int
    | ChangeFacesY Int
    | ChangeLightSpeed Int
    | ChangeVignette Float
    | ChangeAmplitude FSS.AmplitudeChange
    | ChangeProduct Product
    | Locate Position
    | Import EncodedState
    | Export
    | ExportZip
    | TimeTravel Float
    | BackToNow
    | Pause
    | Continue
    | TriggerPause
    | NoOp


sizeCoef : Float
sizeCoef = 1.0


init : ( Model, Cmd Msg )
init =
    ( { paused = False
      , autoRotate = False
      , fps = 0
      , theta = 0.1
      , layers = initialLayers |> List.map createLayer
      , size = ( 1200, 1200 )
      , origin = ( 0, 0 )
      , mouse = FSS.defaultMouse
      , now = 0.0
      , timeShift = 0.0
      , faces = FSS.defaultFaces
      , range = ( 0.8, 1.0 )
      , amplitude = FSS.defaultAmplitude
      , lightSpeed = FSS.defaultLightSpeed
      , product = Product.JetBrains
      , vignette = 1.0
      }
    , Cmd.batch
        [ Task.perform Resize Window.size
        ]
    )


updateAndRebuildFssWith : Model -> ( Model, Cmd Msg )
updateAndRebuildFssWith model =
    ( model, model |> extractFssBuildOptions |> requestFssRebuild )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of

        Bang ->
            ( model
            , model |> prepareGuiConfig |> startGui
            )

        Animate dt ->
            (
                { model
                 | fps = floor (1000 / dt)
                 , theta = if not model.autoRotate
                              then model.theta + dt / 4000
                              else model.theta
                 , now = if not model.paused
                            then model.now + dt + model.timeShift
                            else model.now
                 }
            , Cmd.none
            )

        Configure index config ->
            ( model |> updateLayer index
                (\layer ->
                    case ( layer, config ) of
                        -- FIXME: simplify
                        ( LorenzLayer _ curBlend _, LorenzConfig lorenzConfig ) ->
                            LorenzLayer lorenzConfig curBlend (lorenzConfig |> Lorenz.build)
                        ( FractalLayer _ curBlend _, FractalConfig fractalConfig ) ->
                            FractalLayer fractalConfig curBlend (fractalConfig |> Fractal.build)
                        ( VoronoiLayer _ curBlend _, VoronoiConfig voronoiConfig ) ->
                            VoronoiLayer voronoiConfig curBlend (voronoiConfig |> Voronoi.build)
                        ( FssLayer _ curBlend maybeScene _, FssConfig fssConfig ) ->
                            let
                                newMesh = maybeScene |> FSS.build fssConfig
                            in
                                FssLayer fssConfig curBlend maybeScene newMesh
                        ( TemplateLayer _ curBlend _, TemplateConfig templateConfig ) ->
                            TemplateLayer templateConfig curBlend (templateConfig |> Template.build)
                        _ -> Unknown
                )
            , Cmd.none
            )

        ChangeWGLBlend index newBlend ->
            ( model |> updateLayer index
                (\layer ->
                    case layer of
                        -- FIXME: simplify
                        TemplateLayer cfg _ mesh ->
                            TemplateLayer cfg newBlend mesh
                        LorenzLayer cfg _ mesh ->
                            LorenzLayer cfg newBlend mesh
                        FractalLayer cfg _ mesh ->
                            FractalLayer cfg newBlend mesh
                        VoronoiLayer cfg _ mesh ->
                            VoronoiLayer cfg newBlend mesh
                        FssLayer cfg _ scene mesh ->
                            FssLayer cfg newBlend scene mesh
                        VignetteLayer cfg _ ->
                            VignetteLayer cfg newBlend
                        _ -> layer
                )
            , Cmd.none
            )

        ChangeSVGBlend index newBlend ->
            ( model |> updateLayer index
                (\layer ->
                    case layer of
                        TextLayer _ ->
                            TextLayer newBlend
                        SvgImageLayer _ ->
                            SvgImageLayer newBlend
                        _ -> layer
                )
            , Cmd.none
            )

        ChangeFacesX facesX ->
            updateAndRebuildFssWith
                { model | faces = model.faces |> Tuple.mapFirst (\_ -> facesX) }

        ChangeFacesY facesY ->
            updateAndRebuildFssWith
                { model | faces = model.faces |> Tuple.mapSecond (\_ -> facesY) }

        ChangeLightSpeed lightSpeed ->
            updateAndRebuildFssWith
                { model | lightSpeed = lightSpeed }

        Rotate theta ->
            ( { model | theta = theta  }
            , Cmd.none
            )

        Resize { width, height } ->
            ( { model
              | size = adaptSize ( width, height )
              , origin = getOrigin ( width, height )
              }
            -- , model |> extractFssBuildOptions |> requestFssRebuild
            , Cmd.none
            )

        Locate pos ->
            ( { model | mouse = (pos.x, pos.y) }
            , Cmd.none
            )

        RebuildFss index serializedScene ->
            ( model |> updateLayer index
                (\layer ->
                    case layer of
                        FssLayer cfg blend _ mesh ->
                            let
                                maybeScene = Just serializedScene
                                newMesh = maybeScene |> FSS.build cfg
                            in
                                FssLayer cfg blend maybeScene newMesh
                        _ -> layer
                )
            , Cmd.none
            )

        Pause ->
            ( { model | paused = True }
            , Cmd.none
            )

        Continue ->
            ( { model | paused = False }
            , Cmd.none
            )

        TriggerPause ->
            ( { model | paused = not model.paused }
            , Cmd.none
            )

        Import encodedModel ->
            ( IE.decodeModel encodedModel
                (\src ->
                    { model
                    | theta = src.theta
                    , now = src.now
                    , layers = List.map2 extractLayer model.layers src.layers
                    , mouse = src.mouse
                    , size = src.size
                    , origin = src.origin
                    -- , size = adaptSize src.size
                    -- , origin = getOrigin src.size
                    } )
                -- |> Debug.log "decoded model"
                |> Maybe.withDefault model
            , Cmd.none )

        Export ->
            ( model
            , model |> prepareModel |> IE.encodeModel |> export_
            )

        ExportZip ->
            ( model
            , model |> prepareModel |> IE.encodeModel |> exportZip_
            )

        TimeTravel timeShift ->
            (
                { model
                | timeShift = timeShift
                }
            , Cmd.none )

        BackToNow ->
            ( { model | timeShift = 0.0 }
            , Cmd.none
            )

        ChangeProduct product ->
            updateAndRebuildFssWith
                { model | product = product }

        ChangeVignette opacity ->
            ( { model
              | layers =
                  List.map
                      (\layer ->
                         case layer of
                            VignetteLayer config blend ->
                                VignetteLayer
                                    { config | opacity = opacity }
                                    blend
                            _ -> layer
                      )
                      model.layers }
            , Cmd.none
            )

        ChangeAmplitude ( newAmplitudeX, newAmplitudeY, newAmplitudeZ ) ->
            let
                ( currentAmplitudeX, currentAmplitudeY, currentAmplitudeZ ) = model.amplitude
            in
                ( { model
                | amplitude =
                    ( Maybe.withDefault currentAmplitudeX newAmplitudeX
                    , Maybe.withDefault currentAmplitudeY newAmplitudeY
                    , Maybe.withDefault currentAmplitudeZ newAmplitudeZ
                    ) }
                , Cmd.none
                )

        NoOp -> ( model, Cmd.none )


getLayerKind : Layer -> LayerKind
getLayerKind layer =
    case layer of
        FssLayer { clip } _ _ _ -> Fss clip
        LorenzLayer _ _ _ -> Lorenz
        FractalLayer _ _ _ -> Fractal
        VoronoiLayer _ _ _ -> Voronoi
        TemplateLayer _ _ _ -> Template
        TextLayer _ -> Text
        SvgImageLayer _ -> SvgImage
        VignetteLayer _ _ -> Vignette
        _ -> Text -- FIXME: Empty Kind or Nothing


getBlendString : Layer -> String
getBlendString layer =
    case layer of
        FssLayer _ blend _ _ -> WGLBlend.encodeOne blend
        LorenzLayer _ blend _ -> WGLBlend.encodeOne blend
        FractalLayer _ blend _ -> WGLBlend.encodeOne blend
        VoronoiLayer _ blend _ -> WGLBlend.encodeOne blend
        TemplateLayer _ blend _ -> WGLBlend.encodeOne blend
        VignetteLayer _ blend -> WGLBlend.encodeOne blend
        TextLayer blend -> SVGBlend.encode blend
        SvgImageLayer blend -> SVGBlend.encode blend
        _ -> SVGBlend.encode SVGBlend.default


getBlendForPort : Layer -> IE.PortBlend
getBlendForPort layer =
    ( case layer of
        FssLayer _ blend _ _ -> Just blend
        LorenzLayer _ blend _ -> Just blend
        FractalLayer _ blend _ -> Just blend
        VoronoiLayer _ blend _ -> Just blend
        TemplateLayer _ blend _ -> Just blend
        VignetteLayer _ blend -> Just blend
        _ -> Nothing
    , case layer of
        TextLayer blend ->
            SVGBlend.encode blend |> Just
        SvgImageLayer blend ->
            SVGBlend.encode blend |> Just
        _ -> Nothing
    )


encodeLayerKind : LayerKind -> String
encodeLayerKind kind =
    case kind of
        Fss _ -> "fss"
        Lorenz -> "lorenz"
        Template -> "template"
        Voronoi -> "voronoi"
        Fractal -> "fractal"
        Text -> "text"
        SvgImage -> "svg"
        Vignette -> "vignette"


-- decodeLayerKind : String -> Maybe LayerKind
-- decodeLayerKind code =
--     case code of
--         "fss" -> Just (Fss Nothing) -- FIXME: not Nothing
--         "lorenz" -> Just Lorenz
--         "template" -> Just Template
--         "voronoi" -> Just Voronoi
--         "fractal" -> Just Fractal
--         "text" -> Just Text
--         "svg" -> Just SvgImage
--         "vignette" -> Just Vignette
--         _ -> Nothing


createLayer : LayerKind -> Layer
createLayer code =
    case code of
        Fss maybeClip ->
            let fssConfig = FSS.init
            in
                FssLayer
                    { fssConfig | clip = maybeClip }
                    WGLBlend.default
                    Nothing
                    (FSS.build fssConfig Nothing)
        Lorenz ->
            let lorenzConfig = Lorenz.init
            in LorenzLayer lorenzConfig WGLBlend.default (lorenzConfig |> Lorenz.build)
        Template ->
            let templateConfig = Template.init
            in TemplateLayer templateConfig WGLBlend.default (templateConfig |> Template.build)
        Voronoi ->
            let voronoiConfig = Voronoi.init
            in VoronoiLayer voronoiConfig WGLBlend.default (voronoiConfig |> Voronoi.build)
        Fractal ->
            let fractalConfig = Fractal.init
            in FractalLayer fractalConfig WGLBlend.default (fractalConfig |> Fractal.build)
        Vignette ->
            WGLBlend.build
                (B.customAdd, B.srcAlpha, B.oneMinusSrcAlpha)
                (B.customAdd, B.one, B.oneMinusSrcAlpha)
                |> VignetteLayer Vignette.init
            -- WGLBlend.Blend Nothing (0, 1, 7) (0, 1, 7) |> VignetteLayer Vignette.init
            -- VignetteLayer Vignette.init WGLBlend.default
        Text ->
            TextLayer SVGBlend.default
        SvgImage ->
            SvgImageLayer SVGBlend.default


extractLayer : Layer -> IE.Layer -> Layer
extractLayer curLayer srcLayer =
    case ( srcLayer.type_, curLayer ) of
        ( IE.Fss, FssLayer config blend scene mesh ) ->
            FssLayer config srcLayer.blend scene mesh
        _ -> Unknown


prepareLayer : Layer -> IE.Layer
prepareLayer layer =
    case layer of
        FssLayer config blend maybeScene mesh ->
            { type_ = IE.Fss
            , blend = blend
            -- , config = config
            -- , mesh = mesh
            }
        _ -> IE.defaultLayer


prepareModel : Model -> IE.Model
prepareModel model =
    { theta = model.theta
    , now = model.now
    , layers = List.map prepareLayer model.layers
    , mouse = model.mouse
    , size = model.size
    , origin = model.origin
    }


extractFssBuildOptions : Model -> FssBuildOptions
extractFssBuildOptions = prepareGuiConfig


prepareGuiConfig : Model -> GuiConfig
prepareGuiConfig model =
    let
        ( amplitudeX, amplitudeY, amplitudeZ ) = model.amplitude
    in
        { product = Product.encode model.product
        , palette = Product.getPalette model.product
        , size = ( Tuple.first model.size |> toFloat |> (*) 1.8 |> floor
                , Tuple.second model.size |> toFloat |> (*) 1.8 |> floor
                )
        , layers =
            model.layers |>
                List.map (\layer ->
                    { kind = getLayerKind layer |> encodeLayerKind
                    , blend = getBlendForPort layer
                    , webglOrSvg = if isWebGLLayer layer then "webgl" else "svg"
                    })
        , facesX = Tuple.first model.faces
        , facesY = Tuple.second model.faces
        , amplitude = ( Just amplitudeX, Just amplitudeY, Just amplitudeZ )
        , lightSpeed = model.lightSpeed
        , vignette = model.vignette
        , customSize = Nothing
        }


timeShiftRange : Float
timeShiftRange = 500.0


adaptTimeShift : String -> Time
adaptTimeShift v =
    let floatV = String.toFloat v
         |> Result.withDefault 0.0
    in (floatV - 50.0) / 100.0 * timeShiftRange


extractTimeShift : Time -> String
extractTimeShift v =
    (v / timeShiftRange * 100.0) + 50.0 |> toString


configureWhenMatches : LayerIndex -> Model -> LayerConfig -> (Layer -> Bool) -> Msg
configureWhenMatches index { layers } config f =
    case Array.fromList layers |> Array.get index of
        Just layer -> if (f layer) then Configure index config else NoOp
        Nothing -> NoOp


updateLayer : Int -> (Layer -> Layer) -> Model -> Model
updateLayer index f model =
    let layersArray = Array.fromList model.layers
    in
        case layersArray |> Array.get index of
            Just layer ->
                { model
                | layers = layersArray |> Array.set index (f layer) |> Array.toList
                }
            Nothing -> model


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ bang (\_ -> Bang)
        , AnimationFrame.diffs Animate
        , Window.resizes Resize
        -- , clicks (\pos ->
        --     toLocal model.size pos
        --         |> Maybe.map (\pos -> Pause)
        --         |> Maybe.withDefault NoOp
        --   )
        , moves (\pos ->
            toLocal model.size pos
                |> Maybe.map (\localPos -> Locate localPos)
                |> Maybe.withDefault NoOp
          )
        , rotate Rotate
        , changeProduct (\productStr -> Product.decode productStr |> ChangeProduct)
        , changeFacesX ChangeFacesX
        , changeFacesY ChangeFacesY
        , changeLightSpeed ChangeLightSpeed
        , changeAmplitude ChangeAmplitude
        , setCustomSize
            (\(w, h) ->
                let
                    (newW, newH) =
                        if (w > 0 && h > 0) then (w, h)
                        else model.size
                in
                    Window.Size newW newH |> Resize)
        , changeWGLBlend (\{ layer, blend } ->
            ChangeWGLBlend layer blend
          )
        , changeSVGBlend (\{ layer, blend } ->
            ChangeSVGBlend layer (SVGBlend.decode blend)
          )
        , configureLorenz (\(lorenzConfig, layerIndex) ->
            configureWhenMatches layerIndex model (LorenzConfig lorenzConfig)
                (\layer ->
                    case layer of
                        LorenzLayer _ _ _ -> True
                        _ -> False
                )
          )
        , configureFss (\(fssConfig, layerIndex) ->
            configureWhenMatches layerIndex model (FSS.fromPortModel fssConfig |> FssConfig)
                (\layer ->
                    case layer of
                        FssLayer _ _ _ _ -> True
                        _ -> False
                )
          )
        , rebuildFss (\(serializedMesh, layerIndex) ->
            RebuildFss layerIndex serializedMesh
          )
        , import_ Import
        , pause (\_ -> Pause)
        , continue (\_ -> Continue)
        , triggerPause (\_ -> TriggerPause)
        ]


adaptSize : Size -> Size
adaptSize (width, height) =
    ( toFloat width  * sizeCoef |> floor
    , toFloat height * sizeCoef |> floor
    )


getOrigin : Size -> Pos
getOrigin (width, height) =
    ( toFloat width  * (1 - sizeCoef) / 2 |> ceiling
    , toFloat height * (1 - sizeCoef) / 2 |> ceiling
    )


toLocal : (Int, Int) -> Position -> Maybe Position
toLocal (width, height) pos =
        if (pos.x <= width) && (pos.y <= height)
        then Just pos else Nothing



mapControls : Model -> Controls.Msg -> Msg
mapControls model controlsMsg =
    case controlsMsg of
        Controls.Configure cfg -> Configure 0 (LorenzConfig cfg)
        Controls.Rotate th -> Rotate th


isWebGLLayer : Layer -> Bool
isWebGLLayer layer =
    case layer of
        TextLayer _ -> False
        SvgImageLayer _ -> False
        Unknown -> False
        _ -> True


isHtmlLayer : Layer -> Bool
isHtmlLayer layer =
    case layer of
        TextLayer _ -> True
        SvgImageLayer _ -> True
        Unknown -> False
        _ -> False


mergeWebGLLayers : Model -> List WebGL.Entity
mergeWebGLLayers model =
    let viewport = getViewportState model |> Viewport.find
    in
        model.layers
            |> List.filter isWebGLLayer
            |> List.concatMap (layerToEntities model viewport)


mergeHtmlLayers : Model -> List (Html Msg)
mergeHtmlLayers model =
    model.layers
        |> List.filter isHtmlLayer
        |> List.map (layerToHtml model)


layerToHtml : Model -> Layer -> Html Msg
layerToHtml model layer =
    case layer of
        TextLayer blend ->
            JbText.view model.size model.origin blend
        SvgImageLayer blend ->
            SVGImage.view model.size model.origin model.product blend
        _ -> div [] []


layerToEntities : Model -> Viewport {} -> Layer -> List WebGL.Entity
layerToEntities model viewport layer =
    case layer of
        LorenzLayer _ blend lorenz ->
            [ Lorenz.makeEntity
                viewport
                [ DepthTest.default, WGLBlend.produce blend ]
                lorenz
            ]
        FractalLayer _ blend fractal ->
            [ Fractal.makeEntity
                viewport
                [ DepthTest.default, WGLBlend.produce blend ]
                fractal
            ]
        TemplateLayer _ blend template ->
            [ Template.makeEntity
                viewport
                [ DepthTest.default, WGLBlend.produce blend ]
                template
            ]
        VoronoiLayer _ blend voronoi ->
            [ Voronoi.makeEntity
                viewport
                [ DepthTest.default, WGLBlend.produce blend ]
                voronoi
            ]
        FssLayer config blend serialized fss ->
            [ FSS.makeEntity
                viewport
                config
                serialized
                [ DepthTest.default, WGLBlend.produce blend, sampleAlphaToCoverage ]
                fss
            ]
        -- MirroredFssLayer fssConfig blend serialized fss ->
        --     let
        --         config1 = { fssConfig | clip = Just ( FSS.defaultMirror, 1 ) }
        --         config2 = { fssConfig | clip = Just ( 0, 1.0 - FSS.defaultMirror ) }
        --     in
        --         (layerToEntities model viewport (FssLayer config1 blend serialized fss)) ++
        --         (layerToEntities model viewport (FssLayer config2 blend serialized fss))
        VignetteLayer config blend ->
            [ Vignette.makeEntity
                  viewport
                  config
                  [ DepthTest.default, WGLBlend.produce blend, sampleAlphaToCoverage ]
            ]
        TextLayer _ -> []
            -- [ Template.makeEntity
            --     viewport
            --     [ DepthTest.default, WGLBlend.produce blend ]
            --     (Template.init |> Template.build)
            -- ]
        SvgImageLayer _ -> []
        Unknown -> []
            -- [ Template.makeEntity
            --     viewport
            --     [ DepthTest.default, WGLBlend.produce WGLBlend.default ]
            --     (Template.init |> Template.build)
            -- ]


getViewportState : Model -> Viewport.State
getViewportState { paused, size, origin, theta } =
    { paused = paused, size = size, origin = origin, theta = theta }


view : Model -> Html Msg
view model =
    div [ ]
        --span [ class "fps" ] [ toString model.fps ++ "FPS" |> text ]
        --    :: Html.map mapControls
        --     (config |>
        --           Controls.controls numVertices theta)
           --:: WebGL.toHtmlWith
        [ div
            [ H.class "overlay-panel import-export-panel hide-on-space" ]
            [ input
                [ type_ "range"
                , H.min "0"
                , H.max "100"
                , extractTimeShift model.timeShift |> H.value
                , onInput (\v -> adaptTimeShift v |> TimeTravel)
                , onMouseUp BackToNow
                ]
                []
            , input [ type_ "button", id "import-button", value "Import" ] [ text "Import" ]
            , input [ type_ "button", onClick Export, value "Export" ] [ text "Export" ]
            , input
                [ type_ "button", onClick ExportZip, value "Export .zip" ]
                [ text "Export .zip" ]
            ]
        , mergeWebGLLayers model |>
            WebGL.toHtmlWith
                [ WebGL.antialias
                , WebGL.alpha True
                , WebGL.clearColor 0.0 0.0 0.0 1.0
                --, WebGL.depth 0.5
                ]
                [ H.class "webgl-layers"
                , width (Tuple.first model.size)
                , height (Tuple.second model.size)
                , style
                    [ ( "display", "block" )
                    --, ( "background-color", "#161616" )
                    ,   ( "transform", "translate("
                        ++ (Tuple.first model.origin |> toString)
                        ++ "px, "
                        ++ (Tuple.second model.origin |> toString)
                        ++ "px)"
                        )
                    ]
                , onClick TriggerPause
                ]
        , mergeHtmlLayers model |> div [ H.class "svg-layers"]
        ]


main : Program Never Model Msg
main =
    Html.program
        { init = init
        , view = view
        , subscriptions = subscriptions
        , update = update
        }


-- INGOING PORTS

port bang : (() -> msg) -> Sub msg

port pause : (() -> msg) -> Sub msg

port continue : (() -> msg) -> Sub msg

port triggerPause : (() -> msg) -> Sub msg

port rotate : (Float -> msg) -> Sub msg

port initLayers : (Array String -> msg) -> Sub msg

port configureLorenz : ((Lorenz.Config, Int) -> msg) -> Sub msg

port configureFss : ((FSS.PortModel, Int) -> msg) -> Sub msg

port configureMirroredFss : ((FSS.PortModel, Int) -> msg) -> Sub msg

port changeProduct : (String -> msg) -> Sub msg

-- TODO: port to affect camera

port rebuildFss : ((FSS.SerializedScene, Int) -> msg) -> Sub msg

port import_ : (String -> msg) -> Sub msg

port changeFacesX : (Int -> msg) -> Sub msg

port changeFacesY : (Int -> msg) -> Sub msg

port changeLightSpeed : (Int -> msg) -> Sub msg

port changeVignette : (Float -> msg) -> Sub msg

port changeAmplitude : (FSS.AmplitudeChange -> msg) -> Sub msg

port setCustomSize : ((Int, Int) -> msg) -> Sub msg

port changeWGLBlend :
    ( { layer : Int
      , blend : WGLBlend.Blend
      }
    -> msg) -> Sub msg

port changeSVGBlend :
    ( { layer : Int
      , blend : SVGBlend.PortBlend
      }
    -> msg) -> Sub msg


-- OUTGOING PORTS

port startGui : GuiConfig -> Cmd msg

port requestFssRebuild : FssBuildOptions -> Cmd msg

port export_ : String -> Cmd msg

port exportZip_ : String -> Cmd msg

-- port rebuildOnClient : (FSS.SerializedScene, Int) -> Cmd msg

