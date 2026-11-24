# taskset -c 2 julia --project=. benchmark/references.jl
include("construction.jl")

@noinline function fillreferences!(out,input::I) where I
    empty!(out)
    for value in input
        push!(out,convert(TaggedArg{Input},value))
    end
    out
end

function comparereferences(label,input)
    println("INPUT ",label," eltype=",eltype(input))
    inline=sizehint!(TaggedArg{Input}[],length(input))
    references=sizehint!(Any[],length(input))
    for _ in 1:2
        measure("tag and push inline",()->fillvector!(inline,input),input)
        measure("tag and push reference",()->fillreferences!(references,input),input)
    end
    @assert eltype(inline)===TaggedArg{Input}
    @assert eltype(references)===Any
    @assert all(value->value isa TaggedArg{Input},references)
end

function runreferences()
    println("Julia ",VERSION," CPU ",Sys.CPU_NAME)
    rng=MersenneTwister(42)
    n=8192
    concrete=[TYPES[1](i+1024) for i in 1:n]
    twotypes=Union{TYPES[1],TYPES[2]}[TYPES[rand(rng,1:2)](i+1024) for i in 1:n]
    eighttypes=Union{TYPES...}[TYPES[rand(rng,1:8)](i+1024) for i in 1:n]
    comparereferences("concrete",concrete)
    comparereferences("union2",twotypes)
    comparereferences("union8",eighttypes)
    comparereferences("abstract8",Input[eighttypes...])
    comparereferences("any8",Any[eighttypes...])
    comparereferences("any concrete",Any[concrete...])

    input=tagged(Input,eighttypes)
    boxed=Any[input...]
    inline=sizehint!(TaggedArg{Input}[],n)
    references=sizehint!(Any[],n)
    println("INPUT already tagged")
    measure("push existing inline",()->fillvector!(inline,input),input)
    measure("box and push reference",()->fillvector!(references,input),input)
    measure("push existing reference",()->fillvector!(references,boxed),boxed)
    GC.@preserve boxed references begin
        @assert unsafe_load(pointer(boxed))===unsafe_load(pointer(references))
    end
end

abspath(PROGRAM_FILE)==(@__FILE__) && runreferences()
