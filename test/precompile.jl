@testset "precompiled declarations remain updateable" begin
    root=dirname(@__DIR__)
    code="""
        using PrecompileFixture, TurboDispatch
        const F = PrecompileFixture
        original = only(F.check())
        @eval PrecompileFixture struct Added <: Item; value::Int; end
        @dispatchadd F.Added
        xs = tagged(F.Item, Any[F.Added(7), F.First(3)])
        @assert xs[1].tag != original.tag && xs[2].tag == original.tag
        @assert F.score(xs[1]) == 7
        @dispatchupdate
        @assert only(F.check()).tag == original.tag
        """
    cmd=`$(Base.julia_cmd()) --startup-file=no --project=$root -e $code`
    paths=join((root,joinpath(@__DIR__,"fixtures"),"@stdlib"),Sys.iswindows() ? ';' : ':')
    @test success(addenv(cmd,"JULIA_LOAD_PATH"=>paths))
end
