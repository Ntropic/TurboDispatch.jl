# Comparison libraries keep their native storage; construction is outside timing.
const ORDER = WORKLOAD===:hot ? vcat(N,collect(1:N-1)) : collect(1:N)
const NAMES = Symbol[nameof(T) for T in TYPES]
const CONSTRUCTORS = Any[]

function installadapter()
    if BACKEND===:manual
        @eval import ManualDispatch
        types=Expr(:tuple,NAMES[ORDER]...)
        @eval begin
            @inline reversepair(y,x)=pair(x,y)
            @inline manualsecond(x,y)=ManualDispatch.@unionsplit($types,reversepair(y,x))::Int
            @noinline function libraryloop(xs)
                total=0
                for x in xs; total+=ManualDispatch.@unionsplit($types,score(x))::Int; end
                total
            end
            @noinline function libraryloop(xs,ys)
                total=0
                @inbounds for i in eachindex(xs,ys)
                    x,y=xs[i],ys[i]
                    total+=ManualDispatch.@unionsplit($types,manualsecond(x,y))::Int
                end
                total
            end
            adapterentries(xs)=Item[xs...]
        end
    elseif BACKEND in (:wrapped,:light)
        if BACKEND===:wrapped
            @eval import WrappedUnions
            uniontype=Expr(:curly,:Union,NAMES...)
            @eval WrappedUnions.@wrapped struct Container <: WrappedUnions.WrappedUnion
                union::$uniontype
            end
            unary=:(WrappedUnions.@unionsplit(score(x)))
            binary=:(WrappedUnions.@unionsplit(pair(x,y)))
        else
            @eval import LightSumTypes
            declaration=Expr(:call,:Container,NAMES[ORDER]...)
            @eval LightSumTypes.@sumtype $declaration
            unary=:(score(LightSumTypes.variant(x)))
            binary=:(pair(LightSumTypes.variant(x),LightSumTypes.variant(y)))
        end
        @eval begin
            adapterentries(xs)=Container[Container(x) for x in xs]
            @noinline function libraryloop(xs)
                total=0
                for x in xs; total+=$unary::Int; end
                total
            end
            @noinline function libraryloop(xs,ys)
                total=0
                @inbounds for i in eachindex(xs,ys)
                    x,y=xs[i],ys[i]
                    total+=$binary::Int
                end
                total
            end
        end
    else
        variants=[Symbol(:Variant_,i) for i in 1:N]
        if BACKEND===:sum
            @eval import SumTypes
            declarations=Expr(:block,[:($(variants[i])(::$(NAMES[i]))) for i in ORDER]...)
            @eval SumTypes.@sum_type Container $declarations
            unary=Expr(:block,[:($(variants[i])(payload) => score(payload)) for i in ORDER]...)
            second=Expr(:block,[:($(variants[i])(payload) => pair(a,payload)) for i in ORDER]...)
            outer=Expr(:block,[:($(variants[i])(payload) => librarysecond(payload,y)) for i in ORDER]...)
            unarycall=:(SumTypes.@cases x $unary)
            secondcall=:(SumTypes.@cases y $second)
            outercall=:(SumTypes.@cases x $outer)
            @eval adapterentries(xs)=Container[CONSTRUCTORS[findfirst(==(typeof(x)),TYPES)](x) for x in xs]
        else
            @eval import Unityper
            declarations=quote; @abstract struct Container end; end
            for i in ORDER
                fields=Expr(:block,[:($(Symbol(:v,k))::Int=0) for k in 1:i]...)
                push!(declarations.args,Expr(:struct,false,Expr(:<:,variants[i],:Container),fields))
            end
            @eval Unityper.@compactify $declarations
            # Preserve each payload's fields using Unityper's scalar-field schema.
            payload(i,x)=Expr(:call,NAMES[i],Expr(:tuple,[:($x.$(Symbol(:v,k))::Int) for k in 1:i]...))
            unary=Expr(:block,[:($(variants[i]) => score($(payload(i,:x)))) for i in ORDER]...)
            second=Expr(:block,[:($(variants[i]) => pair(a,$(payload(i,:y)))) for i in ORDER]...)
            outer=Expr(:block,[:($(variants[i]) => librarysecond($(payload(i,:x)),y)) for i in ORDER]...)
            unarycall=:(Unityper.@compactified x::Container $unary)
            secondcall=:(Unityper.@compactified y::Container $second)
            outercall=:(Unityper.@compactified x::Container $outer)
            @eval function adapterentries(xs)
                map(xs) do x
                    id=findfirst(==(typeof(x)),TYPES)
                    fields=NamedTuple{Tuple(Symbol(:v,k) for k in 1:id)}(x.n)
                    CONSTRUCTORS[id](;fields...)
                end |> xs->Container[xs...]
            end
        end
        append!(CONSTRUCTORS,[Base.invokelatest(getfield,@__MODULE__,v) for v in variants])
        @eval begin
            @inline librarysecond(a,y)=$secondcall
            @noinline function libraryloop(xs)
                total=0
                for x in xs; total+=$unarycall::Int; end
                total
            end
            @noinline function libraryloop(xs,ys)
                total=0
                @inbounds for i in eachindex(xs,ys)
                    x,y=xs[i],ys[i]
                    total+=$outercall::Int
                end
                total
            end
        end
    end
end
