using Test
using Zarrs

@testset "Consolidated Metadata" begin
    @testset "_keys_from_consolidated" begin
        metadata = Dict(
            ".zgroup" => Dict("zarr_format" => 2),
            ".zattrs" => Dict(),
            "temperature/.zarray" => Dict("zarr_format" => 2),
            "temperature/.zattrs" => Dict("units" => "K"),
            "pressure/.zarray" => Dict("zarr_format" => 2),
            "pressure/.zattrs" => Dict(),
            "nested/.zgroup" => Dict("zarr_format" => 2),
            "nested/.zattrs" => Dict(),
            "nested/data/.zarray" => Dict("zarr_format" => 2),
            "nested/data/.zattrs" => Dict(),
        )

        @testset "root group children" begin
            children = Zarrs._keys_from_consolidated(metadata, "/")
            @test children == ["nested", "pressure", "temperature"]
        end

        @testset "nested group children" begin
            children = Zarrs._keys_from_consolidated(metadata, "/nested")
            @test children == ["data"]
        end

        @testset "deduplication" begin
            # temperature has both .zarray and .zattrs — should appear once
            children = Zarrs._keys_from_consolidated(metadata, "/")
            @test count(==("temperature"), children) == 1
        end

        @testset "filters metadata files" begin
            children = Zarrs._keys_from_consolidated(metadata, "/")
            @test ".zgroup" ∉ children
            @test ".zattrs" ∉ children
            @test ".zarray" ∉ children
        end

        @testset "leaf group returns empty" begin
            children = Zarrs._keys_from_consolidated(metadata, "/pressure")
            @test isempty(children)
        end
    end

    @testset "_try_load_consolidated!" begin
        fixture_path = joinpath(@__DIR__, "fixtures", "consolidated_v2")
        storage = Zarrs.create_storage(fixture_path)

        @test storage.consolidated === missing

        Zarrs._try_load_consolidated!(storage)

        @test storage.consolidated isa Dict
        @test haskey(storage.consolidated, "temperature/.zarray")
        @test haskey(storage.consolidated, "nested/.zgroup")
    end

    @testset "_try_load_consolidated! with no .zmetadata" begin
        mktempdir() do dir
            # Create a bare V2 group with no .zmetadata
            write(joinpath(dir, ".zgroup"), """{"zarr_format": 2}""")
            write(joinpath(dir, ".zattrs"), "{}")
            storage = Zarrs.create_storage(dir)

            Zarrs._try_load_consolidated!(storage)

            @test storage.consolidated === nothing
        end
    end

    @testset "keys() uses consolidated metadata" begin
        fixture_path = joinpath(@__DIR__, "fixtures", "consolidated_v2")
        g = zopen(fixture_path)

        @test g isa ZarrsGroup
        # Consolidated metadata should have been loaded
        @test g.storage.consolidated isa Dict

        children = keys(g)
        @test "temperature" in children
        @test "pressure" in children
        @test "nested" in children
        @test length(children) == 3
    end
end
