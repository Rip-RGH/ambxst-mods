import QtQuick
import QtQuick.Effects

// Liquid-glass rendering of the clock. Loaded on demand by DepthLayer; if this
// file fails to load, DepthLayer keeps showing the solid clock.
//
// Look: the wallpaper seen through the glyphs (frosted and slightly magnified,
// like a lens), a faint tint, a bright rim on the top-left edges, a softer rim
// on the bottom-right, and a soft shadow underneath.
Item {
    id: glass

    property var host: null     // the DepthLayer; every setting is read from it
    readonly property bool usable: host !== null && host.backdrop !== null && host.textItem !== null

    // Geometry follows the (animated) solid Text, plus padding for the rims.
    readonly property var t: host ? host.textItem : null
    readonly property real tw: t ? Math.ceil(t.implicitWidth) : 0
    readonly property real th: t ? Math.ceil(t.implicitHeight) : 0
    readonly property real pad: Math.max(24, Math.ceil(th * 0.15))
    readonly property real rx: t ? Math.round(t.x - pad) : 0     // whole pixels: no resampling blur
    readonly property real ry: t ? Math.round(t.y - pad) : 0
    readonly property real rw: tw + 2 * pad
    readonly property real rh: th + 2 * pad
    readonly property real ss: host ? host.glassSupersample : 1   // glyph shapes are drawn at this multiple
    readonly property real rim: Math.max(1.5, th * 0.012)           // rim thickness in px
    readonly property real frost: host ? host.glassFrost / 100 : 0.4
    readonly property real tint: host ? host.glassTint / 100 : 0.15
    readonly property real shine: host ? host.glassHighlight / 100 : 0.7

    // The backdrop is captured live while "settling" (after start-up, a move, a
    // wallpaper change...) so late-loading images can never leave a stale or blank
    // capture; once things have been still for a while it stops, so an idle
    // desktop does no per-frame work.
    property bool settling: true
    property bool shown: false          // true once the first capture has had time to land
    function kick() {
        settling = true;
        settleEnd.restart();
    }
    opacity: shown ? 1 : 0.01           // not exactly 0: fully transparent items aren't rendered
    Behavior on opacity {
        NumberAnimation {
            duration: glass.host ? 220 : 0
            easing.type: Easing.OutCubic
        }
    }

    // A white copy of the glyphs, optionally shifted. Used as shape/mask sources.
    component Glyph: Item {
        property real dx: 0
        property real dy: 0
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(Math.max(1, Math.round(width * glass.ss)), Math.max(1, Math.round(height * glass.ss)))
        Text {
            x: glass.pad + parent.dx
            y: glass.pad + parent.dy
            text: glass.t ? glass.t.text : ""
            font: glass.host ? glass.host.clockFont : Qt.font({})
            color: "white"
            renderType: glass.host ? glass.host.textRenderType : Text.QtRendering
        }
    }

    Glyph { id: shape }
    Glyph { id: shiftedTL; dx: glass.rim; dy: glass.rim }      // glyph minus this = top-left rim
    Glyph { id: shiftedBR; dx: -glass.rim; dy: -glass.rim }    // ... = bottom-right rim

    // What is behind the glyphs, cropped a little tighter than the glyph box so
    // it comes out magnified. Static wallpaper, so only re-captured on demand.
    ShaderEffectSource {
        id: backdropTex
        visible: false
        width: glass.rw
        height: glass.rh
        sourceItem: glass.host ? glass.host.backdrop : null
        readonly property real inset: Math.min(glass.rw, glass.rh) * 0.012
        sourceRect: Qt.rect(glass.rx + inset, glass.ry + inset, glass.rw - 2 * inset, glass.rh - 2 * inset)
        live: glass.settling || (glass.host ? glass.host.moving : false)
        recursive: false
    }

    // soft shadow (sits under the opaque glass body, so it only shows outside it)
    MultiEffect {
        x: glass.rx
        y: glass.ry + glass.th * 0.035
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        colorization: 1.0
        colorizationColor: "black"
        blurEnabled: true
        blurMax: 32
        blur: 0.55
        opacity: 0.30
    }

    // the glass body: frosted backdrop clipped to the glyphs
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: backdropTex
        autoPaddingEnabled: false
        blurEnabled: true
        blurMax: 48
        blur: glass.frost
        saturation: 0.4
        brightness: 0.09
        contrast: 0.08
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    // tint: follows the clock colour (light on dark wallpapers, dark on bright ones)
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        colorization: 1.0
        colorizationColor: glass.host ? glass.host.clockFill : "white"
        opacity: glass.tint * 0.7
    }

    // sheen: a vertical gradient clipped to the glyphs, so the glass isn't flat
    Item {
        id: sheen
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.30) }
                GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.05) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.20) }
            }
        }
    }
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: sheen
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: 0.35 + glass.shine * 0.65
    }

    // rim light, top-left (bright)
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: shiftedTL
        maskInverted: true
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: glass.shine * 0.95
    }

    // rim light, bottom-right (softer)
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: shiftedBR
        maskInverted: true
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: glass.shine * 0.45
    }

    Timer { id: settleEnd; interval: 6000; onTriggered: glass.settling = false }
    Timer { id: reveal; interval: 250; onTriggered: glass.shown = true }
    onRwChanged: kick()
    onRhChanged: kick()
    Connections {
        target: glass.host
        function onSourceChanged() { glass.kick(); }
        function onReadyChanged() { glass.kick(); }
        function onMovingChanged() { glass.kick(); }
    }
    Component.onCompleted: {
        kick();
        reveal.restart();
    }
}
