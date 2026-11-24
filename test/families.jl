using Test, TurboDispatch
using TurboDispatch: TaggedArg, family, discover!, register!, registermember!, registerfunction!, refresh!, dispatch, typeid, backend


@dispatchfamily abstract type Parent{R} end
@dispatchfamily abstract type Item{R} <: Parent{R} end
@dispatchadd struct A{R} <: Item{R}
    value::Int
end
@dispatchadd struct B{R} <: Item{R}
    value::Int
end
const FAM=family(Item{Int})
const PARENT_FAM=family(Parent{Int})
struct Later{R} <: Item{R}
    value::Int
end
score(x::Item)=x.value
same(a::Item,b::Item)=a.value==b.value
heterogeneous(x::A)=x.value
heterogeneous(x::B)=string(x.value)
heterogeneous(x::Later)=x.value
risky(x::Item)=x.value<0 ? error("negative") : x.value
contextual(x::Item,offset::Int;scale=1)=(x.value+offset)*scale
@turbodispatch score(::Item{Int})
@turbodispatch same(::Item{Int},::Item{Int})
@turbodispatch contextual(::Item{Int},offset::Int)

@testset "families, tags, ancestor registration" begin
    @test family(Item{Int}) === FAM
    @test length(FAM.members)==2
    @test length(PARENT_FAM.members)==2
    old=typeid(FAM,A{Int})
    @dispatchadd Later
    @dispatchadd Later
    @test length(FAM.members)==3
    @test length(PARENT_FAM.members)==3
    @test typeid(FAM,A{Int})==old
    @test typeid(FAM,Later{Int})==3
    @dispatchadd Later
    @test length(FAM.members)==3
    @test family(Item{Float64}) !== FAM
    @test_throws ArgumentError register!(Item,String)
end

@testset "inferred and heterogeneous returns" begin
    xs=Array{TaggedArg{Item{Int}}}([A{Int}(1024),B{Int}(2048),Later{Int}(4096)])
    run=registerfunction!(heterogeneous,Item{Int})
    @test backend(run)===:binary
    for (i,wanted) in enumerate((1024,"2048",4096))
        actual=run(xs[i])
        @test typeof(actual)===typeof(wanted) && actual==wanted
        actual=run(tagged(xs,i))
        @test typeof(actual)===typeof(wanted) && actual==wanted
    end
    mixedpair(x,y)=x isa B ? string(x.value+y.value) : x.value+y.value
    pair_run=registerfunction!(mixedpair,Item{Int},Item{Int})
    for i in eachindex(xs),j in eachindex(xs)
        wanted=i==2 ? string(xs[i].value.value+xs[j].value.value) : xs[i].value.value+xs[j].value.value
        actual=pair_run(tagged(xs,i),tagged(xs,j))
        @test typeof(actual)===typeof(wanted) && actual==wanted
    end
end

@testset "ordinary tagged arrays and mutations" begin
    v=TaggedArg{Item{Int}}[]
    push!(v,A{Int}(1),B{Int}(2))
    insert!(v,2,Later{Int}(3))
    @test getproperty.(v,:value)==Item{Int}[A{Int}(1),Later{Int}(3),B{Int}(2)]
    v[1],v[3]=v[3],v[1]
    @test all(entry->typeid(FAM,typeof(entry.value))==entry.tag,v)
    old=copy(v)
    @test_throws ArgumentError push!(v,"bad")
    @test v==old
    @test_throws BoundsError setindex!(v,A{Int}(5),99)
    @test_throws ArgumentError deleteat!(copy(v),[2,1])
    deleteat!(v,2)
    @test pop!(v).value==A{Int}(1)
    @test length(v)==1
    @test [raw(x) for x in view(v,:)]==getproperty.(v,:value)
    @test score.(v)==[2]
    @test size(similar(v,Int,(2,3)))==(2,3)
    empty!(v);@test isempty(v)
    m=Array{TaggedArg{Item{Int}}}([A{Int}(1) B{Int}(2);Later{Int}(3) A{Int}(4)])
    @test size(m)==(2,2)
    @test (score(m[1,2]))==2
    @test score(tagged(m,1,2))==score(tagged(m,CartesianIndex(1,2)))==2
    @test_throws BoundsError tagged(m,1,3)
    @test (same(m[1,1],m[2,2]))==false
end
