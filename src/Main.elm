port module Main exposing (main)

import Browser

import Array exposing (Array)
import Task exposing (Task)

import Browser.Dom as Browser
import Browser.Events as Browser

import Html exposing (Html, text, div, span, input)
import Html.Attributes as H
    exposing (class, width, height, style, class, type_, min, max, value, id)
-- import Html.Events exposing (on, onInput, onMouseUp, onClick)
import Html.Events as Events exposing (onInput)
import Json.Decode as D

import WebGL exposing (Mesh, Option)
import WebGL.Settings.Blend as B
import WebGL.Settings exposing (sampleAlphaToCoverage)
import WebGL.Settings.DepthTest as DepthTest

import Model exposing (..)
import Gui.Gui as Gui
import Gui.Mouse exposing (Position)
import Viewport exposing (Viewport)
import WebGL.Blend as WGLBlend
import Html.Blend as HtmlBlend
import Controls
import ImportExport as IE
import Product exposing (Product)
import Product as Product

import Layer.Lorenz as Lorenz
import Layer.Fractal as Fractal
import Layer.Voronoi as Voronoi
import Layer.FSS as FSS
import Layer.Template as Template
import Layer.Cover as Cover
import Layer.Canvas as Canvas
import Layer.Vignette as Vignette
import Layer.Metaballs as Metaballs


sizeCoef : Float
sizeCoef = 1.0


initialMode : UiMode
initialMode = Development


init : ( Model, Cmd Msg )
init =
    ( Model.init initialMode (initialLayers initialMode) createLayer
    , resizeToViewport
    )


initialLayers : UiMode -> List ( LayerKind, String, LayerModel )
initialLayers mode =
    -- [ ( Fss, "Lower Layer", FssModel FSS.init )
    -- , ( Fss, "Mid Layer", FssModel FSS.init )
    -- , ( Fss, "Top layer"
    --   , let
    --         fssModel = FSS.init
    --     in
    --         { fssModel
    --         | renderMode = FSS.PartialLines
    --         , shareMesh = True
    --         } |> FssModel
    --   )
    -- , ( Cover, "Cover", NoModel )
    -- -- , ( Vignette, Vignette.init )
    -- ]
    -- |> List.filter (\(kind, _, _) ->
    --     case ( kind, mode ) of
    --         ( Cover, Ads ) -> False
    --         _ -> True
    -- )
    [ ( Metaballs, "Metaballs", MetaballsModel Metaballs.init )
    ]



update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of

        Bang ->
            ( model
            , model |> IE.encodePortModel |> startGui
            )

        ChangeMode mode ->
            ( Model.init mode (initialLayers mode) createLayer
            , resizeToViewport
            )

        GuiMessage guiMsg ->
            case model.gui of
                Just gui ->
                    let
                        ( ( newModel, commands ), newGui ) =
                            gui |> Gui.update update model guiMsg
                    in
                        (
                            { newModel
                            | gui = Just newGui
                            }
                        , commands
                        )
                Nothing -> ( model, Cmd.none )

        Animate dt ->
            (
                { model
                 | fps = floor (1000 / dt)
                 , theta = if not (model.autoRotate || model.paused)
                              then model.theta + (dt * model.omega) / 1000
                              else model.theta
                 , now = if not model.paused
                            then model.now + dt + model.timeShift
                            else model.now
                 }
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

        HideControls ->
            ( { model | controlsVisible = False }
            , Cmd.none
            )

        Import encodedModel ->
            encodedModel
                |> IE.decodeModel model.mode createLayer
                |> Maybe.withDefault model
                |> rebuildAllFssLayersWith

        Export ->
            ( model
            , model |> IE.encodeModel |> export_
            )

        ExportZip ->
            ( model
            , model |> IE.encodeModel |> exportZip_
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

        Rotate omega ->
            ( { model | omega = omega  }
            , Cmd.none
            )

        Resize (ViewportSize width height) ->
            ( { model
              | size = adaptSize ( width, height )
              , origin = getOrigin ( width, height )
              }
            , Cmd.none -- updateAndRebuildFssWith
            )

        ResizeFromPreset (ViewportSize width height) ->
            let
                newModel =
                    { model
                    | size = adaptSize ( width, height )
                    , origin = getOrigin ( width, height )
                    }
            in
                ( newModel
                , newModel |> getSizeUpdate |> presetSizeChanged
                )

        RequestFitToWindow ->
            ( model, requestFitToWindow () )

        Locate (( x, y ) as pos) ->
            let
                modelWithMouse =
                    { model
                    | mouse = pos
                    }
                message = modelWithMouse.gui
                    |> Maybe.map
                        (\gui ->
                            Gui.moves gui { x = x, y = y } |> GuiMessage
                        )
                    |> Maybe.withDefault NoOp
            in
                update message modelWithMouse

        TurnOn index ->
            ( model |> updateLayerDef index
                (\def -> { def | on = True })
            , Cmd.none
            )

        TurnOff index ->
            ( model |> updateLayerDef index
                (\def -> { def | on = False })
            , Cmd.none
            )

        MirrorOn index ->
            ( model |> updateLayerDef index
                (\layerDef ->
                    case layerDef.layer of
                        WebGLLayer webglLayer blend ->
                            case webglLayer of
                                FssLayer maybeScene mesh ->
                                    { layerDef
                                    | layer =
                                        WebGLLayer
                                        (MirroredFssLayer maybeScene mesh)
                                        blend
                                    , kind = MirroredFss
                                    }
                                _ -> layerDef
                        _ -> layerDef
                )
            , Cmd.none
            )

        MirrorOff index ->
            ( model |> updateLayerDef index
                (\layerDef ->
                    case layerDef.layer of
                        WebGLLayer webglLayer blend ->
                            case webglLayer of
                                MirroredFssLayer maybeScene mesh ->
                                    { layerDef
                                    | layer =
                                        WebGLLayer
                                        (FssLayer maybeScene mesh)
                                        blend
                                    , kind = Fss
                                    }
                                _ -> layerDef
                        _ -> layerDef
                )
            , Cmd.none
            )

        ChangeProduct product ->
            { model | product = product }
            |> rebuildAllFssLayersWith

        Configure index layerModel ->
            ( model |> updateLayer index
                (\layer curLayerModel ->
                    case layer of
                        WebGLLayer webglLayer webglBlend ->
                            WebGLLayer
                            (case ( webglLayer, curLayerModel ) of
                                ( LorenzLayer _, LorenzModel lorenzModel ) ->
                                    LorenzLayer (lorenzModel |> Lorenz.build)
                                ( FractalLayer _, FractalModel fractalModel ) ->
                                    FractalLayer (fractalModel |> Fractal.build)
                                ( VoronoiLayer _, VoronoiModel voronoiModel ) ->
                                    VoronoiLayer (voronoiModel |> Voronoi.build)
                                ( FssLayer maybeScene _, FssModel fssModel ) ->
                                    let
                                        newMesh = maybeScene |> FSS.build fssModel
                                    in
                                        FssLayer maybeScene newMesh
                                ( MirroredFssLayer maybeScene _, FssModel fssModel ) ->
                                    let
                                        newMesh = maybeScene |> FSS.build fssModel
                                    in
                                        MirroredFssLayer maybeScene newMesh
                                ( TemplateLayer _, TemplateModel templateModel ) ->
                                    TemplateLayer (templateModel |> Template.build)
                                ( VignetteLayer, VignetteModel vignetteModel ) ->
                                    VignetteLayer
                                _ -> webglLayer)
                            webglBlend
                        _ -> layer)
            , Cmd.none
            )

        ChangeWGLBlend index newBlend ->
            ( model |> updateLayerBlend index
                (\_ -> Just newBlend)
                (\_ -> Nothing)
            , Cmd.none
            )

        AlterWGLBlend index changeF ->
            ( model |> updateLayerBlend index
                (\curBlend -> Just <| changeF curBlend)
                (\_ -> Nothing)
            , Cmd.none
            )

        ChangeHtmlBlend index newBlend ->
            ( model |> updateLayerBlend index
                (\_ -> Nothing)
                (\_ -> Just newBlend)
            , Cmd.none
            )

        ChangeFssRenderMode index renderMode ->
            -- ( model
            --     |> updateFss index
            --         (\fssModel -> { fssModel | renderMode = renderMode })
            -- , Cmd.none
            -- )
            model
                |> updateAndRebuildFssWith index
                    (\fssModel -> { fssModel | renderMode = renderMode })

        ChangeFaces index faces ->
            model
                |> updateAndRebuildFssWith index
                    (\fssModel -> { fssModel | faces = faces })

        AlterFaces index change ->
            model
                |> updateAndRebuildFssWith index
                    (\fss ->
                        let
                            current = fss.faces
                        in
                            { fss | faces =
                                FSS.Faces
                                    ( change.xChange |> Maybe.withDefault current.x )
                                    ( change.yChange |> Maybe.withDefault current.y )
                            }
                    )

        ChangeLightSpeed index lightSpeed ->
            model
                |> updateAndRebuildFssWith index
                    (\fssModel -> { fssModel | lightSpeed = lightSpeed })

        RebuildFss index serializedScene ->
            ( model |> updateLayer index
                (\layer layerModel ->
                    case layer of
                        WebGLLayer webglLayer webglBlend ->
                            case ( webglLayer, layerModel ) of
                                ( FssLayer _ mesh, FssModel fssModel ) ->
                                    let
                                        maybeScene = Just serializedScene
                                        newMesh = maybeScene |> FSS.build fssModel
                                    in
                                        WebGLLayer
                                        (FssLayer maybeScene newMesh)
                                        webglBlend
                                ( MirroredFssLayer _ mesh, FssModel fssModel ) ->
                                    let
                                        maybeScene = Just serializedScene
                                        newMesh = maybeScene |> FSS.build fssModel
                                    in
                                        WebGLLayer
                                        (MirroredFssLayer maybeScene newMesh)
                                        webglBlend
                                _ -> layer
                        _ -> layer
                )
            , Cmd.none
            )

        ChangeVignette index opacity ->
            ( model
                |> updateFss index
                    (\fssModel -> { fssModel | vignette = opacity })
            , Cmd.none
            )

        ChangeIris index iris ->
            ( model |> updateFss index
                (\fssModel -> { fssModel | iris = iris })
            , Cmd.none
            )

            -- model
            --     |> updateAndRebuildFssWith index
            --         (\fssModel -> { fssModel | vignette = vignette })

            -- ( model
            --     |> updateLayerWithItsModel
            --         index
            --         (\(layer, model) ->
            --             case ( layer, model ) of
            --                 ( WebGLLayer VignetteLayer _, VignetteModel vignetteModel ) ->
            --                     (layer, { vignetteModel | opacity = opacity } |> VignetteModel)
            --                 _ -> (layer, model)
            --         )
            -- , Cmd.none

        AlterAmplitude index change ->
            model
                |> updateAndRebuildFssWith index
                    (\fss ->
                        let
                            current = fss.amplitude
                        in
                            { fss | amplitude =
                                FSS.Amplitude
                                    ( change.xChange |> Maybe.withDefault current.amplitudeX )
                                    ( change.yChange |> Maybe.withDefault current.amplitudeY )
                                    ( change.zChange |> Maybe.withDefault current.amplitudeZ )
                            }
                    )


        ShiftColor index shift ->
            ( model |> updateFss index
                (\fss ->
                    let
                        current = fss.colorShift
                    in
                        { fss | colorShift =
                            FSS.ColorShift
                                ( shift.hueShift        |> Maybe.withDefault current.hue        )
                                ( shift.saturationShift |> Maybe.withDefault current.saturation )
                                ( shift.brightnessShift |> Maybe.withDefault current.brightness )
                        }
                )
            , Cmd.none
            )

        ChangeOpacity index newOpacity ->
            ( model |> updateFss index
                (\fssModel -> { fssModel | opacity = newOpacity })
            , Cmd.none
            )

        SavePng ->
            ( model
            , model |> getSizeUpdate |> triggerSavePng
            )

        Randomize ->
            ( model
            , model |> IE.encodePortModel |> requestRandomize
            )

        ApplyRandomizer portModel ->
            (IE.decodePortModel createLayer portModel)
                |> rebuildAllFssLayersWith

        NoOp -> ( model, Cmd.none )


getSizeUpdate : Model -> SizeUpdate
getSizeUpdate model =
    { size = model.size
    , product = Product.encode model.product
    , coverSize = Product.getCoverTextSize model.product
    , background = model.background
    }


getLayerModel : LayerIndex -> Model -> Maybe LayerModel
getLayerModel index model =
    model.layers
        |> Array.fromList
        |> Array.get index
        |> Maybe.map .model


updateFss : LayerIndex -> (FSS.Model -> FSS.Model) -> Model -> Model
updateFss index f model =
    model |> updateLayerWithItsModel
        index
        (\(layer, layerModel) ->
            ( layer
            , case layerModel of
                FssModel fssModel ->
                    f fssModel |> FssModel
                _ -> layerModel
            )
        )


updateAndRebuildFssWith
    : LayerIndex
    -> (FSS.Model -> FSS.Model)
    -> Model
    -> ( Model, Cmd Msg )
updateAndRebuildFssWith index f curModel =
    let
        newModel = updateFss index f curModel
    in
        ( newModel
        , case (newModel |> getLayerModel index) of
            Just (FssModel fssModel) ->
                requestFssRebuild
                    { layer = index
                    , model = IE.encodePortModel newModel
                    , value = IE.encodeFss fssModel newModel.product
                    }
            _ -> Cmd.none
        )


rebuildAllFssLayersWith : Model -> ( Model, Cmd Msg )
rebuildAllFssLayersWith model =
    let
        isLayerFss layerDef =
            case layerDef.model of
                FssModel fssModel -> Just fssModel
                _ -> Nothing
        encodedModel = IE.encodePortModel model
        rebuildPotentialFss index fssModel =
            requestFssRebuild
                { layer = index
                , model = encodedModel
                , value = IE.encodeFss fssModel model.product
                }

    in
        ( model
        , List.filterMap isLayerFss model.layers
          |> List.indexedMap rebuildPotentialFss
          |> Cmd.batch
        )


getBlendForPort : Layer -> PortBlend
getBlendForPort layer =
    ( case layer of
        WebGLLayer _ webglBlend -> Just webglBlend
        _ -> Nothing
    , case layer of
        HtmlLayer _ htmlBlend ->
            HtmlBlend.encode htmlBlend |> Just
        _ -> Nothing
    )


-- decodeLayerKind : String -> Maybe LayerKind
-- decodeLayerKind code =
--     case code of
--         "fss" -> Just (Fss Nothing) -- FIXME: not Nothing
--         "lorenz" -> Just Lorenz
--         "template" -> Just Template
--         "voronoi" -> Just Voronoi
--         "fractal" -> Just Fractal
--         "text" -> Just Text
--         "html" -> Just SvgImage
--         "vignette" -> Just Vignette
--         _ -> Nothing


createLayer : LayerKind -> LayerModel -> Layer
createLayer kind layerModel =
    case ( kind, layerModel ) of
        ( Fss, FssModel fssModel )  ->
            WebGLLayer
            ( FSS.build fssModel Nothing |> FssLayer Nothing )
            WGLBlend.default
        ( MirroredFss, FssModel fssModel ) ->
            WebGLLayer
            ( FSS.build fssModel Nothing |> MirroredFssLayer Nothing )
            WGLBlend.default
            -- (WGLBlend.build
            --    (B.customAdd, B.oneMinusSrcColor, B.oneMinusSrcColor)
            --    (B.customAdd, B.srcColor, B.zero)
            -- )
        ( Lorenz, LorenzModel lorenzModel ) ->
            WebGLLayer
            (Lorenz.build lorenzModel |> LorenzLayer)
            WGLBlend.default
        ( Template, TemplateModel templateModel ) ->
            WebGLLayer
            ( Template.build templateModel |> TemplateLayer )
            WGLBlend.default
        ( Voronoi, VoronoiModel voronoiModel ) ->
            WebGLLayer
            ( Voronoi.build voronoiModel |> VoronoiLayer )
            WGLBlend.default
        ( Fractal, FractalModel fractalModel ) ->
            WebGLLayer
            ( Fractal.build fractalModel |> FractalLayer )
            WGLBlend.default
        ( Vignette, _ ) ->
            WebGLLayer
            VignetteLayer
            (WGLBlend.build
                (B.customAdd, B.srcAlpha, B.oneMinusSrcAlpha)
                (B.customAdd, B.one, B.oneMinusSrcAlpha) )
            -- WGLBlend.Blend Nothing (0, 1, 7) (0, 1, 7) |> VignetteLayer Vignette.init
            -- VignetteLayer Vignette.init WGLBlend.default
        ( Cover, _ ) ->
            HtmlLayer
            CoverLayer
            HtmlBlend.default
        ( Metaballs, _ ) ->
            HtmlLayer
            MetaballsLayer
            HtmlBlend.default
        _ ->
            Model.emptyLayer


-- extractFssBuildOptions : Model -> FssBuildOptions
-- extractFssBuildOptions = prepareGuiConfig



timeShiftRange : Float
timeShiftRange = 500.0


adaptTimeShift : String -> TimeDelta
adaptTimeShift v =
    let floatV = String.toFloat v
         |> Maybe.withDefault 0.0
    in (floatV - 50.0) / 100.0 * timeShiftRange


extractTimeShift : TimeDelta -> String
extractTimeShift v =
    (v / timeShiftRange * 100.0) + 50.0 |> String.fromFloat


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


updateLayerBlend
    : Int
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


tellGui : (Gui.Model Msg -> a -> Gui.Msg Msg) -> Model -> a -> Msg
tellGui f model =
    model.gui
        |> Maybe.map (\gui -> f gui >> GuiMessage)
        |> Maybe.withDefault (always NoOp)



decodeMousePosition : D.Decoder Position
decodeMousePosition =
    D.map2 Position
        (D.at [ "offsetX" ] D.int)
        (D.at [ "offsetY" ] D.int)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ bang (\_ -> Bang)
        , Browser.onAnimationFrameDelta Animate
        , Browser.onResize <| \w h -> Resize (ViewportSize w h)
        -- , clicks (\pos ->
        --     toLocal model.size pos
        --         |> Maybe.map (\pos -> Pause)
        --         |> Maybe.withDefault NoOp
        --   )
        , Sub.map (\{ x, y } ->
                toLocal model.size (x, y)
                    |> Maybe.map (\localPos -> Locate localPos)
                    |> Maybe.withDefault NoOp
            )
            <| Browser.onMouseMove
            <| decodeMousePosition
        --, downs <| Gui.downs >> GuiMessage
        , Sub.map (tellGui Gui.downs model)
            <| Browser.onMouseDown
            <| decodeMousePosition
        , Sub.map (tellGui Gui.ups model)
            <| Browser.onMouseUp
            <| decodeMousePosition
        , rotate Rotate
        , changeProduct (\productStr -> Product.decode productStr |> ChangeProduct)
        , changeFssRenderMode (\{value, layer} ->
            FSS.decodeRenderMode value |> ChangeFssRenderMode layer)
        , changeFacesX (\{value, layer} ->
            case model |> getLayerModel layer of
                Just (FssModel { faces }) ->
                    ChangeFaces layer { x = value, y = faces.y }
                _ -> NoOp
          )
        , changeFacesY (\{value, layer} ->
            case model |> getLayerModel layer of
                Just (FssModel { faces }) ->
                    ChangeFaces layer { x = faces.x, y = value }
                _ -> NoOp
          )
        , changeLightSpeed (\{value, layer} -> ChangeLightSpeed layer value)
        , changeAmplitude (\{value, layer} -> AlterAmplitude layer value)
        , shiftColor (\{value, layer} -> ShiftColor layer value)
        , changeOpacity (\{value, layer} -> ChangeOpacity layer value)
        , changeVignette (\{value, layer} -> ChangeVignette layer value)
        , changeIris (\{value, layer} -> ChangeIris layer value)
        , changeMode (\modeStr -> ChangeMode <| IE.decodeMode modeStr)
        , setCustomSize
            (\(w, h) ->
                let
                    (newW, newH) =
                        if (w > 0 && h > 0) then (w, h)
                        else model.size
                in
                    ViewportSize newW newH |> ResizeFromPreset)
        , changeWGLBlend (\{ layer, value } ->
            ChangeWGLBlend layer value
          )
        , changeHtmlBlend (\{ layer, value } ->
            ChangeHtmlBlend layer <| HtmlBlend.decode value
          )
        , configureLorenz (\{ layer, value } ->
            Configure layer (LorenzModel value)
          )
        , configureFss (\{ layer, value } ->
            IE.fromFssPortModel value |> FssModel |> Configure layer
          )
        , rebuildFss (\{ layer, value } ->
            RebuildFss layer value
          )
        , applyRandomizer ApplyRandomizer
        , import_ Import
        , pause (\_ -> Pause)
        , continue (\_ -> Continue)
        , triggerPause (\_ -> TriggerPause)
        , hideControls (\_ -> HideControls)
        , turnOn TurnOn
        , turnOff TurnOff
        , mirrorOn MirrorOn
        , mirrorOff MirrorOff
        , savePng (\_ -> SavePng)
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


toLocal : (Int, Int) -> Pos -> Maybe Pos
toLocal (width, height) (x, y) =
        if (x <= width) && (y <= height)
        then Just (x, y) else Nothing



mapControls : Model -> Controls.Msg -> Msg
mapControls model controlsMsg =
    case controlsMsg of
        Controls.Configure cfg -> Configure 0 (LorenzModel cfg)
        Controls.Rotate th -> Rotate th


type RenderQueueItem = Empty | ToCanvas (Array WebGL.Entity) | ToHtml (Array (Html Msg))
type alias RenderQueue = Array RenderQueueItem


groupLayers : Model -> RenderQueue
groupLayers model =
    let
        viewport = getViewportState model |> Viewport.find
        addToQueue (index, layer) renderQueue =
            let
                indexOfThelastInQueue = Array.length renderQueue - 1
                lastInQueue = renderQueue |> Array.get indexOfThelastInQueue
            in case layer.layer of
                WebGLLayer _ _ ->
                    case lastInQueue of
                        Nothing ->
                            renderQueue
                                |> Array.push
                                    (layerToEntities model viewport index layer
                                        |> Array.fromList
                                        |> ToCanvas)
                        Just (ToCanvas curEntities) ->
                            renderQueue
                                |> Array.set indexOfThelastInQueue
                                    (layerToEntities model viewport index layer
                                        |> Array.fromList
                                        |> Array.append curEntities
                                        |> ToCanvas)
                        Just _ ->
                            renderQueue
                                |> Array.push
                                    (layerToEntities model viewport index layer
                                        |> Array.fromList
                                        |> ToCanvas)
                HtmlLayer _ _ ->
                    case lastInQueue of
                        Nothing ->
                            renderQueue
                                |> Array.push
                                    (Array.empty
                                        |> Array.push (layerToHtml model index layer)
                                        |> ToHtml)
                        Just (ToHtml curHtml) ->
                            renderQueue
                                |> Array.set indexOfThelastInQueue
                                    (Array.empty
                                        |> Array.push (layerToHtml model index layer)
                                        |> Array.append curHtml
                                        |> ToHtml)
                        Just _ ->
                            renderQueue
                                |> Array.push
                                    (Array.empty
                                        |> Array.push (layerToHtml model index layer)
                                        |> ToHtml)
    in
        model.layers
            |> List.indexedMap Tuple.pair
            |> List.foldl addToQueue Array.empty


isWebGLLayer : Layer -> Bool
isWebGLLayer layer =
    case layer of
        WebGLLayer _ _ -> True
        HtmlLayer _ _ -> False

isHtmlLayer : Layer -> Bool
isHtmlLayer layer =
    case layer of
        WebGLLayer _ _ -> False
        HtmlLayer _ _ -> True


mergeWebGLLayers : Model -> List WebGL.Entity
mergeWebGLLayers model =
    let viewport = getViewportState model |> Viewport.find
    in
        model.layers
            |> List.filter (.layer >> isWebGLLayer)
            |> List.filter .on
            |> List.indexedMap Tuple.pair
            -- |> List.concatMap (uncurry >> layerToEntities model viewport)
            |> List.concatMap
                    (\(index, layer) ->
                        layerToEntities model viewport index layer
                    )


mergeHtmlLayers : Model -> List (Html Msg)
mergeHtmlLayers model =
    model.layers
        |> List.filter (.layer >> isHtmlLayer)
        |> List.filter .on
        |> List.indexedMap (layerToHtml model)


layerToHtml : Model -> Int -> LayerDef -> Html Msg
layerToHtml model index { layer } =
    case layer of
        HtmlLayer htmlLayer htmlBlend ->
            case htmlLayer of
                CoverLayer ->
                    Cover.view model.mode model.product model.size model.origin htmlBlend
                MetaballsLayer ->
                    Metaballs.view model.mouse
                CanvasLayer ->
                    Canvas.view
                NoContent -> div [] []
        _ -> div [] []


layerToEntities : Model -> Viewport {} -> Int -> LayerDef -> List WebGL.Entity
layerToEntities model viewport index layerDef =
    case layerDef.layer of
        WebGLLayer webglLayer blend ->
            case ( webglLayer, layerDef.model ) of
                ( LorenzLayer mesh, _ ) ->
                    [ Lorenz.makeEntity
                        viewport
                        [ DepthTest.default, WGLBlend.produce blend ]
                        mesh
                    ]
                ( FractalLayer mesh, _ ) ->
                    [ Fractal.makeEntity
                        viewport
                        [ DepthTest.default, WGLBlend.produce blend ]
                        mesh
                    ]
                ( TemplateLayer mesh, _ ) ->
                    [ Template.makeEntity
                        viewport
                        [ DepthTest.default, WGLBlend.produce blend ]
                        mesh
                    ]
                ( VoronoiLayer mesh, _ ) ->
                    [ Voronoi.makeEntity
                        viewport
                        [ DepthTest.default, WGLBlend.produce blend ]
                        mesh
                    ]
                ( FssLayer serialized mesh, FssModel fssModel ) ->
                    let
                        ( maybeBorrowedSerialized, maybeBorrowedMesh ) =
                            ( serialized, mesh )
                            -- if (fssModel.shareMesh) then
                            --     model |>
                            --         findTopAndGet
                            --             (\layer otherIndex ->
                            --                 if otherIndex < index then
                            --                     case layer of
                            --                         FssLayer _ otherSerialized otherMesh ->
                            --                             Just ( otherSerialized, otherMesh )
                            --                         MirroredFssLayer _ otherSerialized otherMesh ->
                            --                             Just ( otherSerialized, otherMesh )
                            --                         _ -> Nothing
                            --                 else Nothing
                            --             )
                            --             ( serialized, mesh )
                            -- else ( serialized, mesh )
                    in
                        [ FSS.makeEntity
                            model.now
                            (case model.mouse of ( x, y ) -> { x = x, y = y })
                            (model.product |> Product.getId)
                            index
                            viewport
                            fssModel
                            maybeBorrowedSerialized
                            [ DepthTest.default, WGLBlend.produce blend, sampleAlphaToCoverage ]
                            maybeBorrowedMesh -- seems this mesh is already built with "Triangles", so there's no sense in reusing it
                    ]
                ( MirroredFssLayer serialized mesh, FssModel fssModel ) ->
                    let
                        -- TODO: store clip position in the layer
                        fssModel1 =
                            { fssModel
                            | clip = Just { x = 0.0, y = FSS.defaultMirror }
                            , mirror = True
                            }
                        fssModel2 =
                            { fssModel
                            | clip = Just { x = FSS.defaultMirror, y = 1.0 }
                            }
                    in
                        layerToEntities model viewport index
                            { layerDef
                            | layer = WebGLLayer (FssLayer serialized mesh) blend
                            , model = FssModel fssModel1
                            } ++
                        layerToEntities model viewport index
                            { layerDef
                            | layer = WebGLLayer (FssLayer serialized mesh) blend
                            , model = FssModel fssModel2
                            }
                ( VignetteLayer, _ ) ->
                    [ Vignette.makeEntity
                        viewport
                        Vignette.init
                        [ DepthTest.default, WGLBlend.produce blend, sampleAlphaToCoverage ]
                    ]
                _ -> []
        _ -> []


resizeToViewport =
    Task.perform
        (\{ viewport } -> Resize
            <| ViewportSize (floor viewport.width) (floor viewport.height))
        Browser.getViewport


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
        [ mergeHtmlLayers model |> div [ H.class "html-layers" ]
        , if model.controlsVisible
            then ( div
                [ H.class "overlay-panel import-export-panel hide-on-space" ]
                [
                  div [  H.class "timeline_holder" ] [
                  span [ H.class "label past"] [text "past"]
                , input
                    [ type_ "range"
                    , class "timeline"
                    , H.min "0"
                    , H.max "100"
                    , extractTimeShift model.timeShift |> H.value
                    , Events.onInput (\v -> adaptTimeShift v |> TimeTravel)
                    , Events.onMouseUp BackToNow
                    ]
                    []
                , span [ H.class "label future"] [text "future"]
                  ]
                -- , input [ type_ "button", id "import-button", value "Import" ] [ text "Import" ]
                -- , input [ type_ "button", onClick Export, value "Export" ] [ text "Export" ]
                , input
                    [ type_ "button", class "export_html5"
                    , Events.onClick ExportZip, value "warp in html5" ]
                    [ text "Export to html5.zip" ]
                , input
                    [ type_ "button", class "export_png"
                    , Events.onClick SavePng, value "blast to png" ]
                    [ text "Export to png" ]
                , div [ H.class "spacebar_info" ] [ text "spacebar to hide controls, click to pause" ]
                ]
            ) else div [] []
        , mergeWebGLLayers model |>
            WebGL.toHtmlWith
                [ WebGL.antialias
                , WebGL.alpha True
                , WebGL.clearColor 0.0 0.0 0.0 1.0
                -- , WebGL.depth 0.5
                ]
                [ H.class "webgl-layers"
                , width (Tuple.first model.size)
                , height (Tuple.second model.size)
                , style "display" "block"
                    --, ( "background-color", "#161616" )
--                    ,   ( "transform", "translate("
--                        ++ (Tuple.first model.origin |> toString)
--                        ++ "px, "
--                        ++ (Tuple.second model.origin |> toString)
--                        ++ "px)"
--                        )
                , Events.onClick TriggerPause
                ]
        -- , mergeHtmlLayers model |> div [ H.class "html-layers"]
        , model.gui
            |> Maybe.map Gui.view
            |> Maybe.map (Html.map GuiMessage)
            |> Maybe.map (\guiLayer -> div [ H.class "hide-on-space" ] [ guiLayer ])
            |> Maybe.withDefault (div [] [])
        ]


main : Program {} Model Msg
main =
    Browser.element
        { init = always init
        , view = view
        , subscriptions = subscriptions
        , update = update
        }


-- INCOMING PORTS

port bang : (() -> msg) -> Sub msg

port changeMode : (String -> msg) -> Sub msg

port pause : (() -> msg) -> Sub msg

port continue : (() -> msg) -> Sub msg

port triggerPause : (() -> msg) -> Sub msg

port hideControls : (() -> msg) -> Sub msg

port rotate : (Float -> msg) -> Sub msg

port initLayers : (Array String -> msg) -> Sub msg

port configureLorenz : ({ value: Lorenz.Model, layer: LayerIndex } -> msg) -> Sub msg

port configureFss : ({ value: FSS.PortModel, layer: LayerIndex } -> msg) -> Sub msg

port configureMirroredFss : ({ value: FSS.PortModel, layer: LayerIndex } -> msg) -> Sub msg

port changeProduct : (String -> msg) -> Sub msg

port rebuildFss : ({ value: FSS.SerializedScene, layer: LayerIndex } -> msg) -> Sub msg

port turnOn : (LayerIndex -> msg) -> Sub msg

port turnOff : (LayerIndex -> msg) -> Sub msg

port mirrorOn : (LayerIndex -> msg) -> Sub msg

port mirrorOff : (LayerIndex -> msg) -> Sub msg

port import_ : (String -> msg) -> Sub msg

port changeFssRenderMode : ({ value: String, layer: LayerIndex } -> msg) -> Sub msg

port changeFacesX : ({ value: Int, layer: LayerIndex } -> msg) -> Sub msg

port changeFacesY : ({ value: Int, layer: LayerIndex } -> msg) -> Sub msg

port changeLightSpeed : ({ value: Int, layer: LayerIndex } -> msg) -> Sub msg

port changeVignette : ({ value: FSS.Vignette, layer: LayerIndex } -> msg) -> Sub msg

port changeIris : ({ value: FSS.Iris, layer: LayerIndex } -> msg) -> Sub msg

port changeAmplitude : ({ value: FSS.AmplitudeChange, layer: LayerIndex } -> msg) -> Sub msg

port shiftColor : ({ value: FSS.ColorShiftPatch, layer: LayerIndex } -> msg) -> Sub msg

port changeOpacity : ({ value: FSS.Opacity, layer: LayerIndex } -> msg) -> Sub msg

port setCustomSize : ((Int, Int) -> msg) -> Sub msg

port applyRandomizer : (PortModel -> msg) -> Sub msg

port savePng : (() -> msg) -> Sub msg

port changeWGLBlend :
    ( { layer : Int
      , value : WGLBlend.Blend
      }
    -> msg) -> Sub msg

port changeHtmlBlend :
    ( { layer : Int
      , value : String
      }
    -> msg) -> Sub msg


-- OUTGOING PORTS

type alias SizeUpdate =
    { size: Size
    , product: String
    , coverSize: Size
    , background: String
    }

port startGui : PortModel -> Cmd msg

port requestFssRebuild :
    { layer: LayerIndex
    , model: PortModel
    , value: FSS.PortModel
    } -> Cmd msg

port presetSizeChanged : SizeUpdate -> Cmd msg

port export_ : String -> Cmd msg

port exportZip_ : String -> Cmd msg

port triggerSavePng : SizeUpdate -> Cmd msg

port requestRandomize : PortModel -> Cmd msg

port requestFitToWindow : () -> Cmd msg

-- port rebuildOnClient : (FSS.SerializedScene, Int) -> Cmd msg
