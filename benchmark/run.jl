# Desktop only: julia --project=benchmark benchmark/run.jl SIZE ARITY METHOD [uniform]
using TurboDispatch, Random, Statistics
const N = isempty(ARGS) ? 4 : parse(Int,ARGS[1])
const ARITIES = length(ARGS)<2 || ARGS[2]=="both" ? (1,2) : (parse(Int,ARGS[2]),)
const BACKEND = length(ARGS)<3 ? :binary : Symbol(ARGS[3])
const WORKLOAD = length(ARGS)<4 ? :uniform : Symbol(ARGS[4])
const COMPILATION = length(ARGS)<5 ? :eager : Symbol(ARGS[5])
@assert N in (4,8,16) && all(n->n in (1,2),ARITIES)
@assert BACKEND in (:direct,:binary,:julia,:manual,:wrapped,:light,:sum,:unity)
@assert WORKLOAD in (:uniform,:hot) && COMPILATION in (:eager,:lazy)
@assert COMPILATION===:eager || BACKEND===:binary

abstract type Item end
const TYPES = ntuple(N) do i
    name=Symbol(:Item,i)
    @eval struct $name <: Item; n::NTuple{$i,Int}; end
    Base.invokelatest(getfield,@__MODULE__,name)
end
@dispatchfamily Item
WORKLOAD===:hot && (@dispatchfamily Item hot=(first(TYPES),))

# Distinct layouts and operation graphs, not a common function plus a type ID.
for (i,T) in enumerate(TYPES)
    kind=mod(i-1,4)
    terms=[kind==0 ? :($(k)*x.n[$k]) :
           kind==1 ? :(x.n[$k] << $(mod(k,7))) :
           kind==2 ? :(x.n[$k]*x.n[$(mod1(k+1,i))]) :
                     :((x.n[$k] ⊻ x.n[$(mod1(k+1,i))]) * $k) for k in 1:i]
    op=kind==1 ? :xor : :+
    body=foldl((a,b)->Expr(:call,op,a,b),terms;init=0)
    @eval @inline score(x::$T)=$body
end
for (i,X) in enumerate(TYPES),(j,Y) in enumerate(TYPES)
    kind=mod(i+j,4)
    body=kind==0 ? :(a*b + (c ⊻ (d << $i)) + (a >>> $j)) :
         kind==1 ? :((a ⊻ b)*(c | 1) + (d >>> $i) - (b << $j)) :
         kind==2 ? :((a+b) ⊻ ((c << $i) | (d >>> $j))) :
                   :(((a-b)*((c >>> $j) | 1)) ⊻ (d << $i))
    @eval @inline function pair(x::$X,y::$Y)
        a=x.n[$i]; b=y.n[$j]; c=x.n[1]; d=y.n[1]
        $body
    end
end

# Independent runtime oracle; it does not invoke the generated methods.
function referencescore(i,data)
    kind=mod(i-1,4); result=0
    for k in 1:i
        if kind==0
            result+=k*data[k]
        elseif kind==1
            result=xor(result,data[k] << mod(k,7))
        elseif kind==2
            result+=data[k]*data[mod1(k+1,i)]
        else
            result+=(data[k] ⊻ data[mod1(k+1,i)])*k
        end
    end
    result
end
function referencepair(i,j,x,y)
    a=x[i]; b=y[j]; c=x[1]; d=y[1]
    kind=mod(i+j,4)
    if kind==0
        a*b + (c ⊻ (d << i)) + (a >>> j)
    elseif kind==1
        (a ⊻ b)*(c | 1) + (d >>> i) - (b << j)
    elseif kind==2
        (a+b) ⊻ ((c << i) | (d >>> j))
    else
        ((a-b)*((c >>> j) | 1)) ⊻ (d << i)
    end
end

@noinline function sweep(r::R,arrays::Tuple) where R
    total=0
    @inbounds for i in eachindex(first(arrays))
        total+=r(map(a->tagged(a,i),arrays)...)::Int
    end
    total
end
@noinline function ordinary(f::F,arrays::Tuple) where F
    total=0
    @inbounds for i in eachindex(first(arrays))
        total+=f(map(a->a[i],arrays)...)::Int
    end
    total
end
function measure(label,f::F,expected,n) where F
    @assert f()==expected
    bytes=@allocated f()
    samples=Float64[]
    for _ in 1:7
        start=time_ns(); elapsed=0; count=0
        while elapsed<20_000_000
            @assert f()==expected
            count+=1; elapsed=time_ns()-start
        end
        push!(samples,elapsed/(count*n))
    end
    println(label," ns/item=",median(samples)," bytes/sweep=",bytes)
    bytes
end
function measuredirect(f::F,arrays::As) where {F,As<:Tuple}
    expected=ordinary(f,arrays)
    @assert (@allocated ordinary(f,arrays))==0
    samples=Float64[]
    for _ in 1:3
        start=time_ns(); elapsed=0; count=0
        while elapsed<1_000_000
            @assert ordinary(f,arrays)==expected
            count+=1; elapsed=time_ns()-start
        end
        push!(samples,elapsed/(count*length(first(arrays))))
    end
    median(samples)
end
function directbaseline(f,inputs,ids,n,expected)
    weighted=0.0; entries=0; checksum=0
    for index in CartesianIndices(ntuple(_->N,n))
        positions=findall(i->all(k->ids[k][i]==index[k],1:n),eachindex(first(inputs)))
        isempty(positions) && continue
        # Concrete vectors give ordinary Julia calls fully known argument types.
        groups=ntuple(k->Vector{TYPES[index[k]]}(inputs[k][positions]),n)
        checksum+=ordinary(f,groups)
        weighted+=length(positions)*measuredirect(f,groups)
        entries+=length(positions)
    end
    @assert entries==length(first(inputs))
    @assert checksum==expected
    println("$n-arg-direct ns/item=",weighted/entries," bytes/sweep=0 grouped=true typed_storage=true")
end
const EXTERNAL = BACKEND in (:manual,:wrapped,:light,:sum,:unity)
function main()
    println("Julia ",VERSION," CPU ",Sys.CPU_NAME," types=",N," backend=",BACKEND," workload=",WORKLOAD," compilation=",COMPILATION)
    @assert length(unique(sizeof.(TYPES)))==N
    rng=MersenneTwister(42)
    ids=ntuple(_->WORKLOAD===:hot ? shuffle!(rng,[fill(1,6554);rand(rng,2:N,1638)]) : rand(rng,1:N,8192),2)
    arrays=map(indices->Any[TYPES[id](ntuple(_->rand(rng,Int),id)) for id in indices],ids)
    for n in ARITIES
        f=n==1 ? score : pair
        inputs=arrays[1:n]
        r=BACKEND===:binary ? f : nothing
        fingerprints=[Int[] for _ in 1:N^n]
        checkrng=MersenneTwister(73)
        for _ in 1:4
            # Shared prefixes compare implementations on matched data, not different random values.
            seeds=ntuple(n) do _
                data=rand(checkrng,Int,N)
                Any[T(Tuple(data[1:i])) for (i,T) in enumerate(TYPES)]
            end
            entries=EXTERNAL ? map(adapterentries,seeds) : nothing
            taggedseeds=BACKEND===:binary ? map(a->tagged(Item,a),seeds) : nothing
            for (slot,index) in enumerate(CartesianIndices(ntuple(_->N,n)))
                wanted=n==1 ? referencescore(index[1],seeds[1][index[1]].n) :
                    referencepair(index[1],index[2],seeds[1][index[1]].n,seeds[2][index[2]].n)
                actual=if EXTERNAL
                    libraryloop(ntuple(k->entries[k][index[k]:index[k]],n)...)
                elseif BACKEND in (:julia,:direct)
                    f(ntuple(k->seeds[k][index[k]],n)...)
                else
                    r(ntuple(k->tagged(taggedseeds[k],index[k]),n)...)
                end
                @assert actual==wanted
                push!(fingerprints[slot],actual)
            end
        end
        @assert length(unique(Tuple.(fingerprints)))==N^n
        println("CHECK arity=$n backend=$BACKEND distinct_layouts=$N combinations=",N^n," distinct_fingerprints=",N^n," probes=4")
        expected=sum(n==1 ? referencescore(ids[1][i],arrays[1][i].n) :
            referencepair(ids[1][i],ids[2][i],arrays[1][i].n,arrays[2][i].n) for i in 1:8192)
        if BACKEND===:direct
            directbaseline(f,inputs,ids,n,expected)
        elseif EXTERNAL
            adapted=map(adapterentries,inputs)
            measure("$n-arg-$BACKEND",()->libraryloop(adapted...),expected,8192)
        elseif BACKEND===:julia
            plain=map(a->Vector{Item}(a),inputs)
            measure("$n-arg-Julia",()->ordinary(f,plain),expected,8192)
        else
            taggedinputs=map(a->tagged(Item,a),inputs)
            bytes=measure("$n-arg-$BACKEND",()->sweep(r,taggedinputs),expected,8192)
            COMPILATION===:eager && @assert bytes==0
        end
    end
end
if EXTERNAL
    include("adapters.jl")
    installadapter()
elseif BACKEND===:binary
    if COMPILATION===:lazy
        @turbodispatch :lazy score(::Item)
        @turbodispatch :lazy pair(::Item,::Item)
    else
        @turbodispatch score(::Item)
        @turbodispatch pair(::Item,::Item)
    end
end
abspath(PROGRAM_FILE)==(@__FILE__) && main()
