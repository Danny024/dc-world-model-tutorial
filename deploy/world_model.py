"""
world_model.py — importlib shim for 07_world_model.py
======================================================
Python cannot import modules whose filenames begin with a digit.
This shim loads 07_world_model.py under the name 'world_model' so that:
  - inference_server.py    can do: from world_model import load_model, predict
  - export_edge.py         can do: from world_model import WINDOW_SIZE, HORIZONS
  - 08_vertex_training.py  can do: from world_model import train
  - Docker container       already renames the file, but local dev uses this shim

This file is intentionally minimal — all real code lives in 07_world_model.py.
"""
import importlib.util
import pathlib
import sys

_path = pathlib.Path(__file__).parent / "07_world_model.py"
_spec = importlib.util.spec_from_file_location("world_model", _path)
_module = importlib.util.module_from_spec(_spec)
sys.modules[__name__] = _module
_spec.loader.exec_module(_module)
