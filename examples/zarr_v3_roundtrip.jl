# Zarr V3 read/write example using Zarrs.jl
#
# Run from the zarrs-julia/ directory:
#   julia --project examples/zarr_v3_roundtrip.jl

using Zarrs

outdir = mktempdir()
println("Working directory: $outdir\n")

# --- 1. Create a 2D array with sharding ---
path = joinpath(outdir, "temperature.zarr")
nx, ny = 360, 180
chunks = (90, 90)
shard_shape = (180, 180)

println("Creating $(nx)x$(ny) Float64 array with chunks=$chunks, shard_shape=$shard_shape")
z = zcreate(Float64, nx, ny;
    path,
    chunks,
    shard_shape,
    compressor="zstd",
    compressor_level=3,
    fill_value=Float64(NaN),
    dimension_names=("longitude", "latitude"),
)
println(z)

# --- 2. Write synthetic data ---
# Simple latitude/longitude temperature model
lon = range(-180f0, 179f0, length=nx)
lat = range(-90f0, 89f0, length=ny)
data = [20f0 - 30f0 * abs(la) / 90f0 + 5f0 * sin(2π * lo / 360f0)
        for lo in lon, la in lat]

println("\nWriting data (min=$(round(minimum(data), digits=1)), max=$(round(maximum(data), digits=1)))...")
z[:, :] = data

# --- 3. Read back subsets ---
println("\nReading a 10x10 block at [1:10, 1:10]:")
block = z[1:10, 1:10]
println("  size=$(size(block)), mean=$(round(sum(block)/length(block), digits=2))")

println("\nReading a single latitude band [1:360, 90:90]:")
band = z[:, 90]
println("  size=$(size(band)), range=[$(round(minimum(band), digits=1)), $(round(maximum(band), digits=1))]")

# --- 4. Verify full round-trip ---
readback = z[:, :]
maxerr = maximum(abs.(readback .- data))
println("\nFull round-trip max error: $maxerr")

# --- 5. Inspect metadata ---
println("\nMetadata:")
zinfo(z)

# --- 6. Attributes ---
set_attributes!(z, Dict("units" => "degC", "long_name" => "Surface Temperature"))
attrs = get_attributes(z)
println("\nAttributes: $attrs")

# --- 7. Reopen from disk ---
println("\nReopening from disk...")
z2 = zopen(path)
println("  $(z2)")
println("  Data matches: $(z2[:, :] ≈ data)")

# --- 8. Resize the array ---
println("\nResizing to 720x360...")
resize!(z2, 720, 360)
println("  New size: $(size(z2))")
println("  Old data preserved: $(z2[1:nx, 1:ny] ≈ data)")

# --- 9. Create a group with multiple arrays ---
group_path = joinpath(outdir, "weather.zarr")
g = zgroup(group_path; attrs=Dict{String,Any}("source" => "example"))

# Add arrays to the group by creating them within the store
storage = Zarrs.create_storage(group_path)
temp_meta = Zarrs.build_v3_metadata(; T=Float32, shape=(100, 100), chunks=(50, 50))
Zarrs.LibZarrs.zarrs_create_array_rw(storage.ptr, "/temperature", temp_meta)
pres_meta = Zarrs.build_v3_metadata(; T=Float64, shape=(100, 100), chunks=(50, 50))
Zarrs.LibZarrs.zarrs_create_array_rw(storage.ptr, "/pressure", pres_meta)

g2 = zopen(group_path)
println("\nGroup children: $(collect(keys(g2)))")

println("\nDone.")
