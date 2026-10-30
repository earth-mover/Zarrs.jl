using Test
using Dates
using Zarrs
using Zarrs.Icechunk

@testset "Icechunk virtual chunks" begin

    @testset "credential and config JSON" begin
        IC = Zarrs.Icechunk
        @test IC._credentials_dict("s3://b/", :anonymous) ==
              Dict("credential_type" => "s3", "s3_credential_type" => "anonymous")
        @test IC._credentials_dict("gs://b/", :from_env)["gcs_credential_type"] == "from_env"
        @test IC._credentials_dict("file:///x/", nothing) == Dict("credential_type" => "local_file_system_access")
        @test IC._credentials_dict("https://h/", nothing) == Dict("credential_type" => "http_access")
        @test IC._credentials_dict("s3://b/", S3Credentials("k", "s"))["access_key_id"] == "k"
        @test_throws ArgumentError IC._credentials_dict("s3://b/", nothing)
        @test_throws ArgumentError IC._credentials_dict("file:///x/", :anonymous)
        @test_throws ArgumentError VirtualChunkContainer("s3://b", s3_store())
        @test haskey(s3_store(endpoint_url="http://localhost:9000").json, "s3_compatible")

        # every credential kind is accepted by the library
        config = RepositoryConfig(virtual_chunk_containers=[
            VirtualChunkContainer("s3://a/", s3_store(region="us-east-1")),
            VirtualChunkContainer("s3://b/", s3_store(endpoint_url="http://127.0.0.1:9000", allow_http=true)),
            VirtualChunkContainer("gs://c/", gcs_store()),
            VirtualChunkContainer("https://example.com/d/", http_store(headers=Dict("X-Test" => "1")))])
        repo = Repository(MemoryStorage(); mode=:create, config,
                          authorize_virtual_chunk_access=Dict(
                              "s3://a/" => :anonymous,
                              "s3://b/" => S3Credentials("k", "s"; expires_after=DateTime(2099, 1, 1)),
                              "gs://c/" => :anonymous, "https://example.com/d/" => nothing))
        @test length(repository_config(repo)["virtual_chunk_containers"]) == 4
    end

    @testset "local files: write refs, read through containers" begin
        mktempdir() do dir
            # Two "files" of raw little-endian Float64 chunks, 4 values per chunk.
            datafile = joinpath(dir, "data", "raw.bin")
            mkpath(dirname(datafile))
            values = collect(1.0:12.0)
            write(datafile, htol.(values))
            prefix = "file://" * joinpath(dir, "data") * "/"

            config = RepositoryConfig(virtual_chunk_containers=[
                VirtualChunkContainer(prefix, local_filesystem_store(joinpath(dir, "data")))])
            repo_dir = joinpath(dir, "repo")
            repo = Repository(LocalStorage(repo_dir); mode=:create, config,
                              authorize_virtual_chunk_access=Dict(prefix => nothing))
            @test haskey(repository_config(repo)["virtual_chunk_containers"], prefix)

            s = writable_session(repo, "main")
            create_group(s)
            create_array(s, "v", Float64, 12; chunks=(4,), compressor="none", fill_value=-1.0)
            for c in 0:2
                set_virtual_ref(s, "v/c/$c", prefix * "raw.bin"; offset=c * 32, length=32)
            end
            @test zopen(s, "v")[:] == values
            # a location outside every container is rejected
            @test_throws ErrorException set_virtual_ref(s, "v/c/0", "file:///elsewhere/x.bin";
                                                        offset=0, length=32)
            commit(s, "virtual")

            r = readonly_session(repo)
            @test zopen(r, "v")[:] == values
            @test virtual_chunk_locations(r) == [prefix * "raw.bin"]

            # The container was stored with the repository; reading still needs authorization.
            repo2 = Repository(LocalStorage(repo_dir); authorize_virtual_chunk_access=Dict(prefix => nothing))
            @test zopen(readonly_session(repo2), "v")[5:8] == values[5:8]
            repo3 = Repository(LocalStorage(repo_dir))
            @test_throws Exception zopen(readonly_session(repo3), "v")[:]

            # A stale reference (object changed since) fails instead of returning wrong data.
            s = writable_session(repo2, "main")
            set_virtual_ref(s, "v/c/0", prefix * "raw.bin"; offset=0, length=32,
                            last_modified=DateTime(2000, 1, 1))
            commit(s, "pinned to an old modification time")
            @test_throws Exception zopen(readonly_session(repo2), "v")[1:4]
        end
    end

    @testset "save_config persists containers added on open" begin
        mktempdir() do dir
            Repository(LocalStorage(dir); mode=:create)
            prefix = "s3://example-bucket/"
            config = RepositoryConfig(virtual_chunk_containers=[VirtualChunkContainer(prefix, s3_store(region="us-east-1"))],
                                      inline_chunk_threshold_bytes=64)
            repo = Repository(LocalStorage(dir); config)
            @test repository_config(repo)["inline_chunk_threshold_bytes"] == 64
            @test !haskey(something(repository_config(Repository(LocalStorage(dir)))["virtual_chunk_containers"], Dict()), prefix)
            save_config(repo)
            stored = repository_config(Repository(LocalStorage(dir)))
            @test haskey(stored["virtual_chunk_containers"], prefix)
            @test stored["inline_chunk_threshold_bytes"] == 64
        end
    end
end
