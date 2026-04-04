import vapoursynth as vs
from vapoursynth import core

import sys
from pathlib import Path

# add blur.py folder to path so it can reference scripts
sys.path.insert(1, str(Path(__file__).parent))

import blur.interpolate
import blur.utils as u

if vars().get("macos_bundled") == "true":
    u.load_plugins(".dylib")
elif vars().get("linux_bundled") == "true":
    u.load_plugins(".so")

model_path = Path(vars().get("rife_model", ""))
gpu_index = vars().get("rife_gpu_index", 0)
benchmark_video_path = Path(vars().get("benchmark_video_path", ""))

if vars().get("enable_lsmash") == "true":
    video = core.lsmas.LWLibavSource(source=benchmark_video_path, cache=0)
else:
    video = core.bs.VideoSource(source=benchmark_video_path, cachemode=0)

video = blur.interpolate.interpolate_rife(
    video,
    is_full_color_range=False,  # doesn't matter
    new_fps=video.fps * 3,
    model_path=model_path,
    gpu_index=gpu_index,
)

video.set_output()
