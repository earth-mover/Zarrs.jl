# Read remote Zarr data over HTTP/HTTPS
#
# This example demonstrates reading Zarr arrays served over HTTPS.
#
# Run from the zarrs-julia/ directory:
#   julia --project examples/http_gefs_read.jl

using Zarrs

# --- Example 1: Read bioimage data from the IDR (Image Data Resource) ---
println("=" ^ 60)
println("Example 1: IDR Bioimage Archive (Zarr V2, S3-backed)")
println("=" ^ 60)

url = "https://uk1s3.embassy.ebi.ac.uk/idr/zarr/v0.4/idr0062A/6001240.zarr/0"
println("Opening: $url")

z = zopen(url)
println("  Array:  ", z)
println("  Shape:  ", size(z))
println("  Type:   ", eltype(z))
println("  Chunks: ", z.chunks)

# Read a small subset
data = z[1:5, 1:5, 1, 1]
println("  Sample [1:5, 1:5, 1, 1]:")
for row in eachrow(data)
    println("    ", row)
end
println()

# --- Example 2: Attempt NOAA GEFS from Dynamical.org ---
println("=" ^ 60)
println("Example 2: NOAA GEFS Analysis (Dynamical.org)")
println("=" ^ 60)

gefs_url = "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr"
println("Opening: $gefs_url")
println("Note: This requires an S3-compatible HTTP server. The basic HTTP")
println("client may not work with all CDN/cloud storage backends.")
println()

try
    g = zopen(gefs_url)
    println("  Opened: ", g)
    if g isa Zarrs.ZarrsGroup
        println("  Children: ", keys(g))
    end
catch e
    println("  Could not open (server may require S3 protocol): ",
            split(string(e), '\n')[1])
    println("  S3 storage support will be added in a future release.")
end

println()
println("Done!")
