#=
Generate Julia @ccall wrappers for the zarrs_jl C FFI using Clang.jl.

The generated code replaces the hand-written LibZarrs.jl module. Custom
rewriting transforms each raw ccall wrapper into an ergonomic Julia function:

  - CamelCase C names → snake_case Julia names  (zarrsOpenArrayRW → zarrs_open_array_rw)
  - Functions returning ZarrsResult are wrapped with `check_error()`
  - Functions with a `char **` output parameter automatically call
    `unsafe_string` + `zarrsFreeString` and return a String (or nothing)
  - Functions with a `Ptr{Ptr{Cvoid}}` output parameter allocate a Ref,
    call the function, and return the pointer
  - Utility functions (zarrsLastError, zarrsFreeString, zarrsVersion) get
    thin wrappers without error checking

This script regenerates both deps/zarrs_jl/zarrs_jl.h (via the cbindgen CLI)
and src/LibZarrs.jl. Run it after changing any `extern "C"` function in
deps/zarrs_jl/src/ and commit both files; CI fails if they are out of date.

Usage:
    cargo install cbindgen --version "$(cat gen/cbindgen-version)" --locked
    julia --project=gen -e 'using Pkg; Pkg.instantiate()'
    julia --project=gen gen/generator.jl
=#

using Clang
using Clang.Generators
using MacroTools
using JuliaFormatter

const output_dir = joinpath(@__DIR__, "..", "src")
const crate_dir = joinpath(@__DIR__, "..", "deps", "zarrs_jl")
const header_path = joinpath(crate_dir, "zarrs_jl.h")

# ---------------------------------------------------------------------------
# Generate the C header with a pinned cbindgen so the output is reproducible
# ---------------------------------------------------------------------------

const cbindgen_version = strip(read(joinpath(@__DIR__, "cbindgen-version"), String))

let
    found = try
        readchomp(`cbindgen --version`)
    catch
        error("""
        cbindgen not found. Install the pinned version with:
            cargo install cbindgen --version $cbindgen_version --locked
        """)
    end
    if found != "cbindgen $cbindgen_version"
        error("""
        Found `$found`, but gen/cbindgen-version pins $cbindgen_version. Install it with:
            cargo install cbindgen --version $cbindgen_version --locked
        """)
    end
    run(Cmd(`cbindgen --config cbindgen.toml --output zarrs_jl.h`; dir=crate_dir))
end

# ---------------------------------------------------------------------------
# Name conversion:  zarrsCreateStorageFilesystem → zarrs_create_storage_filesystem
# ---------------------------------------------------------------------------

"""
Convert a CamelCase C function name to snake_case.
Handles runs of uppercase letters (e.g. "RW" → "_rw", "HTTP" → "_http", "GCS" → "_gcs").
"""
function camel_to_snake(name::AbstractString)
    # Insert underscore between lowercase/digit and uppercase
    s = replace(name, r"([a-z0-9])([A-Z])" => s"\1_\2")
    # Insert underscore between uppercase runs and a following uppercase+lowercase
    s = replace(s, r"([A-Z]+)([A-Z][a-z])" => s"\1_\2")
    return lowercase(s)
end

# ---------------------------------------------------------------------------
# Classify C functions by their signature pattern
# ---------------------------------------------------------------------------

# Functions that should NOT be wrapped with check_error (they are infrastructure)
const NO_ERROR_CHECK = Set([
    :zarrsLastError,
    :zarrsFreeString,
    :zarrsVersion,
])

# Functions that always use a plain `ccall`, never an off-thread call (see `@zarrs_ccall`):
# fast, never block on I/O, or may run inside finalizers (which must not yield).
function plain_ccall(c_sym::Symbol)
    name = String(c_sym)
    return c_sym in NO_ERROR_CHECK || startswith(name, "zarrsCredentials") ||
           occursin("Destroy", name) || occursin("Free", name)
end

"""
The call expression for a wrapper: `ccall(...)`, or `@zarrs_ccall(...)` for functions that may
block on I/O (and therefore on refreshable credentials served by a Julia task).
"""
function call_expr(c_sym, fname, rettype, argtypes, argvalues)
    plain_ccall(c_sym) && return :(ccall($fname, $rettype, $argtypes, $(argvalues...)))
    return Expr(:macrocall, Symbol("@zarrs_ccall"), LineNumberNode(0), fname, rettype, argtypes, argvalues...)
end

# Functions whose last char** parameter is an output string that must be freed.
# Detected automatically: if last param is Ptr{Ptr{Cchar}} or Ptr{Ptr{UInt8}},
# it's a string output parameter.

# Functions whose last Ptr{Ptr{Cvoid}} parameter is a handle output.
# Detected automatically: if last param is Ptr{Ptr{Cvoid}}.

# ---------------------------------------------------------------------------
# Expression rewriter
# ---------------------------------------------------------------------------

"""
Rewrite a vector of expressions (called by Clang.jl on each header's output).
"""
function rewriter(xs::Vector)
    rewritten = Any[]
    for x in xs
        if x isa String
            push!(rewritten, x)
            continue
        end
        @assert x isa Expr
        push!(rewritten, rewriter(x))
    end
    rewritten
end

"""
Rewrite a single expression — the core transformation logic.

For each ccall wrapper function generated by Clang.jl, we:
1. Rename to snake_case
2. Apply the appropriate wrapper pattern based on return type and parameter types

Output parameter detection:
- `Ptr{Cstring}` (C `char**`) → string output: auto-allocate Ref, call zarrsFreeString
- `Ptr{Ptr{X}}` for any X    → handle output: auto-allocate Ref, return Ptr{Cvoid}
- `Ptr{Int32}` / `Ptr{Csize_t}` as the ONLY trailing pointer → scalar output
- `Ptr{UInt64}` / `Ptr{UInt8}` → buffer pointers, left as-is (caller manages)
"""
function rewriter(x::Expr)
    if !@capture(x, function f_(fargs__)
        ccall(fname_, rettype_, argtypes_, argvalues__)
    end)
        return x  # Not a ccall wrapper — leave unchanged (enums, consts, etc.)
    end

    c_sym = if fname isa QuoteNode
        fname.value
    elseif @capture(fname, (sym_, lib_))
        sym isa QuoteNode ? sym.value : sym
    else
        return x
    end

    # Convert name
    jl_name = Symbol(camel_to_snake(String(c_sym)))

    # --- Utility functions (no error checking) ---
    if c_sym in NO_ERROR_CHECK
        if rettype in (:Cstring, :(Ptr{Cchar}), :(Ptr{UInt8}))
            # zarrsLastError / zarrsVersion → return String
            cc = :(ccall($fname, Ptr{UInt8}, $argtypes, $(argvalues...)))
            return :(function $jl_name($(fargs...))
                ptr = $cc
                ptr == C_NULL && return nothing
                s = unsafe_string(ptr)
                ccall(($(QuoteNode(:zarrsFreeString)), libzarrs_jl), Cvoid, (Ptr{UInt8},), ptr)
                return s
            end) |> prettify
        else
            # zarrsFreeString → pass through. Restrict the argument to C pointers:
            # ccall would otherwise accept a Julia String and free Julia-owned memory.
            cc = :(ccall($fname, $rettype, $argtypes, $(argvalues...)))
            typed_fargs = [:($a::Union{Cstring,Ptr{UInt8}}) for a in fargs]
            return :(function $jl_name($(typed_fargs...))
                $cc
            end) |> prettify
        end
    end

    # --- Standard functions returning ZarrsResult ---
    rettype == :ZarrsResult || error(
        "$c_sym returns $rettype, not ZarrsResult. Add it to NO_ERROR_CHECK " *
        "with a suitable wrapper, or return ZarrsResult from the Rust side.")

    atypes = argtypes.args
    avals = argvalues
    n = length(atypes)
    last_type = n > 0 ? atypes[end] : nothing

    # Clang.jl drops `const`, so check the C prototype: a const trailing pointer
    # is an input and must not be turned into an auto-managed output.
    last_is_const = get(TRAILING_PARAM_IS_CONST, c_sym, false)

    is_string_out = !last_is_const && _is_string_out(last_type)
    is_handle_out = !last_is_const && !is_string_out && _is_handle_out(last_type)
    is_scalar_out = !last_is_const && !is_string_out && !is_handle_out && _is_scalar_out(last_type)

    if is_string_out
        # char** output → allocate Ref{Cstring}, extract string, free
        input_fargs = fargs[1:end-1]
        input_avals = avals[1:end-1]
        cc = call_expr(c_sym, fname, rettype, :(($(atypes...),)), [input_avals..., :_str_ptr])
        return :(function $jl_name($(input_fargs...))
            _str_ptr = Ref{Cstring}(C_NULL)
            _result = $cc
            check_error(_result)
            if _str_ptr[] == C_NULL
                return nothing
            end
            _s = unsafe_string(_str_ptr[])
            ccall(($(QuoteNode(:zarrsFreeString)), libzarrs_jl), Cvoid, (Cstring,), _str_ptr[])
            return _s
        end) |> prettify
    elseif is_handle_out
        # Ptr{Ptr{X}} output → allocate Ref, return opaque pointer
        input_fargs = fargs[1:end-1]
        input_avals = avals[1:end-1]
        cc = call_expr(c_sym, fname, rettype, :(($(atypes...),)), [input_avals..., :_handle_ptr])
        return :(function $jl_name($(input_fargs...))
            _handle_ptr = Ref{Ptr{Cvoid}}(C_NULL)
            _result = $cc
            check_error(_result)
            return _handle_ptr[]
        end) |> prettify
    elseif is_scalar_out
        # Ptr{Int32} / Ptr{Csize_t} scalar output → allocate Ref, return value
        scalar_type = _extract_scalar_type(last_type)
        input_fargs = fargs[1:end-1]
        input_avals = avals[1:end-1]
        cc = call_expr(c_sym, fname, rettype, :(($(atypes...),)), [input_avals..., :_out_ref])
        return :(function $jl_name($(input_fargs...))
            _out_ref = Ref{$scalar_type}(zero($scalar_type))
            _result = $cc
            check_error(_result)
            return _out_ref[]
        end) |> prettify
    else
        # No auto-managed output — just call and check error
        cc = call_expr(c_sym, fname, rettype, argtypes, argvalues)
        return :(function $jl_name($(fargs...))
            _result = $cc
            check_error(_result)
        end) |> prettify
    end
end

# --- Type detection helpers ---

"Detect Ptr{Cstring} — Clang.jl maps `char**` to this."
function _is_string_out(t)
    t === nothing && return false
    return t == :(Ptr{Cstring})
end

"Detect Ptr{Ptr{X}} for any X (handle output)."
function _is_handle_out(t)
    t === nothing && return false
    # Match Ptr{Ptr{X}} for any X — covers StorageHandle, ArrayHandle, etc.
    return @capture(t, Ptr{Ptr{inner_}})
end

"""
Detect scalar output: only Ptr{Int32} and Ptr{Csize_t}.
NOT Ptr{UInt64} or Ptr{UInt8} — those are array/buffer pointers.
"""
function _is_scalar_out(t)
    t === nothing && return false
    return t in (:(Ptr{Int32}), :(Ptr{Csize_t}))
end

function _extract_scalar_type(t)
    @capture(t, Ptr{inner_})
    return inner
end

# ---------------------------------------------------------------------------
# DAG rewriter (called by Clang.jl)
# ---------------------------------------------------------------------------

function rewriter(dag::Clang.ExprDAG)
    for node in Clang.Generators.get_nodes(dag)
        map!(rewriter, node.exprs, node.exprs)
    end
end

# ---------------------------------------------------------------------------
# Run the generator
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Preprocess header: cbindgen emits `enum ZarrsResult { ... }` alongside
# `typedef int32_t ZarrsResult;` (for the #[repr(i32)] Rust enum), and
# Clang.jl's sanity check rejects the duplicate name. Cut the enum block out
# and keep only the int32_t typedef; the variants are read from the block and
# emitted as a Julia @enum in the module prologue below. We write the cleaned
# copy to a temp file and point Clang.jl at that instead of the original header.
# ---------------------------------------------------------------------------

header_text = read(header_path, String)

# Matches the whole block, including the C23 `: int32_t` guard newer cbindgen
# versions put between the name and the opening brace.
const enum_block_re = r"^enum ZarrsResult\b[^{]*\{(?<body>[^}]*)\};\n"m

result_variants = let
    m = match(enum_block_re, header_text)
    m === nothing && error("Could not find `enum ZarrsResult { ... };` in $header_path")
    variants = Pair{String,Int}[]
    for line in split(m[:body], '\n')
        vm = match(r"^\s*(\w+)\s*=\s*(-?\d+)\s*,?\s*$", line)
        vm === nothing || push!(variants, vm[1] => parse(Int, vm[2]))
    end
    ("ZARRS_SUCCESS" => 0) in variants ||
        error("ZarrsResult variants parsed from header lack ZARRS_SUCCESS = 0: $variants")
    variants
end

# C function name → whether its last parameter is declared const.
# Prototypes can span several lines; parameters contain no `(`, `)` or `;`.
const TRAILING_PARAM_IS_CONST = Dict{Symbol,Bool}(
    Symbol(m[1]) => startswith(strip(last(split(m[2], ','))), "const")
    for m in eachmatch(r"\b(\w+)\(([^();]*)\);", header_text)
)

cleaned_header = let
    (tmp, io) = mktemp(; cleanup=true)
    write(io, replace(header_text, enum_block_re => ""))
    close(io)
    # Clang needs a .h extension to parse the file as a C header
    hdr = tmp * ".h"
    mv(tmp, hdr)
    atexit(() -> rm(hdr; force=true))
    hdr
end

result_enum_body = join(("    $name = $value" for (name, value) in result_variants), "\n")

options = load_options(joinpath(@__DIR__, "generator.toml"))
# Resolve the output path relative to this script so it can be run from any directory
options["general"]["output_file_path"] = joinpath(output_dir, "LibZarrs.jl")

args = get_default_args()
# Parse as C11 so the header's C23-only `typedef enum ZarrsResult` branch stays inactive
push!(args, "-std=c11")
# Define ZARRS_ICECHUNK so Clang sees the Icechunk-guarded functions
push!(args, "-DZARRS_ICECHUNK")

ctx = create_context([cleaned_header], args, options)

build!(ctx, BUILDSTAGE_NO_PRINTING)
rewriter(ctx.dag)
build!(ctx, BUILDSTAGE_PRINTING_ONLY)

# ---------------------------------------------------------------------------
# Post-process: wrap output in the API module
# ---------------------------------------------------------------------------

output_path = joinpath(output_dir, "LibZarrs.jl")

raw_content = read(output_path, String)

# Clang.jl turns type names in C doc comments into Documenter `@ref` links, but
# the opaque handle types are plain `Cvoid` aliases with no docstring to link
# to, so the docs build would fail. Keep them as code spans instead.
raw_content = replace(raw_content, r"\[(`[^`\]]+`)\]\(@ref\)" => s"\1")

wrapped = """
# This file is automatically generated by gen/generator.jl — DO NOT EDIT.
#
# To regenerate (also regenerates deps/zarrs_jl/zarrs_jl.h):
#   cargo install cbindgen --version "\$(cat gen/cbindgen-version)" --locked
#   julia --project=gen -e 'using Pkg; Pkg.instantiate()'
#   julia --project=gen gen/generator.jl

module LibZarrs

# Library path — must be a plain String for ccall((:sym, lib), ...) to work.
# Initialized in __init__() and accessed by all generated ccall wrappers.
libzarrs_jl::String = ""

function __init__()
    global libzarrs_jl = joinpath(@__DIR__, "..", "deps", "lib",
        Sys.iswindows() ? "zarrs_jl.dll" :
        Sys.isapple()   ? "libzarrs_jl.dylib" :
                          "libzarrs_jl.so")
    if !isfile(libzarrs_jl)
        error("zarrs_jl shared library not found at \$(libzarrs_jl). Run `julia deps/build.jl` first.")
    end
end

# ---------------------------------------------------------------------------
# ZarrsResult enum — variants read from `enum ZarrsResult` in zarrs_jl.h.
# Emitted here rather than by Clang.jl because cbindgen also declares
# `typedef int32_t ZarrsResult`, which Clang.jl rejects as a duplicate name.
# ---------------------------------------------------------------------------

@enum ZarrsResult::Cint begin
$result_enum_body
end

# Values for the `pretty` argument of the JSON metadata/attribute getters
const JSON_COMPACT = Cint(0)
const JSON_PRETTY = Cint(1)

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

function check_error(result::ZarrsResult)
    result == ZARRS_SUCCESS && return
    msg_ptr = ccall((:zarrsLastError, libzarrs_jl), Ptr{UInt8}, ())
    msg = msg_ptr != C_NULL ? unsafe_string(msg_ptr) : "Unknown zarrs error"
    if msg_ptr != C_NULL
        ccall((:zarrsFreeString, libzarrs_jl), Cvoid, (Ptr{UInt8},), msg_ptr)
    end
    error("zarrs error (\$result): \$msg")
end

# ---------------------------------------------------------------------------
# Off-thread calls (refreshable credentials)
#
# Icechunk asks for refreshable credentials on Tokio threads, and Zarrs.jl answers them with an
# ordinary Julia task (see `Zarrs.Icechunk.RefreshableCredentials`). That task can only run if the
# Julia thread that made the FFI call is not blocked inside it. So once refreshable credentials
# exist, every call that may block on I/O runs on a libuv worker thread while the calling task
# yields. The worker thread is adopted by Julia to run the call wrapper, so the C call itself runs
# in a GC-safe region: otherwise a garbage collection started by the credentials task would wait
# forever for that worker. Before refreshable credentials exist, calls are plain `ccall`s.
# ---------------------------------------------------------------------------

"Set (never cleared) when refreshable credentials are first registered."
const OFFLOAD_BLOCKING_CALLS = Threads.Atomic{Bool}(false)

# At most UV_THREADPOOL_SIZE - 2 concurrent off-thread calls, so that libuv worker threads stay
# free for DNS lookups and file I/O, which the credentials task may need.
const OFFLOAD_LIMIT = Base.Semaphore(max(1, parse(Int, get(ENV, "UV_THREADPOOL_SIZE", "4")) - 2))

\"\"\"
    @gcsafe_threadcall((cfunc, clib), rettype, (argtypes...), argvals...)

Like `Base.@threadcall`, but the C function runs in a GC-safe region (`@ccall gc_safe=true`), and
concurrency is limited by `OFFLOAD_LIMIT`. The C function must not call back into Julia.
\"\"\"
macro gcsafe_threadcall(f, rettype, argtypes, argvals...)
    isa(argtypes, Expr) && argtypes.head === :tuple || error("argument types must be a tuple")
    length(argtypes.args) == length(argvals) || error("wrong number of arguments to C function")
    f = esc(f)
    rettype = esc(rettype)
    argtypes = map(esc, argtypes.args)
    argvals = map(esc, argvals)
    wrapper = :(function (fptr::Ptr{Cvoid}, args_ptr::Ptr{Cvoid}, retval_ptr::Ptr{Cvoid})
        p = args_ptr
    end)
    body = wrapper.args[2].args
    typed = Expr[]
    for (i, T) in enumerate(argtypes)
        arg = Symbol("arg", i)
        push!(body, :(\$arg = unsafe_load(convert(Ptr{\$T}, p))))
        push!(body, :(p += Core.sizeof(\$T)))
        push!(typed, :(\$arg::\$T))
    end
    call = Expr(:(::), Expr(:call, Expr(:\$, :fptr), typed...), rettype)
    push!(body, :(ret = @ccall gc_safe = true \$call))
    push!(body, :(unsafe_store!(convert(Ptr{\$rettype}, retval_ptr), ret)))
    push!(body, :(return Int(Core.sizeof(\$rettype))))
    wrapper = Expr(:var"hygienic-scope", wrapper, @__MODULE__, __source__)
    return :(let fun_ptr = @cfunction(\$wrapper, Int, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
        Base.acquire(OFFLOAD_LIMIT) do
            Base.do_threadcall(fun_ptr, cglobal(\$f), \$rettype, Any[\$(argtypes...)], Any[\$(argvals...)])
        end
    end)
end

\"\"\"
    @zarrs_ccall((cfunc, clib), rettype, (argtypes...), argvals...)

A `ccall` that runs off-thread (`@gcsafe_threadcall`) once `OFFLOAD_BLOCKING_CALLS` is set.
On Julia < 1.12 (no `@ccall gc_safe`), always a plain `ccall`; refreshable credentials then
refuse to start (see `Zarrs.Icechunk.RefreshableCredentials`).
\"\"\"
macro zarrs_ccall(f, rettype, argtypes, argvals...)
    plain = Expr(:call, :ccall, f, rettype, argtypes, argvals...)
    VERSION < v"1.12-" && return esc(plain)
    offloaded = Expr(:macrocall, Symbol("@gcsafe_threadcall"), __source__, f, rettype, argtypes, argvals...)
    return esc(:(OFFLOAD_BLOCKING_CALLS[] ? \$offloaded : \$plain))
end

# ---------------------------------------------------------------------------
# Generated bindings
# ---------------------------------------------------------------------------

$raw_content

end # module LibZarrs
"""

write(output_path, wrapped)

# Format the generated file
format(output_path)

println("Generated $(output_path)")
println("Done.")
