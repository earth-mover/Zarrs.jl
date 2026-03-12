using Documenter
using Zarrs

makedocs(;
    modules=[Zarrs],
    sitename="Zarrs.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://zarrs.github.io/zarrs-julia",
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Cloud & Remote Access" => "cloud.md",
        "Icechunk" => "icechunk.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/zarrs/zarrs-julia",
    devbranch="main",
)
