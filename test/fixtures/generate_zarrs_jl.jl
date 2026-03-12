# Generate Zarr V3 test fixtures using Zarrs.jl for cross-language validation.
#
# Run:  julia --project test/fixtures/generate_zarrs_jl.jl

using Zarrs

FIXTURE_DIR = joinpath(@__DIR__, "v3_zarrs_jl")
rm(FIXTURE_DIR; force=true, recursive=true)
mkpath(FIXTURE_DIR)

# Standard 10x10 test data: 0..99 as Float32
DATA_F32 = Float32.(reshape(0:99, 10, 10))
DATA_I32_1D = Int32.(0:19)
DATA_F64_3D = Float64.(reshape(0:59, 3, 4, 5))

# ---------------------------------------------------------------------------
# Compressors
# ---------------------------------------------------------------------------

for (name, comp) in [("none", "none"), ("zstd", "zstd"), ("gzip", "gzip"), ("blosc", "blosc")]
    path = joinpath(FIXTURE_DIR, "array_$(name).zarr")
    z = zcreate(Float32, 10, 10; chunks=(5, 5), path=path,
                compressor=comp, compressor_level=comp == "none" ? 0 : 3,
                fill_value=Float32(0))
    z[:, :] = DATA_F32
end

# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

for (name, T, data) in [
    ("bool",       Bool,       Bool[true false; false true]),
    ("int8",       Int8,       Int8.(reshape(0:3, 2, 2))),
    ("int16",      Int16,      Int16.(reshape(0:3, 2, 2))),
    ("int32",      Int32,      Int32.(reshape(0:3, 2, 2))),
    ("int64",      Int64,      Int64.(reshape(0:3, 2, 2))),
    ("uint8",      UInt8,      UInt8.(reshape(0:3, 2, 2))),
    ("uint16",     UInt16,     UInt16.(reshape(0:3, 2, 2))),
    ("uint32",     UInt32,     UInt32.(reshape(0:3, 2, 2))),
    ("uint64",     UInt64,     UInt64.(reshape(0:3, 2, 2))),
    ("float32",    Float32,    Float32[1.5 2.5; 3.5 4.5]),
    ("float64",    Float64,    Float64[1.5 2.5; 3.5 4.5]),
    ("complex64",  ComplexF32, ComplexF32[1+2im 3+4im; 5+6im 7+8im]),
    ("complex128", ComplexF64, ComplexF64[1+2im 3+4im; 5+6im 7+8im]),
]
    path = joinpath(FIXTURE_DIR, "dtype_$(name).zarr")
    z = zcreate(T, size(data)...; chunks=size(data), path=path,
                compressor="zstd", compressor_level=1)
    z[ntuple(_ -> Colon(), ndims(data))...] = data
end

# ---------------------------------------------------------------------------
# Dimensionality
# ---------------------------------------------------------------------------

# 1D
let path = joinpath(FIXTURE_DIR, "array_1d.zarr")
    z = zcreate(Int32, 20; chunks=(10,), path=path, compressor="zstd", compressor_level=1)
    z[:] = DATA_I32_1D
end

# 3D
let path = joinpath(FIXTURE_DIR, "array_3d.zarr")
    z = zcreate(Float64, 3, 4, 5; chunks=(3, 4, 5), path=path,
                compressor="zstd", compressor_level=1)
    z[:, :, :] = DATA_F64_3D
end

# ---------------------------------------------------------------------------
# Sharding
# ---------------------------------------------------------------------------

let path = joinpath(FIXTURE_DIR, "array_sharded.zarr")
    z = zcreate(Float32, 10, 10; chunks=(5, 5), shard_shape=(10, 10), path=path,
                compressor="zstd", compressor_level=1, fill_value=Float32(0))
    z[:, :] = DATA_F32
end

# ---------------------------------------------------------------------------
# Attributes
# ---------------------------------------------------------------------------

let path = joinpath(FIXTURE_DIR, "array_attrs.zarr")
    z = zcreate(Float32, 10, 10; chunks=(5, 5), path=path,
                compressor="zstd", compressor_level=1)
    z[:, :] = DATA_F32
    set_attributes!(z, Dict("units" => "kelvin", "long_name" => "temperature"))
end

# ---------------------------------------------------------------------------
# Dimension names
# ---------------------------------------------------------------------------

let path = joinpath(FIXTURE_DIR, "array_dimnames.zarr")
    z = zcreate(Float32, 10, 10; chunks=(5, 5), path=path,
                compressor="zstd", compressor_level=1,
                dimension_names=("x", "y"))
    z[:, :] = DATA_F32
end

println("Zarrs.jl V3 fixtures generated at: $FIXTURE_DIR")
