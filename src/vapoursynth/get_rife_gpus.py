import vapoursynth as vs
from vapoursynth import core

import sys
from pathlib import Path

# add blur.py folder to path so it can reference scripts
sys.path.insert(1, str(Path(__file__).parent))

import blur.utils as u

if vars().get("macos_bundled") == "true":
    u.load_plugins(".dylib")
elif vars().get("linux_bundled") == "true":
    u.load_plugins(".so")

video = core.std.BlankClip(
    width=1, height=1, length=2, fpsnum=1, fpsden=1, format=vs.RGBS
)

core.rife.RIFE(video, list_gpu=True)
