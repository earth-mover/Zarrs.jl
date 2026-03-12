using Test
using Zarrs

@testset "Groups" begin
    @testset "create group" begin
        mktempdir() do dir
            path = joinpath(dir, "g.zarr")
            g = zgroup(path)
            @test g isa ZarrsGroup
        end
    end

    @testset "group with attributes" begin
        mktempdir() do dir
            path = joinpath(dir, "g.zarr")
            g = zgroup(path; attrs=Dict{String,Any}("title" => "test"))
            attrs = Zarrs.get_attributes(g)
            @test attrs["title"] == "test"
        end
    end

    @testset "group hierarchy" begin
        mktempdir() do dir
            root_path = joinpath(dir, "root.zarr")
            # Create root group
            root = zgroup(root_path)

            # Create a child array within the group's storage
            arr_path = joinpath(root_path, "temperature")
            mkpath(arr_path)
            storage = Zarrs.create_storage(root_path)
            metadata = Zarrs.build_v3_metadata(;
                T=Float32, shape=(50, 50), chunks=(25, 25))
            Zarrs.LibZarrs.zarrs_create_array_rw(storage.ptr, "/temperature", metadata)

            # Open root and navigate
            g = zopen(root_path)
            if g isa ZarrsGroup
                child_keys = keys(g)
                @test "temperature" in child_keys
            end
        end
    end
end
