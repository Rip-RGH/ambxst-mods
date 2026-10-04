import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services
import qs.modules.theme
import qs.config

// Clock drawn *behind* a cutout of the wallpaper's foreground.
// Lives inside the wallpaper window, above the wallpaper, so it can sit
// between the two. Generation is lazy: nothing shows until the cutout exists.
Item {
    id: root

    property string source          // wallpaper path ("" disables the layer)
    property Item backdrop: null    // the wallpaper item, sampled by the glass style

    // Must match "id" in ambxst.mod.json.
    readonly property string modId: "rip-rgh.wallpaper-depth"

    // User settings (see settings.schema.json). Defaults mirror the schema and
    // are used until the real values arrive, or if they never do.
    property bool effectEnabled: true
    property int threshold: 30      // 0-100
    property int feather: 8         // px
    property int clockSize: 22      // % of screen height
    property string clockColor: "auto"   // auto | light | dark | theme
    property string clockPosition: "center"
    property string clockFormat: "h24"      // h24 | h24s | h12 | h12s | custom
    property string customFormat: "HH:mm"   // used when clockFormat is custom
    property bool liquidGlass: false        // solid style when false
    property int glassFrost: 40             // 0-100, blur inside the glyphs
    property int glassTint: 35              // 0-100
    property int glassHighlight: 70         // 0-100, rim light strength
    property string fontFamily: ""          // "" = default font
    property string fontWeightName: "bold"
    property int offsetX: 0         // % of screen width, fine-tune on top of the preset
    property int offsetY: 0         // % of screen height
    property bool settingsLoaded: false
    property int settingsTries: 0

    function applySetting(key, value) {
        if (key === "enabled")
            effectEnabled = Boolean(value);
        else if (key === "threshold")
            threshold = Number(value);
        else if (key === "feather")
            feather = Number(value);
        else if (key === "clockSize")
            clockSize = Number(value);
        else if (key === "clockColor")
            clockColor = String(value);
        else if (key === "clockPosition")
            clockPosition = String(value);
        else if (key === "clockFormat")
            clockFormat = String(value);
        else if (key === "customFormat")
            customFormat = String(value);
        else if (key === "liquidGlass")
            liquidGlass = Boolean(value);
        else if (key === "glassFrost")
            glassFrost = Number(value);
        else if (key === "glassTint")
            glassTint = Number(value);
        else if (key === "glassHighlight")
            glassHighlight = Number(value);
        else if (key === "fontFamily")
            fontFamily = String(value).trim();
        else if (key === "fontWeight")
            fontWeightName = String(value);
        else if (key === "offsetX")
            offsetX = Number(value);
        else if (key === "offsetY")
            offsetY = Number(value);
    }

    function loadSettings() {
        settingsTries++;
        ModsService.getSettings(modId, (settings, error) => {
            if (!error && settings && settings.values) {
                for (const key of Object.keys(settings.values))
                    applySetting(key, settings.values[key]);
                settingsLoaded = true;
                checkFont();
                generate();
            } else if (settingsTries < 5) {
                retryTimer.restart();      // backend may not be up yet
            } else {
                console.warn("wallpaper-depth: using default settings:", error);
                settingsLoaded = true;
                generate();
            }
        });
    }

    Timer {
        id: retryTimer
        interval: 2000
        onTriggered: root.loadSettings()
    }

    Connections {
        target: ModsService
        function onSettingChanged(id, key, value) {
            if (id === root.modId)
                root.applySetting(key, value);
        }
    }

    // ---- Clock text: format, font, weight ----------------------------------
    readonly property var formats: ({
        h24: "HH:mm", h24s: "HH:mm:ss", h12: "h:mm AP", h12s: "h:mm:ss AP"
    })
    readonly property string activeFormat: clockFormat === "custom"
        ? (customFormat.trim() !== "" ? customFormat : "HH:mm")
        : (formats[clockFormat] || "HH:mm")
    // Qt format letters: 's' (outside quoted text) means seconds are shown.
    readonly property bool showsSeconds: activeFormat.replace(/'[^']*'/g, "").indexOf("s") >= 0

    readonly property var weights: ({
        thin: Font.Thin, extraLight: Font.ExtraLight, light: Font.Light,
        normal: Font.Normal, medium: Font.Medium, demiBold: Font.DemiBold,
        bold: Font.Bold, extraBold: Font.ExtraBold, black: Font.Black
    })
    function makeFont(px) {
        const f = {
            pixelSize: Math.max(8, Math.round(px)),
            weight: weights[fontWeightName] ?? Font.Bold
        };
        if (fontFamily !== "")
            f.family = fontFamily;
        return Qt.font(f);
    }

    // Long formats (seconds, weekday names...) shrink to fit instead of running
    // off the screen: measure the text at a reference size, cap it at 90% of the width.
    TextMetrics {
        id: refSizer
        font: root.makeFont(100)
        text: sizer.text
    }
    readonly property real fitPx: (refSizer.width > 0 && width > 0)
        ? 0.9 * width / refSizer.width * 100 : 100000
    readonly property font clockFont: makeFont(Math.min(height * clockSize / 100, fitPx))

    function checkFont() {
        if (fontFamily === "" || !settingsLoaded)
            return;
        try {
            if (Qt.fontFamilies().indexOf(fontFamily) < 0)
                console.warn("wallpaper-depth: font not found, falling back:", fontFamily);
        } catch (e) {}
    }
    onFontFamilyChanged: checkFont()

    // Layout uses a sample with every digit set to "0", so the clock doesn't
    // shuffle sideways each minute as digit widths change.
    TextMetrics {
        id: sizer
        font: root.clockFont
        text: Qt.formatDateTime(clock.date, root.activeFormat).replace(/[0-9]/g, "0")
    }

    // ---- Clock placement -------------------------------------------------
    // Preset = (horizontal, vertical) as 0 / 0.5 / 1 across the screen. Edge
    // presets keep a margin; offsetX/offsetY then nudge in percent of the screen.
    readonly property var presets: ({
        topLeft: [0, 0], topCenter: [0.5, 0], topRight: [1, 0],
        centerLeft: [0, 0.5], center: [0.5, 0.5], centerRight: [1, 0.5],
        bottomLeft: [0, 1], bottomCenter: [0.5, 1], bottomRight: [1, 1]
    })
    readonly property var anchorFrac: presets[clockPosition] || presets.center
    readonly property real marginX: width * 0.05
    readonly property real marginY: height * 0.06

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    readonly property real clockX: clamp(
        marginX + (width - sizer.width - 2 * marginX) * anchorFrac[0] + width * offsetX / 100,
        0, Math.max(0, width - sizer.width))
    readonly property real clockY: clamp(
        marginY + (height - sizer.height - 2 * marginY) * anchorFrac[1] + height * offsetY / 100,
        0, Math.max(0, height - sizer.height))

    // Clock centre as whole percents of the screen: depth.py measures the
    // wallpaper brightness there. Debounced so dragging a value doesn't spam it.
    readonly property int clockCx: width > 0 ? Math.round((clockX + sizer.width / 2) / width * 100) : 50
    readonly property int clockCy: height > 0 ? Math.round((clockY + sizer.height / 2) / height * 100) : 50
    readonly property int clockW: width > 0 ? Math.max(1, Math.round(sizer.width / width * 100)) : 30
    readonly property int clockH: height > 0 ? Math.max(1, Math.round(sizer.height / height * 100)) : 20
    onClockCxChanged: remeasure.restart()
    onClockCyChanged: remeasure.restart()
    onClockWChanged: remeasure.restart()
    onClockHChanged: remeasure.restart()

    Timer {
        id: remeasure
        interval: 250
        onTriggered: root.generate(true)
    }

    // Relative luminance of the visible background behind the clock, reported
    // by depth.py (-1 = not measured yet). 0.179 is where black and white text
    // have equal contrast, so brighter than that gets dark text.
    property real luminance: -1
    readonly property color darkText: "#161616"
    readonly property color lightText: "#f4f4f4"
    readonly property color clockFill: {
        if (clockColor === "light") return lightText;
        if (clockColor === "dark") return darkText;
        if (clockColor === "theme" || luminance < 0) return Colors.overBackground;
        return luminance > 0.179 ? darkText : lightText;
    }

    property bool ready: false
    property bool pending: false

    // The solid Text doubles as the layout/animation source for the glass style.
    readonly property Item textItem: clockText
    readonly property bool moving: clockText.x !== clockX || clockText.y !== clockY
    // Glass is used only if it loaded and has something to sample; otherwise the
    // solid clock stays, so a problem in LiquidGlassText.qml can't blank the clock.
    readonly property bool glassActive: liquidGlass && glassLoader.status === Loader.Ready
        && glassLoader.item !== null && glassLoader.item.usable

    readonly property string cutout: Quickshell.env("HOME") + "/.cache/ambxst/depth/"
        + Qt.md5(source) + "-" + threshold + "-" + feather + ".png"
    readonly property string script: Qt.resolvedUrl("depth.py").toString().replace("file://", "")

    function generate(keepVisible) {
        if (!keepVisible)
            ready = false;
        if (!settingsLoaded || !source || !effectEnabled)
            return;
        if (gen.running) {
            pending = true;
            return;
        }
        // Prefer the venv python if the user set one up, else system python3.
        gen.command = ["sh", "-c",
            'PY="$HOME/.local/share/ambxst/depth/venv/bin/python"; [ -x "$PY" ] || PY=python3; exec "$PY" "$@"',
            "sh", script, source, cutout, String(threshold), String(feather),
            String(clockCx), String(clockCy), String(clockW), String(clockH)];
        gen.running = true;
    }

    onCutoutChanged: generate()
    onEffectEnabledChanged: generate()
    Component.onCompleted: loadSettings()

    opacity: fg.status === Image.Ready ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        enabled: Config.animDuration > 0
        NumberAnimation {
            duration: Config.animDuration
            easing.type: Easing.OutCubic
        }
    }

    SystemClock {
        id: clock
        precision: root.showsSeconds ? SystemClock.Seconds : SystemClock.Minutes
    }

    // layer 1: the clock (behind the cutout)
    Text {
        id: clockText
        visible: !root.glassActive
        x: root.clockX
        y: root.clockY
        Behavior on x {
            enabled: root.settingsLoaded && Config.animDuration > 0
            NumberAnimation {
                duration: Config.animDuration
                easing.type: Easing.OutCubic
            }
        }
        Behavior on y {
            enabled: root.settingsLoaded && Config.animDuration > 0
            NumberAnimation {
                duration: Config.animDuration
                easing.type: Easing.OutCubic
            }
        }
        text: Qt.formatDateTime(clock.date, root.activeFormat)
        color: root.clockFill
        Behavior on color {
            ColorAnimation {
                duration: Config.animDuration
                easing.type: Easing.OutCubic
            }
        }
        opacity: 0.9
        font: root.clockFont
    }

    // glass style (optional): loaded only when enabled
    Loader {
        id: glassLoader
        anchors.fill: parent
        active: root.liquidGlass && root.backdrop !== null
        source: "LiquidGlassText.qml"
        onLoaded: item.host = root
        onStatusChanged: {
            if (status === Loader.Error)
                console.warn("wallpaper-depth: liquid glass failed to load, using solid style");
        }
    }

    // layer 2: the foreground cutout. Same crop settings as the wallpaper Image.
    Image {
        id: fg
        anchors.fill: parent
        source: root.ready ? "file://" + root.cutout : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: root.width
        sourceSize.height: root.height
        asynchronous: true
        cache: false
        mipmap: true
        smooth: true
    }

    Process {
        id: gen
        stdout: StdioCollector {
            onStreamFinished: {
                const v = parseFloat(text);
                if (!isNaN(v))
                    root.luminance = v;
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.length > 0)
                    console.warn("wallpaper-depth:", text);
            }
        }
        onExited: code => {
            if (root.pending) {
                root.pending = false;
                root.generate();
                return;
            }
            if (code === 0)
                root.ready = true;
            else
                console.warn("wallpaper-depth: generation failed with code", code);
        }
    }
}
