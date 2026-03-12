using Test
using Zarrs
using Zarrs.Icechunk

# Helper: create a root group in a writable session
function _create_root_group(session)
    storage = session.zarrs_storage
    metadata = Zarrs.JSON.json(Dict("zarr_format" => 3, "node_type" => "group", "attributes" => Dict()))
    group_ptr = Zarrs.LibZarrs.zarrs_create_group_rw(storage.ptr, "/", metadata)
    Zarrs.ZarrsGroupHandle(group_ptr, storage)
    return nothing
end

# Helper: create an array in a session
function _create_array(session, path, T, shape, chunks)
    N = length(shape)
    metadata = Zarrs.build_v3_metadata(;
        T=T, shape=NTuple{N,Int}(shape), chunks=NTuple{N,Int}(chunks),
        compressor="none", fill_value=Zarrs._default_fill_value(T))
    arr_ptr = Zarrs.LibZarrs.zarrs_create_array_rw(
        session.zarrs_storage.ptr, path, metadata)
    arr_handle = Zarrs.ZarrsArrayHandle(arr_ptr, session.zarrs_storage)
    return Zarrs.ZarrsArray{T,N}(
        arr_handle, session.zarrs_storage,
        Ref(NTuple{N,Int}(shape)), NTuple{N,Int}(chunks), "icechunk")
end

@testset "Icechunk" begin

    @testset "Memory round-trip" begin
        storage = MemoryStorage()
        repo = Repository(storage; mode=:create)

        # Write data
        session = writable_session(repo, "main")
        _create_root_group(session)

        arr = _create_array(session, "/data", Float32, (4, 4), (2, 2))
        data = Float32[1 2 3 4; 5 6 7 8; 9 10 11 12; 13 14 15 16]
        arr[:, :] = data
        @test arr[:, :] == data

        # Uncommitted changes
        @test has_uncommitted_changes(session)

        # Commit
        snap_id = commit(session, "initial data")
        @test !isempty(snap_id)

        # Read back via readonly session
        session_ro = readonly_session(repo; branch="main")
        g_ro = zopen(session_ro)
        @test g_ro isa ZarrsGroup
        arr_ro = g_ro["data"]
        @test arr_ro[:, :] == data
    end

    @testset "Local filesystem round-trip" begin
        mktempdir() do dir
            storage = LocalStorage(dir)
            repo = Repository(storage; mode=:create)

            session = writable_session(repo, "main")
            _create_root_group(session)

            arr = _create_array(session, "/values", Int32, (8,), (4,))
            arr[:] = Int32.(1:8)
            snap_id = commit(session, "add values")
            @test !isempty(snap_id)

            # Read back
            session_ro = readonly_session(repo; branch="main")
            g = zopen(session_ro)
            v = g["values"]
            @test v[:] == Int32.(1:8)
        end
    end

    @testset "Branch & tag management" begin
        storage = MemoryStorage()
        repo = Repository(storage; mode=:create)

        # Create initial data so we have a snapshot
        session = writable_session(repo, "main")
        _create_root_group(session)
        arr = _create_array(session, "/x", Float64, (2,), (2,))
        arr[:] = [1.0, 2.0]
        snap_id = commit(session, "initial")
        @test !isempty(snap_id)

        # List branches
        branches = list_branches(repo)
        @test "main" in branches

        # Lookup branch
        main_snap = lookup_branch(repo, "main")
        @test !isempty(main_snap)

        # Create branch
        create_branch(repo, "dev", main_snap)
        branches = list_branches(repo)
        @test "dev" in branches

        # Delete branch
        delete_branch(repo, "dev")
        branches = list_branches(repo)
        @test !("dev" in branches)

        # Create tag
        create_tag(repo, "v1.0", main_snap)
        tags = list_tags(repo)
        @test "v1.0" in tags

        # Lookup tag
        tag_snap = lookup_tag(repo, "v1.0")
        @test tag_snap == main_snap

        # Delete tag
        delete_tag(repo, "v1.0")
        tags = list_tags(repo)
        @test !("v1.0" in tags)
    end

    @testset "Session GC safety" begin
        storage = MemoryStorage()
        repo = Repository(storage; mode=:create)

        # Create initial commit so sessions can open
        session = writable_session(repo, "main")
        _create_root_group(session)
        commit(session, "init")
        session = nothing

        for _ in 1:5
            s = readonly_session(repo; branch="main")
            g = zopen(s)
            s = nothing
            g = nothing
        end
        GC.gc(); GC.gc()
        # If we get here without a segfault, the test passes
        @test true
    end

    @testset "S3 read-only (network)" begin
        if get(ENV, "ZARRS_TEST_NETWORK", "") == ""
            @info "Skipping S3 network test (set ZARRS_TEST_NETWORK=1 to enable)"
        else
            s3 = S3Storage(
                bucket    = "dynamical-noaa-hrrr",
                prefix    = "noaa-hrrr-forecast-48-hour/v0.1.0.icechunk",
                region    = "us-west-2",
                anonymous = true,
            )
            repo = Repository(s3)
            session = readonly_session(repo; branch="main")
            g = zopen(session)
            @test g isa ZarrsGroup
            @test length(keys(g)) > 0

            # Read a small subset
            lat = g["latitude"]
            @test ndims(lat) >= 2
            val = lat[1, 1]
            @test val isa Number
        end
    end

end
