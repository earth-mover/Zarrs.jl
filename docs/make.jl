using Documenter
using Zarrs

makedocs(;
    modules=[Zarrs],
    sitename="Zarrs.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://earth-mover.github.io/Zarrs.jl",
        assets=["assets/logo.svg"],
    ),
    logo="assets/logo.svg",
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Cloud & Remote Access" => "cloud.md",
        "Icechunk" => "icechunk.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/earth-mover/Zarrs.jl",
    devbranch="main",
)
