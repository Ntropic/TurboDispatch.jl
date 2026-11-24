using TurboDispatch, Test
using TurboDispatch: tagvalue, TaggedArg, family, discover!, register!, registermember!, registerfunction!, refresh!, dispatch, typeid, backend

@dispatchfamily abstract type InterfaceRoot end
@dispatchadd struct IA <: InterfaceRoot; n::Int; end
@dispatchadd struct IB <: InterfaceRoot; n::Int; end
struct IC; n::Int; end
const IU=Union{IB,IC}
struct Context; offset::Int; end
abstract type AbstractContext end
struct DynamicContext <: AbstractContext; offset::Int; end
mutable struct ManagedPayload
    items::Vector{Int}
end
managedscore(x::ManagedPayload)=(GC.gc();sum(x.items))
unary(x)=x.n+1
pair(x,y)=10x.n+y.n
@noinline function interfacesum(r::R,xs) where R
    result=0
    for x in xs;result+=r(x);end
    result
end
@noinline function interfacepairs(r::R,xs) where R
    total=0
    for i in eachindex(xs);total+=r(tagged(xs,i),tagged(xs,i));end
    total
end
function bulkallocations(r::R,out,arrays::As) where {R,As<:Tuple}
    TurboDispatch.mapregistered!(r,out,arrays)
    @allocated TurboDispatch.mapregistered!(r,out,arrays)
end
triple(x,c,y,z)=100x.n+10y.n+z.n+c.offset
@dispatchfamily InterfaceRoot hot=(IB,)
@dispatchfamily IU hot=(IC,)
@turbodispatch pair(::InterfaceRoot,::IU)
struct ILater <: InterfaceRoot; n::Int; end
@testset failfast=true "complete registration interface" begin
    for b in (:binary,:auto),c in (:eager,:lazy)
        u=registerfunction!(unary,InterfaceRoot;backend=b,compilation=c,return_type=Int)
        r=registerfunction!(triple,InterfaceRoot,Context,IU,InterfaceRoot;dispatch_positions=(1,3,4),backend=b,compilation=c,return_type=Int)
        @test r===registerfunction!(triple,InterfaceRoot,Context,IU,InterfaceRoot;dispatch_positions=(1,3,4),backend=b,compilation=c,return_type=Int)
        c===:lazy && b!==:auto && @test isempty(r.owners)
        for x in (IA(2),IB(3)),y in (IB(4),IC(5)),z in (IA(6),IB(7))
            @test u(x)==x.n+1
            @test r(x,Context(8),y,z)==100x.n+10y.n+z.n+8
            @test r(tagvalue(x,family(InterfaceRoot)),Context(8),tagvalue(y,family(IU)),tagvalue(z,family(InterfaceRoot)))==100x.n+10y.n+z.n+8
        end
        @test_throws ArgumentError r(IA(1),0,IB(1),IA(1))
        @test_throws ArgumentError u(IC(1))
        @test_throws ArgumentError u()
        @test r.families[1]===r.families[3]
        @test refresh!(r)(IA(2),Context(8),IC(5),IB(7))==265
    end
    @test (pair(IA(2),IC(5)))==25
    inputs=InterfaceRoot[IA(1024),IB(2048)]
    for c in (:eager,:lazy)
        union_run=registerfunction!(unary,IU;compilation=c,return_type=Int)
        @test union_run(IC(1024))==1025
        r=registerfunction!(unary,InterfaceRoot;compilation=c,return_type=Int)
        @test interfacesum(r,inputs)==3074
        @test (@allocated interfacesum(r,inputs))==0
    end
    ids=map(T->typeid(family(InterfaceRoot),T),(IA,IB))
    old=registerfunction!(unary,InterfaceRoot)
    @test TurboDispatch.preparedorder(old)==((2,1),)
    @test family(InterfaceRoot).order==(IB,)
    @dispatchfamily InterfaceRoot hot=(IA,)
    fresh=registerfunction!(unary,InterfaceRoot)
    other=registerfunction!(pair,InterfaceRoot,IU)
    repeated=registerfunction!((x,y)->x.n+y.n,InterfaceRoot,InterfaceRoot)
    @test fresh!==old
    @test TurboDispatch.preparedorder(fresh)[1]==TurboDispatch.preparedorder(other)[1]==(1,2,3)
    @test TurboDispatch.preparedorder(repeated)==((1,2,3),(1,2,3))
    @test TurboDispatch.preparedorder(old)==((2,1),)
    @test TurboDispatch.preparedorder(refresh!(old))==((1,2,3),)
    @test map(T->typeid(family(InterfaceRoot),T),(IA,IB))==ids
    @test_throws MethodError registerfunction!(unary,InterfaceRoot;order=((IB,),))
    @test_throws ArgumentError family(InterfaceRoot;order=(String,))
    @test family(InterfaceRoot).order==(IA,)
    @test_throws ArgumentError (@dispatchfamily InterfaceRoot hot=(String,))
    @test family(InterfaceRoot).order==(IA,)
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@dispatchfamily InterfaceRoot backend=:flat))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@dispatchfamily InterfaceRoot hot=(IA,) order=(IB,)))
    for c in (:eager,:lazy)
        r=registerfunction!(triple,InterfaceRoot,AbstractContext,IU,InterfaceRoot;dispatch_positions=(1,3,4),compilation=c,return_type=Int)
        @test r(IA(2),DynamicContext(8),IC(5),IB(7))==265
    end
    @test backend(registerfunction!(unary,InterfaceRoot))===:binary
    @test backend(registerfunction!(pair,InterfaceRoot,IU;return_type=Int))===:binary
    @test backend(registerfunction!(pair,InterfaceRoot,IU;return_type=Any))===:binary
    @test_throws ArgumentError registerfunction!(unary,InterfaceRoot;backend=:subtype)
    @test_throws ArgumentError registerfunction!(unary,InterfaceRoot;backend=:flat)
    @test_throws ArgumentError registerfunction!(unary,InterfaceRoot;backend=:matrix)
    @test_throws ArgumentError family(InterfaceRoot;order=(String,))
    @test registerfunction!(unary,InterfaceRoot;compilation=:lazy)(IA(1024))==1025
    @test_throws ArgumentError registerfunction!(pair,InterfaceRoot,IU;dispatch_positions=(2,1))
    @test_throws ArgumentError registerfunction!(unary,InterfaceRoot)(IA(1);bad=2)
    captured=let offset=[7]; x->(GC.gc();x.n+offset[1]); end
    for c in (:eager,:lazy)
        r=registerfunction!(captured,InterfaceRoot;compilation=c,return_type=Int)
        @test r(IA(3))==10
    end
    risky(x)=x.n<0 ? error("negative") : x.n
    r=registerfunction!(risky,InterfaceRoot;compilation=:lazy,return_type=Int)
    @test r(IA(1))==1
    @test_throws ErrorException r(IA(-1))
    @test length(r.owners)==1
    u=registerfunction!(unary,InterfaceRoot)
    register!(InterfaceRoot,ILater)
    @test u(ILater(8))==9
    @test refresh!(u)(ILater(8))==9
    for c in (:eager,:lazy)
        asymmetric=registerfunction!(triple,InterfaceRoot,Context,IU,IA;
            dispatch_positions=(1,3,4),compilation=c,return_type=Int)
        for x in (IA(2),IB(3),ILater(4)),y in (IB(5),IC(6))
            @test asymmetric(tagvalue(x,family(InterfaceRoot)),Context(8),tagvalue(y,family(IU)),tagvalue(IA(7),family(IA)))==100x.n+10y.n+15
        end
        @test_throws ArgumentError asymmetric(tagvalue(IC(1),family(IU)),Context(8),IB(2),IA(3))
    end
    @test backend(registerfunction!((a,b,c,d)->1,InterfaceRoot,InterfaceRoot,InterfaceRoot,InterfaceRoot))===:binary
    values=Any[IA(1),IB(2)]
    array=Array{TaggedArg{InterfaceRoot}}(values)
    @test_throws BoundsError tagged(array,0)
    @test_throws BoundsError tagged(array,3)
    @test_throws BoundsError tagged(array,CartesianIndex(3))
    union_array=Array{TaggedArg{Union{IA,IB}}}(values)
    @test fieldtype(eltype(array),:value)===Any
    @test Base.allocatedinline(eltype(array))
    @test fieldtype(typeof(tagged(union_array,1)),:value)===Any
    @test getproperty.(union_array,:value)==values
    for c in (:eager,:lazy)
        rr=registerfunction!(pair,InterfaceRoot,IU;compilation=c,return_type=Int)
        @test rr(tagged(array,1),tagvalue(IC(8),family(IU)))==18
        ur=registerfunction!(unary,Union{IA,IB};compilation=c,return_type=Int)
        @test ur(tagged(union_array,2))==3
        for A in (InterfaceRoot,Union{IA,IB})
            large=Array{TaggedArg{A}}(Any[IA(1024),IB(2048)])
            pr=registerfunction!(pair,A,A;compilation=c,return_type=Int)
            @test interfacepairs(pr,large)==33792
            @test (@allocated interfacepairs(pr,large))==0
        end
    end
    @test_throws BoundsError array[0]
    @test_throws BoundsError array[3]
    @test (@inbounds array[1]).value === array[1].value
    @test map(unary,array)==[2,3]
    add3(x,y,z)=x.n+y.n+z.n
    @test map(add3,array,array,array)==[3,6]
    out=zeros(Int,2)
    @test map!(add3,out,array,array,array)==[3,6]
    total=Ref(0)
    foreach((x,y,z)->(total[]+=x.n+y.n+z.n),array,array,array)
    @test total[]==9
    for n in (2,3)
        inputs=ntuple(_->array,n)
        f=n==2 ? pair : add3
        prepared=registerfunction!(f,ntuple(_->InterfaceRoot,n)...)
        TurboDispatch.mapregistered!(prepared,out,inputs)
        @test bulkallocations(prepared,out,inputs)==0
        matrix=Array{TaggedArg{InterfaceRoot}}(reshape(values,1,2))
        matrices=ntuple(_->matrix,n)
        expected=n==2 ? [11 22] : [3 6]
        @test map(f,matrices...)==expected
        @test map!(f,zeros(Int,1,2),matrices...)==expected
        total[]=0
        foreach((xs...)->(total[]+=sum(x.n for x in xs)),matrices...)
        @test total[]==3n
        unchanged=fill(-1,3)
        @test_throws DimensionMismatch map!(f,unchanged,inputs...)
        @test unchanged==fill(-1,3)
    end
    @test_throws DimensionMismatch map(add3,array,array,TaggedArg{InterfaceRoot}[])
    summany(xs...)=sum(x.n for x in xs)
    many=registerfunction!(summany,ntuple(_->IA,17)...;return_type=Int)
    @test many(ntuple(i->tagvalue(IA(i),family(IA)),17)...)==153
    gcmany(xs...)=(GC.gc();sum(x.n for x in xs))
    for c in (:eager,:lazy)
        wide=registerfunction!(gcmany,ntuple(_->IA,17)...;compilation=c,return_type=Int)
        @test wide(ntuple(i->tagvalue(IA(i),family(IA)),17)...)==153
    end
    extra=tagged(InterfaceRoot,IA(9))
    keepextra(extra,args...)=extra
    for n in (2,17), c in (:eager,:lazy)
        fillers=ntuple(_->nothing,n-2)
        signature=(typeof(extra),map(typeof,fillers)...,InterfaceRoot)
        run=registerfunction!(keepextra,signature...;dispatch_positions=(n,),compilation=c)
        @test run(extra,fillers...,array[1])===extra
    end
    @test_throws OverflowError registerfunction!(summany,ntuple(_->InterfaceRoot,64)...;compilation=:lazy,return_type=Int)
    payload=ManagedPayload([1024,2048])
    stored=tagvalue(payload,family(ManagedPayload))
    @test stored.value===payload
    references=Any[payload]
    reference_array=Array{TaggedArg{ManagedPayload}}(references)
    reference_union=Array{TaggedArg{Union{ManagedPayload,IA}}}(references)
    @test reference_array[1].value===reference_union[1].value===payload
    for c in (:eager,:lazy)
        resource_run=registerfunction!(managedscore,ManagedPayload;compilation=c,return_type=Int)
        @test resource_run(stored)==3072
        payload.items[1]=4096
        @test resource_run(stored)==6144
        @test resource_run(tagvalue(ManagedPayload([8192]),family(ManagedPayload)))==8192
        payload.items[1]=1024
    end
end
