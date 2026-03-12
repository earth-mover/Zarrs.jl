# Icechunk round-trip example — write, commit, branch, tag, and read back
#
# This example uses in-memory storage (no cloud credentials needed).
# Swap MemoryStorage() for LocalStorage("/tmp/my-repo") to persist to disk.
#
# Run from the zarrs-julia/ directory:
#   julia --project examples/icechunk_roundtrip.jl

using Zarrs
using Zarrs.Icechunk

# ---------------------------------------------------------------------------
# 1. Create a repository
# ---------------------------------------------------------------------------
println("=== Creating Icechunk repository (in-memory) ===")
storage = MemoryStorage()
repo = Repository(storage; mode=:create)

# ---------------------------------------------------------------------------
# 2. Write data on the "main" branch
# ---------------------------------------------------------------------------
session = writable_session(repo, "main")

# Create a root group
root_storage = session.zarrs_storage
group_meta = Zarrs.JSON.json(Dict(
    "zarr_format" => 3, "node_type" => "group",
    "attributes" => Dict("description" => "Weather forecast demo"),
))
Zarrs.LibZarrs.zarrs_create_group_rw(root_storage.ptr, "/", group_meta)

# Create a temperature array (12 months × 180 latitudes × 360 longitudes)
nx, ny, nt = 360, 180, 12
meta = Zarrs.build_v3_metadata(;
    T        = Float32,
    shape    = (nx, ny, nt),
    chunks   = (90, 90, 12),
    compressor       = "zstd",
    compressor_level = 3,
    fill_value       = Float32(NaN),
    dimension_names  = ("longitude", "latitude", "month"),
)
arr_ptr = Zarrs.LibZarrs.zarrs_create_array_rw(root_storage.ptr, "/temperature", meta)
arr_handle = Zarrs.ZarrsArrayHandle(arr_ptr, root_storage)
temp = Zarrs.ZarrsArray{Float32,3}(
    arr_handle, root_storage,
    Ref((nx, ny, nt)), (90, 90, 12), "icechunk",
)

# Fill with a simple latitude/seasonal model
lon = range(-180f0, 179f0, length=nx)
lat = range(-90f0, 89f0, length=ny)
data = Array{Float32}(undef, nx, ny, nt)
for m in 1:nt, j in 1:ny, i in 1:nx
    seasonal = 5f0 * cospi(2f0 * (m - 1) / 12)
    data[i, j, m] = 20f0 - 30f0 * abs(lat[j]) / 90f0 + seasonal
end
temp[:, :, :] = data
println("Wrote temperature array: $(size(temp))")

# Create a pressure array
pres_meta = Zarrs.build_v3_metadata(;
    T=Float64, shape=(nx, ny), chunks=(90, 90),
    compressor="zstd", fill_value=0.0,
    dimension_names=("longitude", "latitude"),
)
pres_ptr = Zarrs.LibZarrs.zarrs_create_array_rw(root_storage.ptr, "/pressure", pres_meta)
pres_handle = Zarrs.ZarrsArrayHandle(pres_ptr, root_storage)
pressure = Zarrs.ZarrsArray{Float64,2}(
    pres_handle, root_storage,
    Ref((nx, ny)), (90, 90), "icechunk",
)
pres_data = [1013.25 + 10.0 * sin(2π * lo / 360) for lo in lon, la in lat]
pressure[:, :] = pres_data
println("Wrote pressure array:    $(size(pressure))")

# ---------------------------------------------------------------------------
# 3. Commit
# ---------------------------------------------------------------------------
println("\n=== Committing initial data ===")
snap1 = commit(session, "Add temperature and pressure arrays")
println("Snapshot ID: $snap1")

# ---------------------------------------------------------------------------
# 4. Read back via a read-only session
# ---------------------------------------------------------------------------
println("\n=== Reading back from main branch ===")
ro = readonly_session(repo; branch="main")
g = zopen(ro)
println("Root group children: $(collect(keys(g)))")

t = g["temperature"]
println("temperature shape: $(size(t)), eltype: $(eltype(t))")

# Verify round-trip
readback = t[:, :, :]
maxerr = maximum(abs.(readback .- data))
println("Round-trip max error: $maxerr")

p = g["pressure"]
println("pressure shape:    $(size(p)), eltype: $(eltype(p))")
println("pressure[1,1]:     $(p[1,1]) hPa")

# ---------------------------------------------------------------------------
# 5. Branch, modify, commit
# ---------------------------------------------------------------------------
println("\n=== Creating 'experiment' branch and modifying data ===")
create_branch(repo, "experiment", snap1)
branches = list_branches(repo)
println("Branches: $branches")

exp_session = writable_session(repo, "experiment")

# Overwrite a slice of temperature (set January to 0°C everywhere)
exp_g = zopen(exp_session)
exp_temp = exp_g["temperature"]
exp_temp[:, :, 1] = zeros(Float32, nx, ny)

snap2 = commit(exp_session, "Zero out January temperature")
println("Experiment snapshot: $snap2")

# Verify main is unchanged
main_ro = readonly_session(repo; branch="main")
main_temp = zopen(main_ro)["temperature"]
@assert main_temp[1, 1, 1] ≈ data[1, 1, 1] "Main branch should be unchanged"
println("Main branch Jan temp[1,1,1]: $(main_temp[1,1,1]) (unchanged)")

# Verify experiment branch has zeroed January
exp_ro = readonly_session(repo; branch="experiment")
exp_temp_ro = zopen(exp_ro)["temperature"]
@assert exp_temp_ro[1, 1, 1] == 0f0 "Experiment branch should have zero"
println("Experiment branch Jan temp[1,1,1]: $(exp_temp_ro[1,1,1]) (zeroed)")

# ---------------------------------------------------------------------------
# 6. Tag a release
# ---------------------------------------------------------------------------
println("\n=== Tagging releases ===")
create_tag(repo, "v1.0", snap1)
create_tag(repo, "v2.0-experiment", snap2)
println("Tags: $(list_tags(repo))")

# Read from a tag
tagged = readonly_session(repo; tag="v1.0")
tagged_g = zopen(tagged)
println("v1.0 tag — temperature[180,90,6]: $(tagged_g["temperature"][180, 90, 6])")

# ---------------------------------------------------------------------------
# 7. Lookup and inspect
# ---------------------------------------------------------------------------
println("\n=== Snapshot lookup ===")
main_snap = lookup_branch(repo, "main")
exp_snap  = lookup_branch(repo, "experiment")
v1_snap   = lookup_tag(repo, "v1.0")
println("main branch  -> $main_snap")
println("experiment   -> $exp_snap")
println("v1.0 tag     -> $v1_snap")
@assert main_snap == v1_snap "v1.0 tag should match main branch tip"

# ---------------------------------------------------------------------------
# 8. Cleanup
# ---------------------------------------------------------------------------
println("\n=== Cleanup ===")
delete_tag(repo, "v2.0-experiment")
delete_branch(repo, "experiment")
println("Remaining branches: $(list_branches(repo))")
println("Remaining tags:     $(list_tags(repo))")

println("\nDone!")
