#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "zarr>=3.0.8",
#     "numcodecs>=0.16.1",
# ]
# ///

"""
Generate Zarr V3 and V2 test fixtures using Python zarr for cross-language
compatibility testing with Zarrs.jl.

Run:  uv run test/fixtures/generate_python.py
"""

import shutil
from pathlib import Path

import numpy as np
import zarr
from zarr.codecs import BloscCodec, BytesCodec, GzipCodec, ZstdCodec
from numcodecs import Blosc as NcBlosc, Zstd as NcZstd

FIXTURE_DIR = Path(__file__).parent

# Standard 10x10 test data: 0..99 as float32
DATA_F32 = np.arange(100, dtype=np.float32).reshape(10, 10)
# 1D int data
DATA_I32_1D = np.arange(20, dtype=np.int32)
# 3D data
DATA_F64_3D = np.arange(60, dtype=np.float64).reshape(3, 4, 5)

# ---------------------------------------------------------------------------
# V3 fixtures
# ---------------------------------------------------------------------------
v3_dir = FIXTURE_DIR / "v3_python"
if v3_dir.exists():
    shutil.rmtree(v3_dir)
v3_dir.mkdir()


def create_v3(name, data, *, chunks, dtype=None, compressors=None, shards=None,
              fill_value=0, dimension_names=None, attrs=None):
    """Create a V3 array fixture."""
    path = str(v3_dir / f"{name}.zarr")
    kwargs = dict(
        zarr_format=3,
        shape=data.shape,
        chunks=chunks,
        dtype=dtype or data.dtype,
        fill_value=fill_value,
    )
    if compressors is not None:
        kwargs["compressors"] = compressors
    if shards is not None:
        kwargs["shards"] = shards
    if dimension_names is not None:
        kwargs["dimension_names"] = dimension_names

    a = zarr.create_array(path, overwrite=True, **kwargs)
    a[...] = data
    if attrs:
        a.attrs.update(attrs)
    return a


# Basic compressors
create_v3("array_none", DATA_F32, chunks=(5, 5), compressors=[])
create_v3("array_zstd", DATA_F32, chunks=(5, 5),
          compressors=[ZstdCodec(level=3)])
create_v3("array_gzip", DATA_F32, chunks=(5, 5),
          compressors=[GzipCodec(level=5)])
create_v3("array_blosc", DATA_F32, chunks=(5, 5),
          compressors=[BloscCodec(cname="lz4", clevel=5, shuffle="noshuffle")])

# Data types
for dtype_name, dtype, data_fn in [
    ("bool", "bool", lambda: np.array([[True, False], [False, True]])),
    ("int8", "int8", lambda: np.arange(4, dtype=np.int8).reshape(2, 2)),
    ("int16", "int16", lambda: np.arange(4, dtype=np.int16).reshape(2, 2)),
    ("int32", "int32", lambda: np.arange(4, dtype=np.int32).reshape(2, 2)),
    ("int64", "int64", lambda: np.arange(4, dtype=np.int64).reshape(2, 2)),
    ("uint8", "uint8", lambda: np.arange(4, dtype=np.uint8).reshape(2, 2)),
    ("uint16", "uint16", lambda: np.arange(4, dtype=np.uint16).reshape(2, 2)),
    ("uint32", "uint32", lambda: np.arange(4, dtype=np.uint32).reshape(2, 2)),
    ("uint64", "uint64", lambda: np.arange(4, dtype=np.uint64).reshape(2, 2)),
    ("float32", "float32", lambda: np.array([1.5, 2.5, 3.5, 4.5], dtype=np.float32).reshape(2, 2)),
    ("float64", "float64", lambda: np.array([1.5, 2.5, 3.5, 4.5], dtype=np.float64).reshape(2, 2)),
    ("complex64", "complex64", lambda: np.array([1+2j, 3+4j, 5+6j, 7+8j], dtype=np.complex64).reshape(2, 2)),
    ("complex128", "complex128", lambda: np.array([1+2j, 3+4j, 5+6j, 7+8j], dtype=np.complex128).reshape(2, 2)),
]:
    d = data_fn()
    create_v3(f"dtype_{dtype_name}", d, chunks=d.shape, dtype=dtype,
              compressors=[ZstdCodec(level=1)])

# 1D array
create_v3("array_1d", DATA_I32_1D, chunks=(10,), compressors=[ZstdCodec(level=1)])

# 3D array
create_v3("array_3d", DATA_F64_3D, chunks=(3, 4, 5), compressors=[ZstdCodec(level=1)])

# Sharded array
create_v3("array_sharded", DATA_F32, chunks=(5, 5), shards=(10, 10),
          compressors=[ZstdCodec(level=1)])

# Chunked sharded array (multiple inner chunks per shard)
create_v3("array_sharded_multi", DATA_F32, chunks=(2, 2), shards=(10, 10),
          compressors=[ZstdCodec(level=1)])

# Attributes
create_v3("array_attrs", DATA_F32, chunks=(5, 5), compressors=[ZstdCodec(level=1)],
          attrs={"units": "kelvin", "long_name": "temperature",
                 "coordinates": ["lon", "lat"], "nested": {"a": 1, "b": 2}})

# Dimension names
create_v3("array_dimnames", DATA_F32, chunks=(5, 5), compressors=[ZstdCodec(level=1)],
          dimension_names=["x", "y"])

# Fill value = NaN
create_v3("array_nan_fill", np.full((4, 4), np.nan, dtype=np.float32),
          chunks=(4, 4), fill_value=float("nan"), compressors=[])

# ---------------------------------------------------------------------------
# V2 fixtures
# ---------------------------------------------------------------------------
v2_dir = FIXTURE_DIR / "v2_python"
if v2_dir.exists():
    shutil.rmtree(v2_dir)
v2_dir.mkdir()


def create_v2(name, data, *, chunks, dtype=None, compressors=None, fill_value=0, attrs=None):
    """Create a V2 array fixture."""
    path = str(v2_dir / f"{name}.zarr")
    kwargs = dict(
        zarr_format=2,
        shape=data.shape,
        chunks=chunks,
        dtype=dtype or data.dtype,
        fill_value=fill_value,
    )
    if compressors is not None:
        kwargs["compressors"] = compressors

    a = zarr.create_array(path, overwrite=True, **kwargs)
    a[...] = data
    if attrs:
        a.attrs.update(attrs)
    return a


create_v2("array_none", DATA_F32, chunks=(5, 5), compressors=None)
create_v2("array_zstd", DATA_F32, chunks=(5, 5),
          compressors=[NcZstd(level=3)])
create_v2("array_blosc", DATA_F32, chunks=(5, 5),
          compressors=[NcBlosc(cname="lz4", clevel=5, shuffle=NcBlosc.NOSHUFFLE)])
create_v2("array_1d", DATA_I32_1D, chunks=(10,), compressors=[NcZstd(level=1)])

print(f"V3 fixtures: {v3_dir}")
print(f"V2 fixtures: {v2_dir}")
print("Done.")
