// index.js
'use strict';

// include main style
require('./index.css');

const deepClone = require('./deep-clone.js');
const JSZip = require('jszip');
const JSZipUtils = require('jszip-utils');
const FileSaver = require('jszip/vendor/FileSaver');

// initialize Elm Application
const App = require('./src/Main.elm');
//const mountNode = document.getElementById('elm-target');
const mountNode = document.getElementById('js-animation');
// The third value on embed are the initial values for incomming ports into Elm
const app = App.Main.embed(mountNode);

// mountNode.addEventListener('click', function() {
//     app.ports.pause.send(null);
// });

//const registerToolkit = require('./toolkit.js');
// const startPatching = require('./patch.js');
const startGui = require('./gui.js');

//const LayersNode = require('./src/LayersNode.elm').LayersNode;

const buildFSS = require('./fss.js');

// const defaultConfig =
//     { lights:
//         { ambient: [ '#000000', '#f45b69' ]
//         , diffuse:  [ '#000000', '#e4fde1' ]
//         , speed: 400
//         , count: 2
//         }
//     , material: [ '#ffffff', '#ffffff' ]
//     , xRange: 0.8
//     , yRange: 0.1
//     , size: [ 3550, 3200 ]
//     , faces: [ 35, 35 ]
//     , mirror: 0.5
//     };

// let layerOneConfig = deepClone(defaultConfig);
// layerOneConfig.lights.ambient = [ '#000000', '#f45b69' ];
// layerOneConfig.lights.diffuse = [ '#000000', '#e4fde1' ];

// let layerTwoConfig = deepClone(defaultConfig);
// layerTwoConfig.lights.ambient = [ '#000000', '#4b4e76' ];
// layerOneConfig.lights.diffuse = [ '#000000', '#fb4e76' ];

// let layers = [
//     { type: 'fss-mirror', config: layerOneConfig
//     },
//     { type: 'fss-mirror', config: layerTwoConfig
//     },
//     { type: 'svg' }
// ];

let scenes = {};

// let layersNode = null;
// let paletteNode = null;

const updateFssLayer = (index, config) => {
    const scene = buildFSS(config);
    app.ports.configureMirroredFss.send([ config, index ]);
    app.ports.rebuildFss.send([ scene, index ]);
    if (layers[index]) {
        layers[index].config = deepClone(config);
    }
    scenes[index] = scene;
}

const updateAllFssLayers = (updateConfig) => {
    layers.forEach((layer, index) => {
        if (layer.type == 'fss-mirror') {
            updateFssLayer(index,
                updateConfig(deepClone(layer.config)));
        }
    });
}

const updateFssColors = (index, colors) => {
    // debugger;
    let newConfig = deepClone(defaultConfig);
    newConfig.lights.ambient[1] = colors[0];
    newConfig.lights.diffuse[1] = colors[1];
    updateFssLayer(index, newConfig);
}

const exportScene = (scene) => {
    //console.log(scene);
    return scene.meshes[0].geometry.vertices.map((vertex) => (
        { v0: vertex.v0,
          time: vertex.time,
          anchor: vertex.anchor,
          gradient: vertex.gradient
        }
    ));
}

const import_ = (app, importedState) => {
    const parsedState = JSON.parse(importedState);
    scenes = {};
    layers = [];
    parsedState.layers.forEach((layer, index) => {
        layers[index] = {
            type: layer.type,
            config: layer.config
        };
        //scenes[index] = layer.scene;
    });
    app.ports.pause.send(null);
    app.ports.initLayers.send(layers.map((l) => l.type));
    app.ports.import_.send(JSON.stringify({
        theta: parsedState.theta,
        size: parsedState.size,
        origin: parsedState.origin,
        mouse: parsedState.mouse,
        now: parsedState.now,
        layers: parsedState.layers.map((layer) => (
            { type_ : layer.type,
              blend: layer.blend,
              config: ''
            }
        ))
    }));
    parsedState.layers.forEach((layer, index) => {
        if (layer.type == 'fss-mirror') {
            const scene = buildFSS(layer.config, layer.sceneFuzz);
            scenes[index] = scene;
            app.ports.configureMirroredFss.send([ layer.config, index ]);
            app.ports.rebuildFss.send([ scene, index ]);
        }
    });
    const mergedBlends = parsedState.layers.map(layer => layer.blend).join(':');
    window.location.hash = '#blends=' + mergedBlends;
    //if (layersNode) layersNode.inlets['code'].receive(mergedBlends);
}

const export_ = (app, exportedState) => {
    app.ports.pause.send(null);
    const stateObj = JSON.parse(exportedState);
    stateObj.layers.forEach((layer, index) => {
        layer.config = layers[index] && layers[index].config ? layers[index].config : {};
        if (layer.config['lights']) {
            console.log(index, 'ambient', layer.config.lights.ambient);
            console.log(index, 'diffuse', layer.config.lights.diffuse);
        } else {
            console.log(index, 'no lights');
        }
        layer.sceneFuzz = layer.type == 'fss-mirror'
            ? exportScene(scenes[index]) || exportScene(buildFSS(layer.config))
            : null;
    })
    console.log(stateObj);
    return JSON.stringify(stateObj, null, 2);
}

// const promisedLoad = (filename) => {
//     return new Promise((resolve, reject) => {
//         JSZipUtils.getBinaryContent((err, content) => {
//             if (err) reject(err);
//             else resolve(content);
//         });
//     });
// }

const exportZip_ = (app, exportedState) => {
    JSZipUtils.getBinaryContent(
        './player.bundle.js', (err, playerBundle) => {
        if (err) { throw err; }

        JSZipUtils.getBinaryContent(
            './index.player.html',
            (err, playerHtml) => {
            if (err) { throw err; }

            const sceneJson = export_(app, exportedState);
            const zip = new JSZip();
            // const js = zip.folder("js");
            // js.file('run-scene.js', runScene, { binary: true });
            // js.file(zipMinified ? 'Main.min.js' : 'Main.js', elmApp, { binary: true });
            // js.file('scene.js', 'window.jsGenScene = ' + sceneJson + ';');
            zip.file('player.bundle.js', playerBundle, { binary: true });
            zip.file('scene.js', 'window.jsGenScene = ' + sceneJson + ';');
            zip.file('index.html', playerHtml, { binary: true });
            zip.generateAsync({type:"blob"})
                .then(function(content) {
                    new FileSaver(content, "export.zip");
                });
        });
    });
}

const prepareImportExport = () => {
    app.ports.export_.subscribe((exportedState) => {
        const exportCode = export_(app, exportedState);

        document.getElementById('export-target').className = 'shown';
        document.getElementById('export-code').value = exportCode;
    });
    app.ports.exportZip_.subscribe((exportedState) => {
        try {
            console.log('exportedState', exportedState);
            exportZip_(app, exportedState);
        } catch(e) {
            console.error(e);
            alert('Failed to create .zip');
        }
    });
    document.getElementById('close-export').addEventListener('click', () => {
        document.getElementById('export-target').className = '';
    });
    document.getElementById('close-import').addEventListener('click', () => {
        document.getElementById('import-target').className = '';
    });
    setTimeout(() => {
        document.getElementById('import-button').addEventListener('click', () => {
            document.getElementById('import-target').className = 'shown';
        });
    }, 100);
    document.getElementById('import').addEventListener('click', () => {
        try {
            if (document.getElementById('import-code').value) {
                import_(app, document.getElementById('import-code').value);
            } else {
                alert('Nothing to import');
            }
        } catch(e) {
            console.error(e);
            alert('Failed to parse or send, incorrect format?');
        }
    });

}

const resize = () => {
    layers = layers.map((layer) => {
        if (layer.type == 'fss-mirror') {
            const newLayer = deepClone(layer);
            newLayer.config.size = [Math.floor(window.innerWidth * 2.5), Math.floor(window.innerHeight * 2.5)];
            //newLayer.config.faces = [Math.floor(window.innerWidth / 300), Math.floor(window.innerHeight / 300)];
            return newLayer;
        } else {
            return layer;
        }
    });
    console.log(layers.map(layer => {
        return (layer.type == 'fss-mirror') ? [layer.config.size, layer.config.faces, layer.config.lights.lightspeed] : [];
    }));
}

const rebuild = () => {
    layers.forEach((layer, index) => {
        if (layer.type == 'fss-mirror') {
            updateFssLayer(index, layer.config);
        }
    });
}

//registerToolkit(app, LayersNode, updateFssColors);

// app.ports.initLayers.send(layers.map((l) => l.type));

prepareImportExport();

setTimeout(function() {

    app.ports.startGui.subscribe(function(data) {
        console.log('startGui', data);
        const gui = startGui(
            data.config.layers,
            data.config,
            data.palettes,
            { updateAllFssLayers
            , updateFssColors
            , changeWGLBlend : (index, blend) =>
                { app.ports.changeWGLBlend.send({ layer: index, blend: blend }) }
            , changeSVGBlend : (index, blend) =>
                { app.ports.changeSVGBlend.send({ layer: index, blend: blend }) }
            , changeProduct : (id) =>
                { app.ports.changeProduct.send(id) }
            });
        resize();
        rebuild();
    });

    app.ports.bang.send(null);

    let panelsHidden = false;

    document.addEventListener('keydown', (event) => {
        if (event.keyCode == 32) {
            const overlayPanels = document.querySelectorAll('.hide-on-space');
            for (let i = 0; i < overlayPanels.length; i++) {
                overlayPanels[i].style.display = panelsHidden ? 'block' : 'none';
            }
            panelsHidden = !panelsHidden;
        }
      });

    // window.addEventListener('resize', () => {
    //     resize();
    //     rebuild();
    // });

    // setTimeout(function() {
    //     //updateFssColors(0, ['#000000', '#ffffff']);
    //     updateFssColors(1, ['#ffffff', '#000000']);
    // }, 100);
}, 100);


