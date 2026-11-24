# taskset -c 2 julia --project=. benchmark/construction.jl
using TurboDispatch, Random, Statistics

abstract type Input end
const TYPES = ntuple(8) do i
    name=Symbol(:Input,i)
    @eval struct $name <: Input
        value::Int
    end
    Base.invokelatest(getfield,@__MODULE__,name)
end
@dispatchfamily Input

@noinline produce(flag::Bool,n::Int) = flag ? Input1(n) : Input2(n)

@noinline function fillvector!(out::O,input::I) where {O,I}
    empty!(out)
    for value in input
        push!(out,value)
    end
    out
end

@noinline function tagchecksum(tagger::F,input::I) where {F,I}
    checksum=UInt(0)
    for value in input
        entry=tagger(value)::TaggedArg{Input}
        checksum+=entry.tag
    end
    checksum
end

function measuretag(label,tagger::F,input) where F
    family=TurboDispatch.family(Input)
    expected=sum(TurboDispatch.typeid(family,
        typeof(value isa TaggedArg ? raw(value) : value)) for value in input)
    @assert tagchecksum(tagger,input)==expected
    bytes=@allocated tagchecksum(tagger,input)
    samples=Float64[]
    for _ in 1:7
        start=time_ns()
        elapsed=count=0
        while elapsed<20_000_000
            @assert tagchecksum(tagger,input)==expected
            count+=1
            elapsed=time_ns()-start
        end
        push!(samples,elapsed/(count*length(input)))
    end
    elapsed=median(samples)
    println(label," ns/item=",elapsed," bytes/item=",bytes/length(input))
    elapsed
end

function measure(label,run::F,expected) where F
    actual=run()
    family=TurboDispatch.family(Input)
    @assert length(actual)==length(expected)
    for i in eachindex(expected)
        value=actual[i]
        payload=value isa TaggedArg ? raw(value) : value
        original=expected[i] isa TaggedArg ? raw(expected[i]) : expected[i]
        @assert payload===original
        if value isa TaggedArg
            @assert value.tag==TurboDispatch.typeid(family,typeof(original))
        end
    end
    bytes=@allocated run()
    samples=Float64[]
    for _ in 1:7
        start=time_ns()
        elapsed=count=0
        while elapsed<20_000_000
            run()
            count+=1
            elapsed=time_ns()-start
        end
        push!(samples,elapsed/(count*length(expected)))
    end
    elapsed=median(samples)
    println(label," ns/item=",elapsed," bytes/item=",bytes/length(expected))
    elapsed
end

function compare(label,input)
    println("INPUT ",label," eltype=",eltype(input))
    makeplain()=Vector{Any}(input)
    maketagged()=Vector{TaggedArg{Input}}(input)
    maketaggedapi()=tagged(Input,input)
    measure("construct plain",makeplain,input)
    measure("construct tagged",maketagged,input)
    measure("construct tagged API",maketaggedapi,input)
    measurepush(label,input,input)
end

function measurepush(label,input,expected)
    plain=sizehint!(Any[],length(input))
    packed=sizehint!(TaggedArg{Input}[],length(input))
    tag=measuretag("tag",x->convert(TaggedArg{Input},x),input)
    publictag=measuretag("tagged scalar",x->tagged(Input,x),input)
    plainpush=measure("push plain",()->fillvector!(plain,input),expected)
    taggedpush=measure("push tagged",()->fillvector!(packed,input),expected)
    extra=eltype(expected)<:TaggedArg ? nothing : taggedpush-plainpush
    (label,tag,publictag,plainpush,taggedpush,extra)
end

function main()
    println("Julia ",VERSION," CPU ",Sys.CPU_NAME)
    rng=MersenneTwister(42)
    n=8192
    concrete=[TYPES[1](i+1024) for i in 1:n]
    twotypes=Union{TYPES[1],TYPES[2]}[TYPES[rand(rng,1:2)](i+1024) for i in 1:n]
    eighttypes=Union{TYPES...}[TYPES[rand(rng,1:8)](i+1024) for i in 1:n]
    rows=[
        compare("concrete",concrete),
        compare("union2",twotypes),
        compare("union8",eighttypes),
        compare("abstract8",Input[eighttypes...]),
        compare("any8",Any[eighttypes...]),
        compare("any concrete",Any[concrete...]),
        compare("already tagged",tagged(Input,eighttypes)),
    ]
    returned=only(Base.return_types(produce,Tuple{Bool,Int}))
    @assert returned===eltype(twotypes)
    flags=[x isa Input1 for x in twotypes]
    produced=(produce(flags[i],i+1024) for i in eachindex(flags))
    println("INPUT returned union2 inferred=",returned)
    push!(rows,measurepush("returned union2",produced,twotypes))
    println("\nMedian ns/item, preallocated pushes")
    println("| Input | Tag (convert) | tagged(Input, x) | Push plain | Push into tagged vector | Extra |")
    println("|:---|---:|---:|---:|---:|---:|")
    for (label,times...) in rows
        cells=map(t->t===nothing ? "—" : string(round(t;digits=3)),times)
        println("| ",join((label,cells...)," | ")," |")
    end
end

abspath(PROGRAM_FILE)==(@__FILE__) && main()
