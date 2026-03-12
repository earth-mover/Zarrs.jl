using Test
using Zarrs: parse_url_pipeline, has_adapter, get_adapter, parse_icechunk_authority,
             RootScheme, AdapterScheme, URLPipeline

@testset "URL Pipeline Parser" begin

    @testset "Filesystem paths" begin
        p = parse_url_pipeline("/tmp/data.zarr")
        @test p.root.scheme === :file
        @test p.root.prefix == "/tmp/data.zarr"
        @test p.root.bucket == ""
        @test isempty(p.adapters)

        p2 = parse_url_pipeline("file:///tmp/data.zarr")
        @test p2.root.scheme === :file
        @test p2.root.prefix == "/tmp/data.zarr"
    end

    @testset "S3 URLs" begin
        p = parse_url_pipeline("s3://my-bucket/path/to/data")
        @test p.root.scheme === :s3
        @test p.root.bucket == "my-bucket"
        @test p.root.prefix == "path/to/data"
        @test isempty(p.adapters)

        # Bucket only
        p2 = parse_url_pipeline("s3://my-bucket")
        @test p2.root.bucket == "my-bucket"
        @test p2.root.prefix == ""

        # Trailing slash
        p3 = parse_url_pipeline("s3://my-bucket/prefix/")
        @test p3.root.bucket == "my-bucket"
        @test p3.root.prefix == "prefix"
    end

    @testset "GCS URLs" begin
        p = parse_url_pipeline("gs://my-bucket/data")
        @test p.root.scheme === :gs
        @test p.root.bucket == "my-bucket"
        @test p.root.prefix == "data"
    end

    @testset "HTTP/HTTPS URLs" begin
        p = parse_url_pipeline("https://example.com/data.zarr")
        @test p.root.scheme === :https
        @test p.root.prefix == "https://example.com/data.zarr"

        p2 = parse_url_pipeline("http://localhost:8080/data")
        @test p2.root.scheme === :http
        @test p2.root.prefix == "http://localhost:8080/data"
    end

    @testset "Memory scheme" begin
        p = parse_url_pipeline("memory:")
        @test p.root.scheme === :memory
    end

    @testset "Query parameters" begin
        p = parse_url_pipeline("s3://bucket/prefix?region=us-west-2&anonymous=true")
        @test p.root.query["region"] == "us-west-2"
        @test p.root.query["anonymous"] == "true"
    end

    @testset "Icechunk adapter" begin
        # Basic pipe syntax (no spaces per URL pipeline spec)
        p = parse_url_pipeline("s3://bucket/repo|icechunk://branch.main/")
        @test p.root.scheme === :s3
        @test p.root.bucket == "bucket"
        @test p.root.prefix == "repo"
        @test has_adapter(p, :icechunk)
        adapter = get_adapter(p, :icechunk)
        @test adapter.authority == "branch.main"

        # Tag
        p2 = parse_url_pipeline("s3://bucket/repo|icechunk://tag.v1/")
        adapter2 = get_adapter(p2, :icechunk)
        @test adapter2.authority == "tag.v1"

        # Bare icechunk:
        p3 = parse_url_pipeline("memory:|icechunk:")
        @test p3.root.scheme === :memory
        @test has_adapter(p3, :icechunk)
        adapter3 = get_adapter(p3, :icechunk)
        @test adapter3.authority == ""

        # GCS with icechunk
        p4 = parse_url_pipeline("gs://bucket/repo|icechunk://branch.dev/")
        @test p4.root.scheme === :gs
        adapter4 = get_adapter(p4, :icechunk)
        @test adapter4.authority == "branch.dev"

        # Local filesystem with icechunk
        p5 = parse_url_pipeline("/tmp/ic-store|icechunk://branch.main/")
        @test p5.root.scheme === :file
        @test p5.root.prefix == "/tmp/ic-store"
        @test has_adapter(p5, :icechunk)
    end

    @testset "parse_icechunk_authority" begin
        @test parse_icechunk_authority("branch.main") == (:branch, "main")
        @test parse_icechunk_authority("branch.feature-x") == (:branch, "feature-x")
        @test parse_icechunk_authority("tag.v1") == (:tag, "v1")
        @test parse_icechunk_authority("tag.release-2024") == (:tag, "release-2024")
        @test parse_icechunk_authority("") == (:branch, "main")  # default

        @test_throws ErrorException parse_icechunk_authority("invalid")
    end

    @testset "has_adapter / get_adapter" begin
        p = parse_url_pipeline("s3://b/p")
        @test !has_adapter(p, :icechunk)
        @test_throws ErrorException get_adapter(p, :icechunk)
    end

    @testset "Unsupported adapter" begin
        @test_throws ErrorException parse_url_pipeline("s3://b/p|unknown:")
    end

    @testset "Whitespace tolerance" begin
        # Parser should still handle spaces around | gracefully
        p = parse_url_pipeline("  s3://bucket/prefix  |  icechunk://branch.main/  ")
        @test p.root.scheme === :s3
        @test has_adapter(p, :icechunk)
    end
end
