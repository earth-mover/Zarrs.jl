using Test
using Dates
using Zarrs
using Zarrs.Icechunk

# Refreshable credentials. The unit tests need no network. The S3 tests run when
# ZARRS_TEST_S3_ENDPOINT is set (e.g. http://127.0.0.1:9000 for MinIO/RustFS/moto), with
# ZARRS_TEST_S3_BUCKET (default "testbucket") and ZARRS_TEST_S3_KEY_ID / ZARRS_TEST_S3_SECRET.

const _s3_endpoint = get(ENV, "ZARRS_TEST_S3_ENDPOINT", "")
const _s3_bucket = get(ENV, "ZARRS_TEST_S3_BUCKET", "testbucket")
const _s3_key = get(ENV, "ZARRS_TEST_S3_KEY_ID", "testkey")
const _s3_secret = get(ENV, "ZARRS_TEST_S3_SECRET", "testsecret")

_prefix(name) = "zarrs-jl-creds/$(name)-$(round(Int, time() * 1000))-$(rand(UInt16))"

function _s3(prefix, creds)
    S3Storage(bucket=_s3_bucket, prefix=prefix, region="us-east-1", endpoint_url=_s3_endpoint,
              allow_http=true, force_path_style=true, credentials=creds)
end

# A refreshable credentials function that counts its calls; credentials expire after `ttl` seconds.
mutable struct Counter
    n::Threads.Atomic{Int}
end
Counter() = Counter(Threads.Atomic{Int}(0))

function counting_creds(c::Counter; ttl=nothing, allocate=false)
    RefreshableCredentials() do
        Threads.atomic_add!(c.n, 1)
        if allocate  # make the callback allocate and collect, as an HTTP client would
            v = [rand(64) for _ in 1:2_000]
            GC.gc(false)
            length(v)
        end
        expires = ttl === nothing ? nothing : Dates.now(Dates.UTC) + Dates.Millisecond(round(Int, ttl * 1000))
        S3Credentials(_s3_key, _s3_secret; expires_after=expires)
    end
end

function _write_and_commit!(repo, i)
    s = writable_session(repo, "main")
    g = Zarrs.JSON.json(Dict("zarr_format" => 3, "node_type" => "group", "attributes" => Dict("i" => i)))
    Zarrs.LibZarrs.zarrs_create_group_rw(s.zarrs_storage.ptr, "/", g)
    commit(s, "commit $i")
end

@testset "Refreshable credentials" begin
    @testset "types never show secrets" begin
        c = S3Credentials("AKID", "SECRET"; session_token="TOKEN", expires_after=DateTime(2030, 1, 1))
        s = sprint(show, c)
        @test occursin("AKID", s) && !occursin("SECRET", s) && !occursin("TOKEN", s)
        @test !occursin("tok123", sprint(show, GCSBearerToken("tok123")))
        st = S3Storage(bucket="b", credentials=RefreshableCredentials(() -> c))
        @test st.credentials isa RefreshableCredentials
        @test !st.force_path_style
        @test GCSStorage(bucket="b", credentials=RefreshableCredentials(() -> nothing)).credentials !== nothing
    end

    @testset "errors from the Julia function surface as Julia errors" begin
        set_credentials_timeout(30)
        # Nothing listens on port 9; the credentials are needed before any connection is made.
        boom = RefreshableCredentials(() -> error("credentials service is down"))
        st = S3Storage(bucket="b", prefix="p", region="us-east-1", endpoint_url="http://127.0.0.1:9",
                       allow_http=true, force_path_style=true, credentials=boom)
        err = try
            Repository(st)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("credentials service is down", sprint(showerror, err))
        @test Zarrs.LibZarrs.OFFLOAD_BLOCKING_CALLS[]   # switched on by the first registration

        wrong = RefreshableCredentials(() -> "not credentials")
        st = S3Storage(bucket="b", prefix="p", region="us-east-1", endpoint_url="http://127.0.0.1:9",
                       allow_http=true, force_path_style=true, credentials=wrong)
        err = try Repository(st); nothing catch e; e end
        @test err !== nothing && occursin("expected", sprint(showerror, err))
    end

    @testset "a function slower than the timeout fails the operation, not the process" begin
        set_credentials_timeout(2)
        slow = RefreshableCredentials() do
            sleep(5)
            S3Credentials("k", "s")
        end
        st = S3Storage(bucket="b", prefix="p", region="us-east-1", endpoint_url="http://127.0.0.1:9",
                       allow_http=true, force_path_style=true, credentials=slow)
        t = time()
        err = try Repository(st); nothing catch e; e end
        @test err !== nothing && occursin("no answer", sprint(showerror, err))
        @test time() - t < 60
        set_credentials_timeout(120)
        sleep(4)  # let the slow function finish (its late answer is ignored)
    end

    @testset "local repositories still work while calls are off-thread" begin
        repo = Repository(MemoryStorage(); mode=:create)
        _write_and_commit!(repo, 1)
        @test length(list_branches(repo)) == 1
    end

    if isempty(_s3_endpoint)
        @info "Skipping S3 refreshable-credential tests (set ZARRS_TEST_S3_ENDPOINT)"
    else
        @testset "S3: credentials are fetched again after they expire" begin
            c = Counter()
            prefix = _prefix("expiry")
            repo = Repository(_s3(prefix, counting_creds(c; ttl=2)); mode=:create)
            _write_and_commit!(repo, 1)
            first = c.n[]
            @test first >= 1
            sleep(3)                                # credentials expired
            _write_and_commit!(repo, 2)
            @test c.n[] > first                     # icechunk asked again
            sleep(3)
            r2 = Repository(_s3(prefix, counting_creds(c; ttl=2)))
            s = readonly_session(r2; branch="main")
            g = zopen(s)
            @test g isa ZarrsGroup
        end

        @testset "S3: GC pressure from other tasks and from the callback" begin
            c = Counter()
            repo = Repository(_s3(_prefix("gc"), counting_creds(c; ttl=1, allocate=true)); mode=:create)
            stop = Threads.Atomic{Bool}(false)
            stress = Threads.@spawn begin
                n = 0
                while !stop[]
                    v = [rand(256) for _ in 1:500]
                    n += length(v)
                    GC.gc(false)
                    yield()
                end
                n
            end
            for i in 1:6
                _write_and_commit!(repo, i)
                sleep(1.2)                          # expire, so every commit refetches
            end
            stop[] = true
            @test fetch(stress) > 0
            @test c.n[] >= 6
            @test length(list_branches(repo)) == 1
        end

        @testset "S3: concurrent tasks share one credentials function" begin
            c = Counter()
            repo = Repository(_s3(_prefix("concurrent"), counting_creds(c; ttl=1)); mode=:create)
            _write_and_commit!(repo, 0)
            tasks = [Threads.@spawn begin
                         s = readonly_session(repo; branch="main")
                         zopen(s) isa ZarrsGroup
                     end for _ in 1:8]
            @test all(fetch.(tasks))
        end

        @testset "S3: the function is released with its storage" begin
            before = Zarrs.Icechunk._registered_count()
            let
                r = Repository(_s3(_prefix("release"), counting_creds(Counter())); mode=:create)
                @test Zarrs.Icechunk._registered_count() == before + 1
                r = nothing
            end
            for _ in 1:5
                GC.gc(true)
                yield()
                Zarrs.Icechunk._registered_count() == before && break
                sleep(0.2)
            end
            @test Zarrs.Icechunk._registered_count() == before
        end
    end
end
