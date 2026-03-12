# Read NOAA HRRR weather forecast data from an Icechunk store on S3
#
# This example opens the Dynamical.org HRRR 48-hour forecast dataset,
# which is stored as an Icechunk repository on S3 with anonymous access.
#
# Dataset: NOAA High-Resolution Rapid Refresh (HRRR) — 3km resolution
#          continental US weather forecasts.
#
# Run from the zarrs-julia/ directory:
#   julia --project examples/icechunk_hrrr.jl

using Zarrs

const STORE = "icechunk://dynamical-noaa-hrrr/noaa-hrrr-forecast-48-hour/v0.1.0.icechunk"

println("Opening Icechunk store: $STORE")
g = zopen(STORE; anonymous=true, region="us-west-2")
println("  $(length(keys(g))) variables found")
println()

# --- List all variables ---
println("Variables:")
for name in sort(collect(keys(g)))
    arr = g[name]
    if arr isa ZarrsArray && ndims(arr) >= 2
        println("  $name: $(join(size(arr), "×"))  $(eltype(arr))")
    else
        println("  $name: $(size(arr))  $(eltype(arr))")
    end
end
println()

# --- Read coordinate data ---
lat = g["latitude"]
lon = g["longitude"]
println("Spatial domain:")
println("  Latitude:  $(lat[1,1])°N to $(lat[end,end])°N")
println("  Longitude: $(lon[1,1])°E to $(lon[end,end])°E")
println("  Grid:      $(size(lat, 1)) × $(size(lat, 2)) (~3km resolution)")
println()

# --- Read temperature data ---
temp = g["temperature_2m"]
println("2m Temperature (temperature_2m):")
println("  Shape:  $(size(temp)) (x, y, lead_time, init_time)")
println("  Chunks: $(temp.chunks)")
println("  Type:   $(eltype(temp))")
println()

# Read a spatial subset at the most recent initialization time
# and the first forecast lead time (analysis, t+0)
println("Reading temperature for most recent forecast (lead_time=0)...")
subset = temp[1:10, 1:10, 1, end]
println("  temp_2m[1:10, 1:10, 1, end] (°C above absolute zero):")
using Printf
for i in 1:5
    row = [@sprintf("%.1f", subset[i, j]) for j in 1:5]
    println("    ", join(row, "  "))
end
println("    ...")
println()

# --- Read wind data ---
wind_u = g["wind_u_10m"]
wind_v = g["wind_v_10m"]
u = wind_u[500, 500, 1, end]
v = wind_v[500, 500, 1, end]
speed = sqrt(u^2 + v^2)
println("10m wind at grid point (500, 500), latest forecast:")
println("  u = $(@sprintf("%.2f", u)) m/s")
println("  v = $(@sprintf("%.2f", v)) m/s")
println("  speed = $(@sprintf("%.2f", speed)) m/s")
println()

println("Done!")
