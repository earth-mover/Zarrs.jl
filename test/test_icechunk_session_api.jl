using Test
using Dates
using Zarrs
using Zarrs.Icechunk

@testset "Icechunk session API" begin

    @testset "create_group / create_array / zopen(session, path)" begin
        repo = Repository(MemoryStorage(); mode=:create)
        s = writable_session(repo, "main")
        root = create_group(s; attributes=Dict("title" => "demo"))
        @test root isa ZarrsGroup
        create_group(s, "nested"; attributes=Dict(:level => 1))
        a = create_array(s, "nested/temp", Float32, 6, 4; chunks=(3, 2),
                         dimension_names=("x", "y"), attributes=Dict("units" => "K"),
                         fill_value=-1f0)
        @test a isa ZarrsArray{Float32,2}
        @test size(a) == (6, 4)
        data = reshape(Float32.(1:24), 6, 4)
        a[:, :] = data
        b = create_array(s, "/flags", UInt8, 5; compressor="none")
        b[:] = UInt8[1, 2, 3, 4, 5]
        # raw metadata form
        meta = Dict("zarr_format" => 3, "node_type" => "array", "shape" => [3],
                    "data_type" => "int16", "fill_value" => 7,
                    "chunk_grid" => Dict("name" => "regular", "configuration" => Dict("chunk_shape" => [2])),
                    "chunk_key_encoding" => Dict("name" => "default", "configuration" => Dict("separator" => "/")),
                    "codecs" => [Dict("name" => "bytes", "configuration" => Dict("endian" => "little"))],
                    "attributes" => Dict("raw" => true))
        c = create_array(s, "raw", metadata=meta)
        @test c isa ZarrsArray{Int16,1}
        @test c[:] == Int16[7, 7, 7]
        commit(s, "create nodes")

        r = readonly_session(repo)
        @test zopen(r, "nested/temp")[:, :] == data
        @test get_attributes(zopen(r, "nested/temp")) == Dict("units" => "K")
        @test dimnames(zopen(r, "nested/temp")) == ("x", "y")
        @test zopen(r, "flags")[:] == UInt8[1, 2, 3, 4, 5]
        @test get_attributes(zopen(r, "/")) == Dict("title" => "demo")
        @test get_attributes(zopen(r, "nested")) == Dict("level" => 1)
        @test get_attributes(zopen(r, "raw")) == Dict("raw" => true)
        @test sort(keys(zopen(r))) == ["flags", "nested", "raw"]
        @test_throws ErrorException create_group(r, "nope")   # read-only session
    end

    @testset "No _zarrs attribute by default" begin
        @test include_zarrs_metadata() == false
        repo = Repository(MemoryStorage(); mode=:create)
        s = writable_session(repo, "main")
        create_group(s)
        a = create_array(s, "a", Int32, 4; chunks=(2,))
        meta = Zarrs.JSON.parse(Zarrs.LibZarrs.zarrs_array_get_metadata_string(a.handle.ptr, Zarrs.LibZarrs.JSON_COMPACT))
        @test !haskey(get(meta, "attributes", Dict()), "_zarrs")
        try
            set_include_zarrs_metadata!(true)
            @test include_zarrs_metadata()
            b = create_array(s, "b", Int32, 4; chunks=(2,))
            stored = String(Zarrs.LibZarrs.zarrs_jl_storage_get(s.zarrs_storage.ptr, "b/zarr.json"))
            @test occursin("_zarrs", stored)
            stored_a = String(Zarrs.LibZarrs.zarrs_jl_storage_get(s.zarrs_storage.ptr, "a/zarr.json"))
            @test !occursin("_zarrs", stored_a)
        finally
            set_include_zarrs_metadata!(false)
        end
    end

    @testset "Sessions by snapshot id and as_of" begin
        repo = Repository(MemoryStorage(); mode=:create)
        s = writable_session(repo, "main")
        create_group(s)
        a = create_array(s, "v", Int64, 3; chunks=(3,))
        a[:] = [1, 2, 3]
        snap1 = commit(s, "v1")
        sleep(0.05)
        t_between = Dates.now(Dates.UTC)
        sleep(0.05)
        s = writable_session(repo, "main")
        @test snapshot_id(s) == snap1
        @test session_branch(s) == "main"
        zopen(s, "v")[:] = [10, 20, 30]
        snap2 = commit(s, "v2")

        r1 = readonly_session(repo; snapshot_id=snap1)
        @test zopen(r1, "v")[:] == [1, 2, 3]
        @test snapshot_id(r1) == snap1
        @test session_branch(r1) === nothing
        @test zopen(readonly_session(repo; snapshot_id=snap2), "v")[:] == [10, 20, 30]
        r_asof = readonly_session(repo; branch="main", as_of=t_between)
        @test snapshot_id(r_asof) == snap1
        @test zopen(r_asof, "v")[:] == [1, 2, 3]
        @test zopen(readonly_session(repo; as_of=Dates.now(Dates.UTC) + Dates.Minute(1)), "v")[:] == [10, 20, 30]
        @test_throws ArgumentError readonly_session(repo; tag="x", snapshot_id=snap1)
        @test_throws ErrorException readonly_session(repo; snapshot_id="not-a-snapshot")
    end

    @testset "status, diff, discard_changes" begin
        repo = Repository(MemoryStorage(); mode=:create)
        s = writable_session(repo, "main")
        create_group(s)
        create_array(s, "a", Float64, 4; chunks=(2,))[1:2] = [1.0, 2.0]
        st = status(s)
        @test st.new_arrays == ["/a"]
        @test st.new_groups == ["/"]
        @test st.updated_chunks["/a"] == [[0]]
        snap1 = commit(s, "one")

        s = writable_session(repo, "main")
        zopen(s, "a")[3:4] = [3.0, 4.0]
        create_group(s, "g")
        snap2 = commit(s, "two")
        d = diff(repo; from_snapshot_id=snap1, to_branch="main")
        @test d.new_groups == ["/g"]
        @test d.updated_chunks["/a"] == [[1]]
        @test isempty(d.deleted_arrays)
        @test_throws ArgumentError diff(repo; from_branch="main", from_tag="t", to_branch="main")

        s = writable_session(repo, "main")
        zopen(s, "a")[1] = 100.0
        @test has_uncommitted_changes(s)
        discard_changes(s)
        @test !has_uncommitted_changes(s)
    end

    @testset "amend, allow_empty, reset_branch" begin
        repo = Repository(MemoryStorage(); mode=:create)
        s = writable_session(repo, "main")
        create_group(s)
        snap1 = commit(s, "first")
        s = writable_session(repo, "main")
        create_group(s, "x")
        snap2 = commit(s, "second")
        s = writable_session(repo, "main")
        create_group(s, "y")
        snap3 = commit(s, "second, amended"; amend=true)
        hist = ancestry(repo)
        @test hist[1].id == snap3
        @test hist[1].message == "second, amended"
        @test hist[2].id == snap1          # snap2 was replaced
        @test !(snap2 in [h.id for h in hist])

        @test_throws ErrorException commit(writable_session(repo, "main"), "nothing")
        snap4 = commit(writable_session(repo, "main"), "empty"; allow_empty=true)
        @test lookup_branch(repo, "main") == snap4

        reset_branch(repo, "main", snap1)
        @test lookup_branch(repo, "main") == snap1
        @test keys(zopen(readonly_session(repo))) == String[]
    end
end
