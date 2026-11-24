module PublicAPITests
using TurboDispatch, Test
abstract type Shape end
struct Circle <: Shape; n::Int; end
struct Square <: Shape; n::Int; end
score(x::Circle)=x.n+1
score(x::Square)=2x.n
@dispatchfamily Shape
@turbodispatch score(::Shape)
copyshape(x::Circle)=Square(x.n)
copyshape(x::Square)=Circle(x.n)
shapeinfo(x::Shape,y::Shape)=(x.n+y.n,copyshape(y))
lazycopyshape(x::Shape)=copyshape(x)
@turbodispatch copyshape(::Shape) tag=Shape
@turbodispatch shapeinfo(::Shape,::Shape)::Tuple{Int,Shape} tag=(Int,Shape)
if VERSION==v"1.13.3" && Sys.islinux() && Sys.ARCH===:x86_64
    @turbodispatch :lazy lazycopyshape(::Shape) tag=Shape
end
@testset "tagged returns" begin
    x,y=tagged(Shape,[Circle(3),Square(5)])
    @test (@inferred copyshape(x)) === tagged(Shape,Square(3))
    @test copyshape(raw(x)) === Square(3)
    @test (@inferred shapeinfo(x,y)) === (8,tagged(Shape,Circle(5)))
    @test shapeinfo(y,x) === (8,tagged(Shape,Square(3)))
    if VERSION==v"1.13.3" && Sys.islinux() && Sys.ARCH===:x86_64
        @test lazycopyshape(x) === tagged(Shape,Square(3))
    end
end
shifted(x::Shape,y::Shape,shift::Int)=score(x)+score(y)+shift
function callshifted(x,y,shift)
    @turbodispatch result = shifted(x::Shape,y::Shape,shift::Int)
    result
end
const firstdispatch = which(shifted,Tuple{TaggedArg{Shape},TaggedArg{Shape},Int})
function callshiftedagain(x,y,shift)
    @turbodispatch result = shifted(x::Shape,y::Shape,shift::Int)
    result
end
@testset "call-site dispatch" begin
    x,y=tagged(Shape,[Circle(3),Square(5)])
    @test callshifted(x,y,2)==16
    @test callshiftedagain(raw(x),y,3)==17
    @test shifted(x,y,2)==16
    @test which(shifted,Tuple{TaggedArg{Shape},TaggedArg{Shape},Int})===firstdispatch
end
@testset "four macro API" begin
    xs=tagged(Shape,Shape[Circle(3),Square(5)])
    @test xs isa Vector{TaggedArg{Shape}}
    @test fieldnames(TaggedArg{Shape})==(:value,:tag)
    @test Base.elsize(typeof(xs))==2sizeof(UInt)
    growing=TaggedArg{Shape}[]
    push!(growing,Circle(3))
    append!(growing,[Square(5),Circle(2)])
    @test [score(x) for x in growing]==[4,10,3]
    @test growing[1] isa TaggedArg{Shape}
    @test (@inferred convert(TaggedArg{Shape},Circle(7))) isa TaggedArg{Shape}
    @test (@inferred tagged(Shape,Circle(7))) isa TaggedArg{Shape}
    @test score(xs[1])==4
    @test score(xs[2])==10
    @test score(tagged(Shape,Circle(3)))==4
    @test map(score,xs)==[4,10]
    TurboDispatch.family(Shape)
    @test (@allocated TurboDispatch.family(Shape))==0
    @test size(tagged(Shape,reshape(Shape[Circle(1),Square(2)],1,2)))==(1,2)
    @test_throws ArgumentError tagged(Shape,1)
    @test Set(names(TurboDispatch))==Set([:TurboDispatch,:TaggedArg,:tagged,:raw,Symbol("@dispatchfamily"),Symbol("@dispatchadd"),Symbol("@dispatchupdate"),Symbol("@turbodispatch")])
end
@dispatchfamily Shape hot=(Square,)
@test score(tagged(Shape,Shape[Circle(2),Square(3)])[2])==6
struct Triangle <: Shape; n::Int; end
score(x::Triangle)=3x.n
@test_throws ArgumentError convert(TaggedArg{Shape},Triangle(4))
@dispatchadd Triangle
@test score(tagged(Shape,Shape[Triangle(4)])[1])==12
@testset "tagging before and after a family extension" begin
    values=Shape[Triangle(1),Circle(2),Square(3)]
    expected=[TurboDispatch.typeid(TurboDispatch.family(Shape),typeof(x)) for x in values]
    for input in (values,Any[values...])
        out=TaggedArg{Shape}[]
        append!(out,input)
        @test [x.tag for x in out]==expected
        @test raw(out)==values
        @test convert(TaggedArg{Shape},out[1])===out[1]
        @test_throws ArgumentError push!(out,1)
    end
    other=TurboDispatch.DispatchFamily{Shape}(Any[Triangle,Square,Circle])
    @test TurboDispatch.tagvalue(Circle(1),other).tag==3
end
@dispatchadd struct Extra <: Shape; n::Int; end
score(x::Extra)=4x.n
@dispatchupdate Shape
@test score(tagged(Shape,Shape[Extra(4)])[1])==16
struct Later <: Shape; n::Int; end
score(x::Later)=5x.n
@dispatchupdate
@test score(tagged(Shape,Shape[Later(4)])[1])==20
const U=Union{Circle,Square}
@dispatchfamily U
pair(x::Shape,offset::Int,y::U)=score(x)+offset+score(y)
@turbodispatch pair(::Shape,offset::Int,::U)
@test pair(tagged(Shape,Circle(3)),2,tagged(U,Square(5)))==16
@test pair(tagged(Shape,Shape[Circle(3)])[1],2,tagged(U,U[Square(5)])[1])==16
@test pair(tagged(Shape,Circle(3)),2,Square(5))==16
@test pair(Circle(3),2,tagged(U,Square(5)))==16
@dispatchfamily Shape hot=()
if VERSION==v"1.13.3" && Sys.islinux() && Sys.ARCH===:x86_64
    @turbodispatch :lazy score(::Shape)
else
    @turbodispatch score(::Shape)
end
@test score(tagged(Shape,Shape[Triangle(4)])[1])==12
@dispatchupdate
@test score(tagged(Shape,Shape[Later(2)])[1])==10
abstract type Group <: Shape end
struct FirstGroup <: Group; n::Int; end
score(x::Group)=x.n+10
const OpenUnion=Union{Group,Square}
@dispatchfamily OpenUnion hot=(Group,)
@turbodispatch score(::OpenUnion)
@dispatchfamily Shape hot=(Square,Group)
@test score(tagged(OpenUnion,OpenUnion[FirstGroup(2)])[1])==12
oldtag=tagged(Shape,Square(2)).tag
@dispatchadd struct SecondGroup <: Group; n::Int; end
@test score(tagged(OpenUnion,OpenUnion[SecondGroup(3)])[1])==13
@test score(tagged(Shape,Shape[SecondGroup(3)])[1])==13
@test tagged(Shape,Square(2)).tag==oldtag
@test_throws ArgumentError tagged(U,SecondGroup(3))
@test_throws ArgumentError tagged(Shape,tagged(U,Square(2)))
xs=tagged(Shape,Shape[Circle(1),Square(2)])
xs[1]=xs[2]
push!(xs,tagged(Shape,Circle(3)))
@test score(pop!(xs))==4
@test score(xs[1])==4
@test score(copy(xs)[2])==4
@test score(view(xs,:)[1])==4
@testset "reuse tags across vectors in the same family" begin
    source=tagged(Shape,Shape[Square(3)])
    dest=tagged(Shape,Shape[])
    saved=pop!(source)
    @test raw(saved)===Square(3)
    push!(dest,saved)
    @test raw(dest[1])===raw(saved)
    @test dest[1].tag==saved.tag
    @test score(dest[1])==6
    @test_throws ArgumentError push!(dest,tagged(U,Square(3)))
    @test length(dest)==1
end
mixed(x::Shape)=x isa Circle ? x.n : string(x.n)
if VERSION==v"1.13.3" && Sys.islinux() && Sys.ARCH===:x86_64
    @turbodispatch :lazy mixed(::Shape)
else
    @turbodispatch mixed(::Shape)
end
@test mixed(tagged(Shape,Shape[Circle(3)])[1])===3
@test mixed(tagged(Shape,Shape[Square(4)])[1])=="4"
@test mixed(Circle(2))===2
@test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch score(::Shape) backend=:binary))

keep(::Shape,extra)=extra
@turbodispatch keep(::Shape,extra::Any)
@dispatchfamily abstract type EmptyFamily end
const Metadata=TurboDispatch.DispatchFamily{Int}
@dispatchfamily Metadata
@dispatchfamily Vector{Int}
@testset "tagged extras, empty arrays, and family payloads" begin
    extra=tagged(Shape,Square(2))
    @test keep(tagged(Shape,Circle(1)),extra)===extra
    @test keep(tagged(Shape,Shape[Circle(1)])[1],extra)===extra

    empty=tagged(EmptyFamily,Matrix{EmptyFamily}(undef,0,2))
    other=tagged(Shape,Matrix{Shape}(undef,0,2))
    out=Matrix{Int}(undef,0,2)
    never(args...)=error("empty arrays must not call the function")
    @test size(map(never,empty))==(0,2)
    @test size(map(never,other,empty))==(0,2)
    @test map!(never,out,empty,other)===out
    @test foreach(never,empty)===nothing
    @test foreach(never,other,empty)===nothing
    @test_throws DimensionMismatch map(never,empty,tagged(Shape,Shape[]))
    @test_throws DimensionMismatch map!(never,Int[],empty)

    metadata=TurboDispatch.family(Int)
    @test tagged(Metadata,metadata).value===metadata

    payload=[1,2]
    @test raw(tagged(Vector{Int},payload))===payload
    batch=tagged(Vector{Int},[payload])
    @test raw(only(batch))===payload
    @test tagged(Vector{Int},batch)===batch
end
end
