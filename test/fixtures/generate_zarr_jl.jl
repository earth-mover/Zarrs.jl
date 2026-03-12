# Generate V2 Zarr test fixtures using Zarr.jl for cross-language testing.
#
# Run from the zarrs-julia/ directory:
#   julia --project=../../Zarr.jl test/fixtures/generate_zarr_jl.jl
#
# Requires Zarr.jl to be available (instantiated) at the path above.

using Zarr

FIXTURE_DIR = joinpath(@__DIR__, "v2_zarr_jl")
rm(FIXTURE_DIR; force=true, recursive=true)
mkpath(FIXTURE_DIR)

# ---------------------------------------------------------------------------
# Compressors
# ---------------------------------------------------------------------------

data_f32 = Float32.(reshape(0:99, 10, 10))

for (name, comp) in [
    ("blosc", Zarr.BloscCompressor(cname="lz4", clevel=5, shuffle=0)),
    ("zstd",  Zarr.ZstdCompressor(level=3)),
    ("none",  Zarr.NoCompressor()),
]
    path = joinpath(FIXTURE_DIR, "array_$(name).zarr")
    s = Zarr.DirectoryStore(path)
    z = Zarr.zcreate(Float32, s, 10, 10; chunks=(5, 5), compressor=comp,
                     fill_value=Float32(0))
    z[:, :] = data_f32
end

# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

for (name, T, data) in [
    ("int8",    Int8,    Int8.(reshape(0:3, 2, 2))),
    ("int16",   Int16,   Int16.(reshape(0:3, 2, 2))),
    ("int32",   Int32,   Int32.(reshape(0:3, 2, 2))),
    ("int64",   Int64,   Int64.(reshape(0:3, 2, 2))),
    ("uint8",   UInt8,   UInt8.(reshape(0:3, 2, 2))),
    ("uint16",  UInt16,  UInt16.(reshape(0:3, 2, 2))),
    ("uint32",  UInt32,  UInt32.(reshape(0:3, 2, 2))),
    ("uint64",  UInt64,  UInt64.(reshape(0:3, 2, 2))),
    ("float32", Float32, Float32[1.5 3.5; 2.5 4.5]),
    ("float64", Float64, Float64[1.5 3.5; 2.5 4.5]),
]
    path = joinpath(FIXTURE_DIR, "dtype_$(name).zarr")
    s = Zarr.DirectoryStore(path)
    z = Zarr.zcreate(T, s, size(data)...; chunks=size(data),
                     compressor=Zarr.BloscCompressor(cname="lz4", clevel=1, shuffle=0))
    z[ntuple(_ -> Colon(), ndims(data))...] = data
end

# ---------------------------------------------------------------------------
# 1D array
# ---------------------------------------------------------------------------

let path = joinpath(FIXTURE_DIR, "array_1d.zarr")
    s = Zarr.DirectoryStore(path)
    z = Zarr.zcreate(Int32, s, 20; chunks=(10,),
                     compressor=Zarr.BloscCompressor(cname="lz4", clevel=1, shuffle=0))
    z[:] = Int32.(0:19)
end

# ---------------------------------------------------------------------------
# Group with attributes
# ---------------------------------------------------------------------------

let path = joinpath(FIXTURE_DIR, "group.zarr")
    g = Zarr.zgroup(path; attrs=Dict("source" => "Zarr.jl", "version" => 2))

    s = Zarr.DirectoryStore(path)
    z = Zarr.zcreate(Float32, g, "temperature", 10, 10; chunks=(5, 5),
                     compressor=Zarr.BloscCompressor(cname="lz4", clevel=1, shuffle=0))
    z[:, :] = Float32.(reshape(0:99, 10, 10))
end

println("Zarr.jl V2 fixtures generated at: $FIXTURE_DIR")
