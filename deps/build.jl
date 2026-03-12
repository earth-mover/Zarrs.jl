function build()
    cargo = Sys.which("cargo")
    cargo === nothing && error(
        "Rust toolchain not found. Install from https://rustup.rs"
    )

    src_dir = joinpath(@__DIR__, "zarrs_jl")
    manifest = joinpath(src_dir, "Cargo.toml")
    run(`$cargo build --release --manifest-path $manifest`)

    lib_name = Sys.iswindows() ? "zarrs_jl.dll" :
               Sys.isapple()   ? "libzarrs_jl.dylib" :
                                 "libzarrs_jl.so"

    src_lib = joinpath(src_dir, "target", "release", lib_name)
    dst_dir = joinpath(@__DIR__, "lib")
    mkpath(dst_dir)
    cp(src_lib, joinpath(dst_dir, lib_name); force=true)
    @info "zarrs_jl library installed" path=joinpath(dst_dir, lib_name)
end

build()
