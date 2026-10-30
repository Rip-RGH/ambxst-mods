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
    property string textSmoothing: "smooth" // smooth | standard | native
    property string fontFamily: ""          // "" = default font
    property string fontWeightName: "bold"
    property string clockSpacing: "auto" // auto | tight | natural
    property int offsetX: 0         // % of screen width, fine-tune on top of the preset
    property int offsetY: 0         // % of screen height
    property bool settingsLoaded: false
    property int settingsTries: 0

    // Preset choices (enum settings) and the numbers they stand for. The option
    // *values* in settings.json are what Ambxst stores, so keep them stable;
    // labels can change freely. Unknown values fall back to the default.
    readonly property var frostLevels: ({ clear: 0, light: 20, medium: 40, strong: 60, heavy: 85 })
    readonly property var tintLevels: ({ none: 0, light: 15, medium: 35, strong: 55, smoked: 80 })
    readonly property var highlightLevels: ({ off: 0, soft: 40, medium: 70, bright: 100 })
    readonly property var thresholdLevels: ({ large: 15, balanced: 30, small: 50, minimal: 70 })
    readonly property var featherLevels: ({ sharp: 0, normal: 8, soft: 16, verySoft: 30 })

    function level(table, value, fallback) {
        const n = table[String(value)];
        return n === undefined ? fallback : n;
    }

    function applySetting(key, value) {
        if (key === "enabled")
            effectEnabled = Boolean(value);
        else if (key === "threshold")
            threshold = level(thresholdLevels, value, 30);
        else if (key === "feather")
            feather = level(featherLevels, value, 8);
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
            glassFrost = level(frostLevels, value, 40);
        else if (key === "glassTint")
            glassTint = level(tintLevels, value, 35);
        else if (key === "glassHighlight")
            glassHighlight = level(highlightLevels, value, 70);
        else if (key === "textSmoothing")
            textSmoothing = String(value);
        else if (key === "fontFamily")
            fontFamily = String(value).trim();
        else if (key === "fontWeight")
            fontWeightName = String(value);
        else if (key === "clockSpacing")
            clockSpacing = String(value);
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

    // Qt's normal weight request is enough for static font families. Variable
    // fonts need the OpenType `wght` axis requested explicitly on Qt 6.7+;
    // otherwise some faces can remain stuck at the font's default/minimum axis.
    // Keep both maps: Font.* gives Qt its native named weight, while the axis
    // values use the standard 100..900 scale defined by OpenType/CSS.
    readonly property var weights: ({
        thin: Font.Thin, extraLight: Font.ExtraLight, light: Font.Light,
        normal: Font.Normal, medium: Font.Medium, demiBold: Font.DemiBold,
        bold: Font.Bold, extraBold: Font.ExtraBold, black: Font.Black
    })
    readonly property var weightAxisValues: ({
        thin: 100, extraLight: 200, light: 300, normal: 400,
        medium: 500, demiBold: 600, bold: 700, extraBold: 800, black: 900
    })
    // CurveRendering and variable font axis support were both added in Qt 6.7.
    // This feature check avoids passing an unsupported property to older Qt.
    readonly property bool supportsVariableFontAxes: Text.CurveRendering !== undefined
    // Text anti-aliasing. "smooth" uses Qt's curve renderer (Qt 6.7+), which draws
    // large glyphs from their outlines with sharp corners and clean edges; older
    // Qt falls back to the standard renderer. "native" uses the font's own hinted
    // rasteriser. The glass style also draws its letter shapes at 2x for non-standard.
    readonly property int textRenderType: {
        if (textSmoothing === "native")
            return Text.NativeRendering;
        if (textSmoothing === "smooth" && Text.CurveRendering !== undefined)
            return Text.CurveRendering;
        return Text.QtRendering;
    }
    readonly property real glassSupersample: textSmoothing === "standard" ? 1 : 2

    // Apple's SF Pro family is commonly installed as separate static OTF faces
    // whose names are not the same as Qt's generic weight labels (for example,
    // weight 100 is named "Ultralight", while 200 is "Thin"). Asking Qt for a
    // named style makes it select the matching installed face instead of relying
    // solely on fontconfig's weight matching. The same names are named instances
    // in variable builds, so this works for both the static and variable variants.
    readonly property var sfProStyleNamesByWeight: ({
        "100": "Ultralight", "200": "Thin", "300": "Light",
        "400": "Regular", "500": "Medium", "600": "Semibold",
        "700": "Bold", "800": "Heavy", "900": "Black"
    })
    // Optical tracking is most noticeable on large, light-weight display clocks.
    // The values below are fractions of the em size; they become absolute pixel
    // spacing only when the font is built, so the result scales with clock size.
    readonly property var trackingByWeight: ({
        thin: 0.025, extraLight: 0.022, light: 0.019,
        normal: 0.015, medium: 0.012, demiBold: 0.009,
        bold: 0.006, extraBold: 0.003, black: 0.0015
    })

    function clockTracking(px) {
        if (clockSpacing === "natural")
            return 0;
        const strength = trackingByWeight[fontWeightName] ?? 0.010;
        // Do not tighten small widget-sized clocks as aggressively as display clocks.
        const sizeFactor = clamp((px - 28) / 112, 0, 1);
        const modeFactor = clockSpacing === "tight" ? 1.45 : 1.0;
        return -Math.min(px * 0.040, px * strength * sizeFactor * modeFactor);
    }

    function isSfProFamily(name) {
        const normalized = String(name).trim().toLowerCase();
        return normalized === "sf pro" || normalized === "sf pro display"
            || normalized === "sf pro text" || normalized === "sf pro rounded";
    }

    function makeFont(px) {
        const size = Math.max(8, Math.round(px));
        const weightValue = weightAxisValues[fontWeightName] ?? 700;
        const sfPro = isSfProFamily(fontFamily);
        const f = {
            pixelSize: size,
            weight: weights[fontWeightName] ?? Font.Bold,
            // QML letterSpacing is an absolute pixel adjustment between glyphs.
            // Keep it proportional to the rendered size for stable tracking.
            letterSpacing: clockTracking(size),
            kerning: true
        };
        if (fontFamily !== "")
            f.family = fontFamily;

        if (sfPro) {
            // `styleName` selects the installed SF Pro face (including static OTFs).
            // Keep this mapping intact; the optical-size axis below is independent.
            f.styleName = sfProStyleNamesByWeight[String(weightValue)] ?? "Bold";
        }

        if (supportsVariableFontAxes) {
            // Ask variable fonts to use their display-appropriate optical size.
            // Fonts without an `opsz` axis simply ignore it. For SF Pro, weight is
            // still selected by its explicit style name so static installations
            // continue to work exactly as before.
            const axes = ({ "opsz": Math.max(6, Math.min(96, size * 0.75)) });
            if (!sfPro)
                axes["wght"] = weightValue;
            f.variableAxes = axes;
        }

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

    // Measure the live string for an accurate depth bounding box. Horizontal
    // placement is anchored to the centre of the first colon below, so changing
    // digit widths can change the left edge without moving the clock's anchor.
    readonly property string clockTextValue: Qt.formatDateTime(clock.date, activeFormat)
    TextMetrics {
        id: sizer
        font: root.clockFont
        text: root.clockTextValue
    }
    readonly property int colonIndex: clockTextValue.indexOf(":")
    TextMetrics {
        id: colonPrefixMetrics
        font: root.clockFont
        text: root.colonIndex >= 0 ? root.clockTextValue.slice(0, root.colonIndex) : ""
    }
    TextMetrics {
        id: colonThroughMetrics
        font: root.clockFont
        text: root.colonIndex >= 0 ? root.clockTextValue.slice(0, root.colonIndex + 1) : ""
    }
    // TextMetrics measures shaped prefixes independently. Averaging the width
    // before and after the colon gives its visual centre, including kerning.
    readonly property real colonAnchorOffset: colonIndex >= 0
        ? (colonPrefixMetrics.width + colonThroughMetrics.width) / 2
        : sizer.width / 2

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

    // The horizontal preset now positions the colon itself, not the changing
    // left/right bounds of the string. This keeps the clock visually anchored
    // when fonts use proportional digits (e.g. 1 is narrower than 8).
    readonly property real clockAnchorX: marginX + (width - 2 * marginX) * anchorFrac[0]
        + width * offsetX / 100
    readonly property real clockX: clamp(
        clockAnchorX - colonAnchorOffset,
        0, Math.max(0, width - sizer.width))
    readonly property real clockY: clamp(
        marginY + (height - sizer.height - 2 * marginY) * anchorFrac[1] + height * offsetY / 100,
        0, Math.max(0, height - sizer.height))

    // Clock centre as whole percents of the screen: depth.py measures the
    // wallpaper brightness there. Debounced so dragging a value doesn't spam it.
    readonly property int clockCx: width > 0 ? Math.round((clockX + colonAnchorOffset) / width * 100) : 50
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

    property bool ready: false          // the foreground cutout exists (depth effect on)
    property bool settled: false        // the script has finished for the current wallpaper
    property bool pending: false

    // Depth on: wait for the cutout. Depth off: no cutout is needed, so show the
    // clock on top of the wallpaper as soon as the brightness has been measured.
    readonly property bool showing: effectEnabled
        ? fg.status === Image.Ready
        : (settled && source !== "")

    // The solid Text doubles as the layout/animation source for the glass style.
    readonly property Item textItem: clockText
    readonly property bool moving: clockText.x !== clockX || clockText.y !== clockY
    // Glass is used only if it loaded and has something to sample; otherwise the
    // solid clock stays, so a problem in LiquidGlassText.qml can't blank the clock.
    readonly property bool glassActive: liquidGlass && glassLoader.status === Loader.Ready
        && glassLoader.item !== null && glassLoader.item.usable && glassLoader.item.shown

    readonly property string cutout: Quickshell.env("HOME") + "/.cache/ambxst/depth/"
        + Qt.md5(source) + "-v2-" + threshold + "-" + feather + ".png"
    readonly property string script: Qt.resolvedUrl("depth.py").toString().replace("file://", "")

    function generate(keepVisible) {
        if (!keepVisible) {
            ready = false;
            settled = false;
        }
        if (!settingsLoaded || !source)
            return;
        if (gen.running) {
            pending = true;
            return;
        }
        // Prefer the venv python if the user set one up, else system python3.
        gen.command = ["sh", "-c",
            'PY="$HOME/.local/share/ambxst/depth/venv/bin/python"; [ -x "$PY" ] || PY=python3; exec "$PY" "$@"',
            "sh", script, source, cutout, String(threshold), String(feather),
            String(clockCx), String(clockCy), String(clockW), String(clockH),
            effectEnabled ? "depth" : "flat"];
        gen.running = true;
    }

    onCutoutChanged: generate()
    // Turning depth off keeps the clock on screen (it just loses the cutout);
    // turning it on has to wait for a cutout.
    onEffectEnabledChanged: generate(!effectEnabled)
    Component.onCompleted: loadSettings()

    opacity: root.showing ? 1 : 0
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
        // crossfades with the glass style instead of popping
        opacity: root.glassActive ? 0 : 0.9
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Config.animDuration
                easing.type: Easing.OutCubic
            }
        }
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
        renderType: root.textRenderType
        text: root.clockTextValue
        color: root.clockFill
        Behavior on color {
            ColorAnimation {
                duration: Config.animDuration
                easing.type: Easing.OutCubic
            }
        }
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
        source: (root.ready && root.effectEnabled) ? "file://" + root.cutout : ""
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
                root.generate(true);
                return;
            }
            if (code === 0)
                root.ready = root.effectEnabled;     // a cutout only exists in depth mode
            else
                console.warn("wallpaper-depth: generation failed with code", code);
            root.settled = true;
        }
    }
}
