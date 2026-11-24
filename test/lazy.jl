module LazyCompilationTests
using Test, TurboDispatch
using TurboDispatch: tagvalue, TaggedArg, family, registerfunction!, refresh!, register!, typeid, backend

@dispatchfamily abstract type Input end
@dispatchadd struct Alpha <: Input; value::Int; end
@dispatchadd struct Beta <: Input; value::String; end
@dispatchfamily abstract type Extra end
@dispatchadd struct Offset <: Extra; value::Float64; end
@dispatchadd struct Count <: Extra; value::Int; end
struct WideResult; value::NTuple{32,Int}; end
mutable struct Collector; values::Vector{Int}; end
(c::Collector)(x::Input)=(push!(c.values,length(string(score(x))));c.values)
score(x::Alpha)=x.value+1
score(x::Beta)=x.value
combine(x::Input,y::Extra)=(score(x),y.value)
concurrentcombine(x::Input,y::Extra,n::Int)=(score(x),y.value,n)
versioned(x::Alpha)=x.value+1
annotated(x::Alpha)=x.value+1
annotated(x::Beta)=length(x.value)
@turbodispatch :lazy annotated(::Input)::Int
mixedmacro(x::Input)=score(x)
@turbodispatch :lazy mixedmacro(::Input)
floatmacro(x::Input)=2.5
@turbodispatch :lazy floatmacro(::Input)::Float64
badmacro(x::Input)=2.5
@turbodispatch :lazy badmacro(::Input)::Int
extramacro(x::Input,n::Int)=length(string(score(x)))+n
@turbodispatch :lazy extramacro(::Input,n::Int)::Int
eagermacro(x::Input)=length(string(score(x)))
@turbodispatch eagermacro(::Input)::Int
unionmacro(x::Input)=score(x)
@turbodispatch :lazy unionmacro(::Input)::Union{Int,String}

@noinline function warmsum(run::R,stored) where R
    result=0
    for _ in 1:256; result+=run(stored); end
    result
end

@testset "lazy arbitrary returns, lifetime, and contracts" begin
    a=Alpha(1024); b=Beta("payload")
    run=registerfunction!(score,Input;compilation=:lazy)
    @test isempty(run.owners)
    @test all(e->(@atomic :acquire e.pointer)==C_NULL,run.entries)
    @test run(a)===1025
    @test length(run.owners)==1
    @test run(tagvalue(b,family(Input)))===b.value
    @test length(run.owners)==2
    @test run(a)===1025
    @test length(run.owners)==2

    values=Any[2048,2.5,Float32(3.5),Int128(1)<<90,UInt8(143),true,nothing,
        missing,:symbol,"result",[1,2],(1,"two"),(data=[3],),Int,identity,
        WideResult(ntuple(identity,32))]
    for expected in values
        f=let value=expected; x->value; end
        r=registerfunction!(f,Input;compilation=:lazy)
        actual=r(a)
        GC.gc(false)
        @test actual===expected
        @test r(b)===expected
    end
    makevector(x)=(v=[score(x),7];GC.gc();v)
    vector_run=registerfunction!(makevector,Input;compilation=:lazy)
    result=vector_run(a)
    GC.gc()
    @test result==[1025,7]

    union_run=registerfunction!(score,Input;compilation=:lazy,return_type=Union{Int,String})
    @test union_run(a)===1025
    @test union_run(b)===b.value
    abstract_run=registerfunction!(x->[score(x)],Input;compilation=:lazy,return_type=AbstractVector)
    @test abstract_run(a)==[1025]
    @test (annotated(a))===1025
    @test (annotated(b))===7
    @test (mixedmacro(b))===b.value
    @test (floatmacro(a))===2.5
    @test (extramacro(b,3))==10
    @test (eagermacro(b))===7
    @test (unionmacro(a))===1025
    @test (unionmacro(b))===b.value
    @test_throws TypeError badmacro(tagged(Input,a))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch annotated(::Input)::Int return_type=Int))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch annotated(x)::Int))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch annotated(::Input) compilation=:lazy))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch :eager annotated(::Input)))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch :lazy))
    @test_throws ArgumentError macroexpand(@__MODULE__,:(@turbodispatch :lazy :lazy annotated(::Input)))

    throws(x)=error("user exception")
    throwing=registerfunction!(throws,Input;compilation=:lazy)
    @test_throws ErrorException throwing(a)
    @test_throws ErrorException throwing(a)
    @test length(throwing.owners)==1
    onlyalpha(x::Alpha)=x.value
    missing_method=registerfunction!(onlyalpha,Input;compilation=:lazy)
    @test_throws MethodError missing_method(b)
    @test missing_method(a)===1024

    typed=registerfunction!(score,Input;compilation=:lazy,return_type=Int)
    stored=tagvalue(a,family(Input))
    @test warmsum(typed,stored)==256*1025
    @test (@allocated warmsum(typed,stored))==0
    for offset in 1:8
        collecting=let n=offset; x->(GC.gc();score(x)+n); end
        cold=registerfunction!(collecting,Input;compilation=:lazy)
        @test cold(tagvalue(Alpha(11),family(Input)))==12+offset
    end
    widesum(xs...)=(GC.gc();sum(x.value for x in xs))
    wide=registerfunction!(widesum,ntuple(_->Alpha,17)...;compilation=:lazy)
    @test wide(ntuple(i->tagvalue(Alpha(i),family(Alpha)),17)...)===153
    collector=Collector(Int[])
    callable=registerfunction!(collector,Input;compilation=:lazy)
    @test callable(a)===collector.values
    GC.gc()
    @test callable(b)===collector.values
    @test collector.values==[4,7]
end

@testset "lazy concurrent first use and cache publication" begin
    xs=(Alpha(11),Beta("beta"));ys=(Offset(2.5),Count(3))
    run=registerfunction!(concurrentcombine,Input,Extra,Int;dispatch_positions=(1,2),compilation=:lazy)
    @test isempty(run.owners)
    tasks=map(1:64) do i
        x=xs[mod1(i,2)];y=ys[mod1(div(i-1,2)+1,2)]
        Threads.@spawn run(tagvalue(x,family(Input)),tagvalue(y,family(Extra)),i)
    end
    for (i,task) in enumerate(tasks)
        x=xs[mod1(i,2)];y=ys[mod1(div(i-1,2)+1,2)]
        @test fetch(task)==(score(x),y.value,i)
    end
    @test length(run.owners)==4
    @test all(e->(@atomic :acquire e.pointer)!=C_NULL,run.entries)
    GC.gc()
    @test run(xs[1],ys[1],7)==(12,2.5,7)
end

@testset "lazy refresh and extension" begin
    a=Alpha(1024)
    old=registerfunction!(versioned,Input;compilation=:lazy)
    @test old(a)===1025
    @eval versioned(x::Alpha)=x.value+2
    fresh=refresh!(old)
    @test fresh!==old
    @test isempty(fresh.owners)
    @test Base.invokelatest(fresh,a)===1026
    @test registerfunction!(versioned,Input;compilation=:lazy)===fresh
    @eval versioned(x::Alpha)=string(x.value)
    changed=refresh!(fresh)
    @test Base.invokelatest(changed,a)=="1024"

    previous=registerfunction!(score,Input;compilation=:lazy)
    @eval struct Gamma <: Input; value::Int; end
    @eval score(x::Gamma)=x.value
    G=Base.invokelatest(getfield,@__MODULE__,:Gamma)
    register!(Input,G)
    g=Base.invokelatest(G,17)
    @test_throws ArgumentError previous(g)
    @test_throws ArgumentError previous(tagvalue(g,family(Input)))
    extended=refresh!(previous)
    @test Base.invokelatest(extended,g)===17
    @test extended(a)===1025
end
end
