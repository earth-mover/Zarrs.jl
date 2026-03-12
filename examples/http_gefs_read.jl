# Read remote Zarr data over HTTP/HTTPS
#
# This example demonstrates reading a Zarr V3 store served over HTTPS
# from Dynamical.org's NOAA GEFS analysis dataset.
#
# Run from the zarrs-julia/ directory:
#   julia --project examples/http_gefs_read.jl

using Zarrs

println("=" ^ 60)
println("NOAA GEFS Analysis (Dynamical.org, Zarr V3)")
println("=" ^ 60)

gefs_url = "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr"
println("Opening: $gefs_url")

g = zopen(gefs_url)
println("  Opened: ", g)
if g isa Zarrs.ZarrsGroup
    println("  Children: ", keys(g))

    # Open a child array
    arr = g["temperature_2m"]
    println("  temperature_2m: ", arr)
    println("    Shape:  ", size(arr))
    println("    Type:   ", eltype(arr))

    # Read a small subset
    sample = arr[700:705, 360:362, 40000]
    println("    Sample [700:705, 360:362, 40000]:")
    println("    ", sample)
end

println()
println("Done!")
