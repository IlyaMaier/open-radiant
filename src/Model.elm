module Model exposing
    ( init
    , Model
    , ModelChange
    , Layer
    , LayerIndex
    , LayerDef
    , LayerModel(..)
    , LayerKind(..)
    , WebGLLayer(..)
    , SVGLayer(..)
    , CreateLayer
    , GuiConfig
    , Size
    , Pos
    , PortBlend
    , emptyLayer
    )

import Either exposing (Either)
import Time exposing (Time)

import WebGL.Blend as WGLBlend
import Svg.Blend as SVGBlend

import Product exposing (Product)
import Product
import Layer.Vignette as Vignette
import Layer.FSS as FSS
import Layer.Lorenz as Lorenz
import Layer.Fractal as Fractal
import Layer.Voronoi as Voronoi
import Layer.Template as Template

type alias LayerIndex = Int

type alias Size = (Int, Int)
type alias Pos = (Int, Int)

type alias ModelChange = LayerModel -> LayerModel

type alias CreateLayer = LayerKind -> ModelChange -> Layer

type LayerKind
    = Lorenz
    | Fractal
    | Template
    | Voronoi
    | Fss
    | MirroredFss
    | Text
    | SvgImage
    | Vignette
    | Empty


-- type LayerBlend
--     = WGLB WGLBlend.Blend
--     | SVGB SVGBlend.Blend


type LayerModel
    = LorenzModel Lorenz.Model
    | FractalModel Fractal.Model
    | VoronoiModel Voronoi.Model
    | FssModel FSS.Model
    | TemplateModel Template.Model
    | NoModel


type WebGLLayer
    = LorenzLayer Lorenz.Mesh
    | FractalLayer Fractal.Mesh
    | VoronoiLayer Voronoi.Mesh
    | TemplateLayer Template.Mesh
    | FssLayer (Maybe FSS.SerializedScene) FSS.Mesh
    | MirroredFssLayer (Maybe FSS.SerializedScene) FSS.Mesh
    | VignetteLayer


type SVGLayer
    = TextLayer
    | SvgImageLayer
    | NoContent


type alias Layer =
    Either
        ( WebGLLayer, WGLBlend.Blend )
        ( SVGLayer, SVGBlend.Blend )


-- `change` is needed since we store a sample layer model
-- to use for any layer in the main model
type alias LayerDef =
    { kind: LayerKind
    , layer: Layer
    , change: ModelChange
    , on: Bool
    }


-- kinda Either, but for ports:
--    ( Just WebGLBlend, Nothing ) --> WebGL Blend
--    ( Nothing, Just String ) --> SVG Blend
--    ( Nothing, Nothing ) --> None
--    ( Just WebGLBlend, Just String ) --> ¯\_(ツ)_/¯
type alias PortBlend =
    ( Maybe WGLBlend.Blend, Maybe SVGBlend.PortBlend )


type alias Model =
    { paused : Bool
    , autoRotate : Bool
    , fps : Int
    , theta : Float
    , layers : List LayerDef
    , size : Size
    , origin : Pos
    , mouse : (Int, Int)
    , now : Time
    , timeShift : Time
    , product : Product
    , vignette : Vignette.Model
    , fss : FSS.Model
    , lorenz : Lorenz.Model
    -- voronoi : Voronoi.Config
    -- fractal : Fractal.Config
    -- , lights (taken from product)
    -- , material TODO
    }


type alias GuiConfig =
    { product : String
    , palette : List String
    , layers : List
        { kind: String
        , blend : PortBlend
        , webglOrSvg: String
        , on: Bool
        }
    , size : ( Int, Int )
    , facesX : Int
    , facesY : Int
    , lightSpeed: Int
    , vignette: Float
    , amplitude : FSS.AmplitudeChange
    , customSize : Maybe (Int, Int)
    }


init
    :  List ( LayerKind, ModelChange )
    -> CreateLayer
    -> Model
init initialLayers createLayer
    = { paused = False
      , autoRotate = False
      , fps = 0
      , theta = 0.1
      , layers = initialLayers |> List.map
            (\(kind, change) ->
                { kind = kind
                , layer = createLayer kind change
                , change = change
                , on = True
                })
      , size = ( 1200, 1200 )
      , origin = ( 0, 0 )
      , mouse = ( 0, 0 )
      , now = 0.0
      , timeShift = 0.0
      --, range = ( 0.8, 1.0 )
      , product = Product.JetBrains
      , fss = FSS.init
      , vignette = Vignette.init
      , lorenz = Lorenz.init
      }


emptyLayer : Layer
emptyLayer =
    Either.Right ( NoContent, SVGBlend.default )