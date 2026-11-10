#!/usr/bin/env python3
"""Wallpaper Depth: build an RGBA foreground cutout of a wallpaper, and measure
how bright the wallpaper is behind the clock so the QML can pick text colour.

usage: depth.py <wallpaper> <out.png> <threshold 0-100> <feather px> <clock x %> <clock y %> <clock w %> <clock h %> [depth|flat]

(clock x/y = centre of the clock, w/h = its size, all as whole percents of the screen)

Mode "flat" (depth effect switched off) skips the model and the cutout entirely
and only measures the brightness behind the clock, so no model is needed.

Prints one number on stdout: relative luminance (0 = black, 1 = white) of the
visible background behind the clock.

How the cutout is made: the model estimates depth; that depth map is refined
against the wallpaper's own edges (guided filter) so the cut follows real
outlines instead of the model's coarse, blocky edges; it is then cut at the
threshold with about one pixel of anti-aliasing, and finally feathered.

The depth map is cached per wallpaper, so changing threshold/feather only
redoes the cheap mask step. Outputs are written atomically.
"""
import hashlib
import io
import os
import sys
import time

wall, out = sys.argv[1], sys.argv[2]
threshold, feather = int(sys.argv[3]), float(sys.argv[4])
cxp, cyp, wp, hp = (int(a) for a in sys.argv[5:9])
cx, cy = cxp / 100.0, cyp / 100.0
flat = len(sys.argv) > 9 and sys.argv[9] == "flat"

DATA = os.path.expanduser("~/.local/share/ambxst/depth")
CACHE = os.path.expanduser("~/.cache/ambxst/depth")
MODEL = os.path.join(DATA, "model.onnx")
os.makedirs(CACHE, exist_ok=True)

def file_fingerprint(path):
    """SHA-256 of wallpaper contents, streamed to avoid loading it into RAM."""
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

fingerprint = file_fingerprint(wall)
base_key = fingerprint[:32]
if flat:
    lum_path = os.path.join(CACHE, f"{base_key}-flat-x{cxp}-y{cyp}-w{wp}-h{hp}.lum")
else:
    lum_path = os.path.splitext(out)[0] + f"-{base_key[:12]}-x{cxp}-y{cyp}-w{wp}-h{hp}.lum"
meta_path = out + ".meta"

def write_atomic(path, data, binary=False):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "wb" if binary else "w") as f:
        f.write(data)
    os.replace(tmp, path)

def prune_cache(protected=()):
    """Evict least-recently-used cache files until within the configured budget."""
    try:
        limit = max(64, int(os.environ.get("AMBXST_DEPTH_CACHE_MB", "512"))) * 1024 * 1024
    except ValueError:
        limit = 512 * 1024 * 1024
    protected = {os.path.abspath(x) for x in protected if x}
    entries, total = [], 0
    now = time.time()
    for name in os.listdir(CACHE):
        path = os.path.join(CACHE, name)
        try:
            if not os.path.isfile(path):
                continue
            st = os.stat(path)
            if name.endswith(".tmp") and now - st.st_mtime > 86400:
                os.unlink(path)
                continue
            total += st.st_size
            if os.path.abspath(path) not in protected and not name.endswith(".tmp"):
                entries.append((st.st_mtime, path, st.st_size))
        except OSError:
            continue
    for _, path, size in sorted(entries):
        if total <= limit:
            break
        try:
            os.unlink(path)
            total -= size
        except OSError:
            pass

seg_mode = os.environ.get("AMBXST_DEPTH_SEGMENTATION", "auto").strip().lower()
expected_meta = f"{fingerprint}:{threshold}:{feather}:{seg_mode}:quality-v4"
# Fast path before heavy imports. Never trust a path-only cache hit.
if flat and os.path.exists(lum_path):
    try:
        print(open(lum_path).read().strip())
        os.utime(lum_path, None)
        prune_cache((lum_path,))
        sys.exit(0)
    except OSError:
        pass
if not flat and os.path.exists(lum_path) and os.path.exists(out) and os.path.exists(meta_path):
    try:
        if open(meta_path).read().strip() == expected_meta:
            print(open(lum_path).read().strip())
            os.utime(out, None)
            os.utime(meta_path, None)
            os.utime(lum_path, None)
            prune_cache((out, meta_path, lum_path))
            sys.exit(0)
    except OSError:
        pass

import numpy as np
from PIL import Image, ImageFilter

DATA = os.path.expanduser("~/.local/share/ambxst/depth")
CACHE = os.path.expanduser("~/.cache/ambxst/depth")
MODEL = os.path.join(DATA, "model.onnx")
os.makedirs(CACHE, exist_ok=True)

img = Image.open(wall).convert("RGB")


def clock_luminance(img, alpha, cx, cy, wp, hp):
    """Median linear luminance of the background pixels behind the clock."""
    W, H = img.size
    hx = min(max(wp / 200.0, 0.02), 0.5)    # half the clock's width, as a fraction of the screen
    hy = min(max(hp / 200.0, 0.02), 0.5)    # half its height
    x0, x1 = max(0.0, cx - hx), min(1.0, cx + hx)
    y0, y1 = max(0.0, cy - hy), min(1.0, cy + hy)
    box = (int(W * x0), int(H * y0), max(int(W * x1), int(W * x0) + 1), max(int(H * y1), int(H * y0) + 1))
    rgb = img.crop(box)
    a = alpha.crop(box)
    rgb.thumbnail((96, 96))
    a = a.resize(rgb.size)
    c = np.asarray(rgb, np.float32) / 255.0
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    bg = np.asarray(a) < 128            # pixels NOT covered by the foreground cutout
    if bg.mean() >= 0.10:
        lum = lum[bg]
    return float(np.median(lum))


def model_size(inp, W, H):
    """Fixed-size models keep their size. Models with dynamic height/width get an
    aspect-preserving size (multiples of 14, quality-oriented long side) instead of being
    squashed to a square, which gives much finer edges."""
    h, w = inp.shape[2], inp.shape[3]
    if isinstance(h, int) and isinstance(w, int):
        return w, h
    s = float(os.environ.get("AMBXST_DEPTH_MAX_SIDE", "1036")) / max(W, H)
    return max(14, round(W * s / 14) * 14), max(14, round(H * s / 14) * 14)


def estimate_depth(img):
    import onnxruntime as ort

    try:
        options = ort.SessionOptions()
        options.intra_op_num_threads = max(1, min(4, os.cpu_count() or 2))
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        sess = ort.InferenceSession(MODEL, sess_options=options,
                                   providers=["CPUExecutionProvider"])
    except Exception as e:                      # noqa: BLE001 - turn it into something readable
        sys.stderr.write(f"could not load the depth model {MODEL}: {e}\n")
        data = MODEL + "_data"
        if os.path.getsize(MODEL) < 5_000_000 and not os.path.exists(data):
            sys.stderr.write(
                "model.onnx is only the model graph. This model keeps its weights in a second\n"
                f"file, model.onnx_data; download it too and put it next to model.onnx ({data}).\n"
            )
        sys.exit(3)
    inp = sess.get_inputs()[0]
    sizes = [model_size(inp, *img.size)]
    if sizes[0] != (518, 518):
        sizes.append((518, 518))        # if a model rejects other sizes, fall back to the classic one
    last = None
    for w, h in sizes:
        try:
            x = np.asarray(img.resize((w, h), Image.BICUBIC), np.float32) / 255.0
            x = (x - np.array([0.485, 0.456, 0.406], np.float32)) / np.array(
                [0.229, 0.224, 0.225], np.float32
            )
            x = x.transpose(2, 0, 1)[None].astype(np.float32)
            depth = np.squeeze(sess.run(None, {inp.name: x})[0])
            while depth.ndim > 2:
                depth = depth[0]
            depth = (depth - depth.min()) / max(float(depth.max() - depth.min()), 1e-6)
            return depth.astype(np.float32)     # relative depth, 1 = closest
        except Exception as e:                  # noqa: BLE001 - try the next size
            last = e
    raise last



def estimate_segmentation(img):
    """Return an optional foreground probability map, or None on any failure.

    `rembg` provides maintained ONNX-backed IS-Net checkpoints. In auto mode,
    averaging the general and anime predictors makes the feature useful across
    mixed wallpaper libraries without trusting either model alone. This quality
    mode intentionally trades extra first-run CPU time for more robust masks. It is an
    optional enhancement: no rembg install or model-download failure preserves
    the original depth-only behavior.
    """
    mode = os.environ.get("AMBXST_DEPTH_SEGMENTATION", "auto").strip().lower()
    if mode in ("off", "0", "false", "no", "disabled"):
        return None
    if mode not in ("auto", "anime", "general"):
        sys.stderr.write(f"unknown AMBXST_DEPTH_SEGMENTATION={mode!r}; using depth-only\n")
        return None

    try:
        from rembg import new_session, remove
    except Exception:
        sys.stderr.write("segmentation unavailable (optional package 'rembg' is not installed); using depth-only\n")
        return None

    model_names = ["isnet-general-use", "isnet-anime"] if mode == "auto" else (
        ["isnet-anime"] if mode == "anime" else ["isnet-general-use"]
    )
    predictions = []
    for model_name in model_names:
        try:
            session = new_session(model_name)
            mask = remove(img, session=session, only_mask=True, post_process_mask=False)
            if not isinstance(mask, Image.Image):
                if isinstance(mask, bytes):
                    mask = Image.open(io.BytesIO(mask))
                elif isinstance(mask, (str, os.PathLike)):
                    mask = Image.open(mask)
                else:
                    mask = Image.fromarray(np.asarray(mask))
            mask = mask.convert("L").resize(img.size, Image.LANCZOS)
            predictions.append(np.asarray(mask, np.float32) / 255.0)
        except Exception as e:  # optional model/download/runtime failure must not break wallpapers
            sys.stderr.write(f"segmentation model {model_name} failed; continuing without it: {e}\n")

    if not predictions:
        return None
    # Average rather than union: union tends to include background artifacts.
    return np.mean(predictions, axis=0, dtype=np.float32)


def box_mean(x, r):
    """Mean over a (2r+1)x(2r+1) window with replicated edges, via cumulative sums."""
    p = np.pad(x, ((r + 1, r), (r + 1, r)), mode="edge").astype(np.float64)
    c = p.cumsum(0).cumsum(1)
    n = 2 * r + 1
    return ((c[n:, n:] - c[:-n, n:] - c[n:, :-n] + c[:-n, :-n]) / (n * n)).astype(np.float32)


def guided_filter(guide, src, r, eps):
    """Edge-aware smoothing of `src` that follows the edges of `guide` (He et al.)."""
    mg, ms = box_mean(guide, r), box_mean(src, r)
    cov = box_mean(guide * src, r) - mg * ms
    var = box_mean(guide * guide, r) - mg * mg
    a = cov / (var + eps)
    b = ms - a * mg
    return box_mean(a, r) * guide + box_mean(b, r)


def make_alpha(img, depth, threshold, feather, segmentation=None):
    W, H = img.size
    s = min(1.0, 2048.0 / max(W, H))            # work at <= 2048 px so 4K wallpapers stay cheap
    ww, wh = max(1, round(W * s)), max(1, round(H * s))
    guide = np.asarray(img.convert("L").resize((ww, wh), Image.LANCZOS), np.float32) / 255.0
    d = np.asarray(Image.fromarray(depth).resize((ww, wh), Image.BICUBIC), np.float32)
    d = np.clip(d, 0.0, 1.0)
    r = max(3, round(8 * min(ww, wh) / 1080))
    df = guided_filter(guide, d, r, 1e-3)
    gy, gx = np.gradient(df)
    # signed distance, in work pixels, from the threshold contour (positive = foreground)
    sd = (df - threshold / 100.0) / np.maximum(np.hypot(gx, gy), 1e-5)
    # Pull the cut inward before feathering, so a soft edge fades out *inside* the
    # subject. Otherwise feathering spreads wallpaper pixels over the clock as a halo.
    sd -= 0.75 * feather * s
    a = np.clip(0.5 + sd / 2.4, 0.0, 1.0)       # ~1.2 px of anti-aliasing each side of the contour

    # Segmentation is a subject prior, not a replacement for depth. It is only
    # allowed to restore subject pixels where depth is near the chosen cutoff;
    # this helps recover hair/clothing that depth alone places just behind the
    # contour without making every salient object cover the clock unconditionally.
    if segmentation is not None:
        seg_img = Image.fromarray(np.uint8(np.clip(segmentation, 0.0, 1.0) * 255.0))
        seg = np.asarray(seg_img.resize((ww, wh), Image.LANCZOS), np.float32) / 255.0
        seg = np.clip(guided_filter(guide, seg, max(2, r // 2), 5e-4), 0.0, 1.0)
        cutoff = threshold / 100.0
        near_cutoff = np.clip((df - (cutoff - 0.22)) / 0.18, 0.0, 1.0)
        a = np.maximum(a, seg * near_cutoff)

    alpha = Image.fromarray((a * 255.0 + 0.5).astype(np.uint8))
    if (ww, wh) != (W, H):
        alpha = alpha.resize((W, H), Image.BICUBIC)
    if feather > 0:
        alpha = alpha.filter(ImageFilter.GaussianBlur(feather))
    return alpha


if flat:
    # Depth effect off: nothing is hidden behind a cutout, so every pixel counts.
    os.makedirs(os.path.dirname(out), exist_ok=True)
    L = clock_luminance(img, Image.new("L", img.size, 0), cx, cy, wp, hp)
    write_atomic(lum_path, f"{L:.4f}\n")
    print(f"{L:.4f}")
    prune_cache((lum_path,))
    sys.exit(0)

valid_output = False
if os.path.exists(out) and os.path.exists(meta_path):
    try:
        valid_output = open(meta_path).read().strip() == expected_meta
    except OSError:
        pass

if valid_output:
    alpha = Image.open(out).getchannel("A")
    if alpha.size != img.size:
        alpha = alpha.resize(img.size)
else:
    dmap_path = os.path.join(CACHE, base_key + "-depth-v4.npy")
    if os.path.exists(dmap_path):
        depth = np.load(dmap_path)
        os.utime(dmap_path, None)
    else:
        if not os.path.exists(MODEL):
            sys.stderr.write(f"depth model missing: {MODEL} (see README)\n")
            sys.exit(2)
        depth = estimate_depth(img)
        tmp_depth = f"{dmap_path}.{os.getpid()}.tmp"
        with open(tmp_depth, "wb") as f:
            np.save(f, depth.astype(np.float32))
        os.replace(tmp_depth, dmap_path)

    seg_key = hashlib.sha256(f"{fingerprint}|seg-v2|{seg_mode}".encode()).hexdigest()[:32]
    seg_path = os.path.join(CACHE, seg_key + "-seg.npy")
    segmentation = None
    if seg_mode not in ("off", "0", "false", "no", "disabled"):
        if os.path.exists(seg_path):
            try:
                cached_seg = np.load(seg_path)
                if cached_seg.shape == (img.height, img.width):
                    segmentation = cached_seg
                    os.utime(seg_path, None)
            except Exception:
                segmentation = None
        if segmentation is None:
            segmentation = estimate_segmentation(img)
            if segmentation is not None:
                tmp_seg = f"{seg_path}.{os.getpid()}.tmp"
                with open(tmp_seg, "wb") as f:
                    np.save(f, segmentation.astype(np.float32))
                os.replace(tmp_seg, seg_path)

    alpha = make_alpha(img, depth, threshold, feather, segmentation)

    cut = img.copy()
    cut.putalpha(alpha)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = f"{out}.{os.getpid()}.tmp"
    cut.save(tmp, format="PNG")
    os.replace(tmp, out)
    write_atomic(meta_path, expected_meta + "\n")

L = clock_luminance(img, alpha, cx, cy, wp, hp)
write_atomic(lum_path, f"{L:.4f}\n")
print(f"{L:.4f}")
prune_cache((out, meta_path, lum_path, locals().get("dmap_path"), locals().get("seg_path")))
