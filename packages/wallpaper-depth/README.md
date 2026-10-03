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
ambxst mods install ./wallpaper-depth
ambxst mods enable yourname.wallpaper-depth
ambxst reload
```

Change `id` and `author` in `ambxst.mod.json` first, and set the same id in `modId`
at the top of `payload/DepthLayer.qml` (settings are looked up by that id).

## Tuning

Settings → Mods → Wallpaper Depth: on/off, foreground threshold (0-100), edge
softness (px) and clock size. Lower threshold = more of the scene counts as foreground.
Changes apply live. Cutouts are cached in `~/.cache/ambxst/depth/`; delete it to
force regeneration.
