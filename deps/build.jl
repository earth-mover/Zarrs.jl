function build()
    # Step 1: Check if a JLL package provides prebuilt binaries
    lib_name = Sys.iswindows() ? "zarrs_jl.dll" :
               Sys.isapple()   ? "libzarrs_jl.dylib" :
                                 "libzarrs_jl.so"
    dst_dir = joinpath(@__DIR__, "lib")

    # Try loading from zarrs_jl_jll (available after BinaryBuilder registration)
    try
        @eval using zarrs_jl_jll
        if zarrs_jl_jll.is_available()
            mkpath(dst_dir)
            cp(zarrs_jl_jll.libzarrs_jl_path, joinpath(dst_dir, lib_name); force=true)
            @info "Using prebuilt binary from zarrs_jl_jll" path=joinpath(dst_dir, lib_name)
            return
        end
    catch
        # JLL not available; fall through to source build
    end

    # Step 2: Fall back to source compilation (requires Rust toolchain)
    cargo = Sys.which("cargo")
    cargo === nothing && error(
        "No prebuilt binary available and Rust toolchain not found.\n" *
        "Install from https://rustup.rs"
    )

    src_dir = joinpath(@__DIR__, "zarrs_jl")
    manifest = joinpath(src_dir, "Cargo.toml")
    run(`$cargo build --release --manifest-path $manifest`)

    src_lib = joinpath(src_dir, "target", "release", lib_name)
    mkpath(dst_dir)
    cp(src_lib, joinpath(dst_dir, lib_name); force=true)
    @info "zarrs_jl library built from source" path=joinpath(dst_dir, lib_name)
end

build()
