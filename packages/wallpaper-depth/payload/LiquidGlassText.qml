import QtQuick
import QtQuick.Effects

// Layered Liquid Glass approximation for the wallpaper clock.
//
// The effect intentionally uses Qt Quick's built-in effects only: no custom
// shader compilation, extra plugin, or new runtime dependency is required.
// It combines a lightly frosted backdrop, two subtle offset samples to suggest
// lensing, adaptive tint, angled specular sheen, a soft lift shadow, and paired
// bright/dark edge rims. True per-pixel refraction would require a custom shader.
Item {
    id: glass

    property var host: null
    readonly property bool usable: host !== null && host.backdrop !== null && host.textItem !== null

    readonly property var t: host ? host.textItem : null
    readonly property real tw: t ? Math.ceil(t.implicitWidth) : 0
    readonly property real th: t ? Math.ceil(t.implicitHeight) : 0
    readonly property real pad: Math.max(24, Math.ceil(th * 0.15))
    readonly property real rx: t ? Math.round(t.x - pad) : 0
    readonly property real ry: t ? Math.round(t.y - pad) : 0
    readonly property real rw: tw + 2 * pad
    readonly property real rh: th + 2 * pad
    readonly property real ss: host ? host.glassSupersample : 1
    readonly property real rim: Math.max(1.25, th * 0.009)
    readonly property real frost: host ? host.glassFrost / 100 : 0.4
    readonly property real tint: host ? host.glassTint / 100 : 0.35
    readonly property real shine: host ? host.glassHighlight / 100 : 0.7

    // A restrained crop magnifies the sampled wallpaper by a few percent.
    // The lateral samples add a very subtle refractive/edge-lensing impression
    // without producing the conspicuous ghosting of large image offsets.
    readonly property real sampleInset: Math.min(rw, rh) * 0.014
    readonly property real sampleWidth: Math.max(1, rw - 2 * sampleInset)
    readonly property real sampleHeight: Math.max(1, rh - 2 * sampleInset)
    readonly property real lensShift: Math.max(1.0, Math.min(4.0, th * 0.012))
    readonly property bool sampleLive: settling || (host ? host.moving : false)

    property bool settling: true
    property bool shown: false
    property real sweepProgress: 1.4

    function kick() {
        settling = true;
        settleEnd.restart();
    }

    // A single soft glint when the wallpaper changes or the clock is moved
    // gives the material a little responsiveness without a permanent animation.
    function playSweep() {
        if (shine <= 0.01)
            return;
        sweepAnimation.stop();
        sweepProgress = -0.28;
        sweepAnimation.start();
    }

    opacity: shown ? 1 : 0.01
    Behavior on opacity {
        NumberAnimation {
            duration: glass.host ? 220 : 0
            easing.type: Easing.OutCubic
        }
    }

    // Shape-only sources are rendered at the clock's selected supersampling
    // factor to keep large glyphs and narrow counters crisp.
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
        layer.textureSize: Qt.size(
            Math.max(1, Math.round(width * glass.ss)),
            Math.max(1, Math.round(height * glass.ss)))

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
    Glyph { id: shiftedTL; dx: glass.rim; dy: glass.rim }
    Glyph { id: shiftedBR; dx: -glass.rim; dy: -glass.rim }

    // Main backdrop sample. It is refreshed while the wallpaper/clock is
    // settling or moving, then held still so idle desktops do not resample it.
    ShaderEffectSource {
        id: backdropTex
        visible: false
        width: glass.rw
        height: glass.rh
        sourceItem: glass.host ? glass.host.backdrop : null
        sourceRect: Qt.rect(
            glass.rx + glass.sampleInset,
            glass.ry + glass.sampleInset,
            glass.sampleWidth,
            glass.sampleHeight)
        live: glass.sampleLive
        recursive: false
    }

    // Positive and negative displacement samples imitate a small amount of
    // lensing near the character strokes. Their low opacity avoids obvious
    // double images on high-detail wallpapers.
    ShaderEffectSource {
        id: refractPositive
        visible: false
        width: glass.rw
        height: glass.rh
        sourceItem: glass.host ? glass.host.backdrop : null
        sourceRect: Qt.rect(
            glass.rx + glass.sampleInset + glass.lensShift,
            glass.ry + glass.sampleInset - glass.lensShift * 0.28,
            glass.sampleWidth,
            glass.sampleHeight)
        live: glass.sampleLive
        recursive: false
    }

    ShaderEffectSource {
        id: refractNegative
        visible: false
        width: glass.rw
        height: glass.rh
        sourceItem: glass.host ? glass.host.backdrop : null
        sourceRect: Qt.rect(
            glass.rx + glass.sampleInset - glass.lensShift,
            glass.ry + glass.sampleInset + glass.lensShift * 0.28,
            glass.sampleWidth,
            glass.sampleHeight)
        live: glass.sampleLive
        recursive: false
    }

    // Lift the digits from the background. The shadow is soft and low contrast,
    // so it should read as separation rather than a dark outline.
    MultiEffect {
        x: glass.rx
        y: glass.ry + glass.th * 0.025
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        colorization: 1.0
        colorizationColor: "#080e18"
        blurEnabled: true
        blurMax: 32
        blur: 0.42
        opacity: 0.28
    }

    // Clear material layer. Some blur remains in the Clear preset so that the
    // effect still reads as glass; higher Frost settings progressively scatter
    // more detail instead of turning the letters into opaque cloudy shapes.
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: backdropTex
        autoPaddingEnabled: false
        blurEnabled: true
        blurMax: 32
        blur: 0.035 + glass.frost * 0.48
        saturation: 0.78
        brightness: 0.025
        contrast: 0.08
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    // Slightly shifted image content adds a restrained refraction cue. These
    // layers disappear progressively as the Frost setting increases.
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: refractPositive
        autoPaddingEnabled: false
        saturation: 1.08
        brightness: 0.025
        contrast: 0.08
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: 0.105 * (1.0 - glass.frost * 0.45)
    }

    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: refractNegative
        autoPaddingEnabled: false
        saturation: 0.94
        brightness: 0.01
        contrast: 0.04
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: 0.055 * (1.0 - glass.frost * 0.45)
    }

    // The tint follows the selected/adaptive clock color. Lower strength than
    // a normal frosted panel keeps the wallpaper's colors present in the glyphs.
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        colorization: 1.0
        colorizationColor: glass.host ? glass.host.clockFill : "white"
        opacity: glass.tint * 0.42
    }

    // Angled, broad specular sheen. The gradient is intentionally soft and
    // quiet; the edge-highlight setting controls it as well as the rim lights.
    Item {
        id: sheen
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(
            Math.max(1, Math.round(width * glass.ss)),
            Math.max(1, Math.round(height * glass.ss)))

        Rectangle {
            x: -parent.width * 0.10
            y: -parent.height * 0.10
            width: parent.width * 1.20
            height: parent.height * 1.20
            rotation: -13
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.30) }
                GradientStop { position: 0.32; color: Qt.rgba(1, 1, 1, 0.10) }
                GradientStop { position: 0.62; color: Qt.rgba(1, 1, 1, 0.015) }
                GradientStop { position: 1.0; color: Qt.rgba(0.02, 0.04, 0.08, 0.12) }
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
        opacity: glass.shine * 0.75
    }

    // A brief glancing reflection travels over the glyphs after meaningful
    // changes. It is event-driven rather than looping, so it costs no idle
    // animation frames. A soft alpha gradient keeps the sweep from looking
    // like a hard white stripe.
    Item {
        id: sweepTex
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(
            Math.max(1, Math.round(width * glass.ss)),
            Math.max(1, Math.round(height * glass.ss)))

        Rectangle {
            width: Math.max(20, glass.rh * 1.05)
            height: Math.max(8, glass.rw * 0.055)
            x: glass.sweepProgress * glass.rw - width / 2
            y: (glass.rh - height) / 2
            rotation: 74
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.0) }
                GradientStop { position: 0.34; color: Qt.rgba(1, 1, 1, 0.035) }
                GradientStop { position: 0.50; color: Qt.rgba(1, 1, 1, 0.18) }
                GradientStop { position: 0.66; color: Qt.rgba(1, 1, 1, 0.035) }
                GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
            }
        }
    }

    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: sweepTex
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: glass.shine * 0.9
    }

    NumberAnimation {
        id: sweepAnimation
        target: glass
        property: "sweepProgress"
        from: -0.28
        to: 1.28
        duration: 820
        easing.type: Easing.OutCubic
    }

    // Bright upper-left rim and a subtle cool/dark lower-right rim create the
    // sense of thickness without drawing a uniform cartoon-like outline.
    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        colorization: 1.0
        colorizationColor: "#ffffff"
        maskEnabled: true
        maskSource: shiftedTL
        maskInverted: true
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: glass.shine * 0.82
    }

    MultiEffect {
        x: glass.rx
        y: glass.ry
        width: glass.rw
        height: glass.rh
        source: shape
        autoPaddingEnabled: false
        colorization: 1.0
        colorizationColor: "#344152"
        maskEnabled: true
        maskSource: shiftedBR
        maskInverted: true
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: glass.shine * 0.34
    }

    Timer { id: settleEnd; interval: 6000; onTriggered: glass.settling = false }
    Timer { id: reveal; interval: 250; onTriggered: glass.shown = true }
    onRwChanged: kick()
    onRhChanged: kick()

    Connections {
        target: glass.host
        function onSourceChanged() { glass.kick(); glass.playSweep(); }
        function onReadyChanged() { glass.kick(); if (glass.host && glass.host.ready) glass.playSweep(); }
        function onMovingChanged() {
            glass.kick();
            if (glass.host && glass.host.moving) glass.playSweep();
        }
    }

    Component.onCompleted: {
        kick();
        playSweep();
        reveal.restart();
    }
}
