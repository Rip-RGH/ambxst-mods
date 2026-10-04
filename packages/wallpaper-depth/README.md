# Wallpaper Depth (Ambxst mod)

Draws a clock between your wallpaper and a cutout of its foreground.
Static image wallpapers only (GIFs and videos are skipped).

## One-time setup

```
mkdir -p ~/.local/share/ambxst/depth && cd ~/.local/share/ambxst/depth
python3 -m venv venv
./venv/bin/pip install onnxruntime numpy pillow
curl -L -o model.onnx \
  https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/onnx/model.onnx
```

## Install

```
ambxst mods install https://github.com/Rip-RGH/ambxst-mods/tree/main/packages/wallpaper-depth
ambxst mods enable rip-rgh.wallpaper-depth
ambxst reload
```

## Tuning

Settings → Mods → Wallpaper Depth:

- **Liquid glass style** (off by default): the clock becomes frosted glass. The
  wallpaper shows through the letters, slightly magnified, with light edges and a
  soft shadow. **Glass frost** (blur), **Glass tint** (raise it if the clock is hard
  to read, especially on bright wallpapers) and **Glass edge highlight** tune it.
  It is an approximation built from Qt effects (frost, lens-like zoom, rim light),
  not true refraction. If `LiquidGlassText.qml` ever fails to load, the solid clock
  stays on screen.
- **Clock format**: 24-hour or 12-hour, with or without seconds, or **Custom**.
- **Custom format**: a Qt date/time format, used when the format is Custom, e.g.
  `ddd d MMM HH:mm`. Letters: `HH` hour (24h), `h` hour (12h with `AP`), `mm`
  minutes, `ss` seconds, `AP` AM/PM, `ddd`/`dddd` weekday, `d` day, `MMM`/`MMMM`
  month. Wrap literal text in single quotes.
- **Font**: an installed font family name (`fc-list : family` lists them). Empty
  uses the default font. A name that isn't installed falls back to the default.
- **Font weight**: Thin to Black. If the font lacks a weight, the nearest is used.
- **Clock size**, **Clock color** (Auto picks light or dark text from the wallpaper
  behind the clock, wherever you put it).
- **Clock position**: nine presets, plus **horizontal / vertical offset** in percent
  of the screen (-50 to 50) to nudge from the preset.
- **Foreground threshold** (0-100; lower = more of the scene counts as foreground)
  and **Edge softness** (px).

Long formats shrink to fit within 90% of the screen width. Changes apply live. Cutouts are cached in `~/.cache/ambxst/depth/`; delete it to
force regeneration.
