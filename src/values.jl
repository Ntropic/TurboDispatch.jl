@inline @generated function findtag(::Type{Members},x) where Members<:Tuple
    expression=:(UInt(0))
    for (tag,T) in reverse(collect(enumerate(Members.parameters)))
        expression=:(if x isa $T; $(UInt(tag)); else; $expression; end)
    end
    expression
end

@inline function valuetag(members,x)
    tag=findtag(members,x)
    iszero(tag) && throw(ArgumentError("value type is outside the prepared argument family; re-register after extension"))
    tag
end

tagblock(::Type,::Val)=nothing

# Append snapshots so downstream precompilation never overwrites an existing method.
function publishtags!(mod,f::DispatchFamily{A}) where A
    block=Base.invokelatest(tagblock,A,Val(1))
    start=block===nothing ? 1 : fieldcount(last(block))+1
    start>length(f.members) && return
    members=Tuple{f.members...}
    lookup=GlobalRef(@__MODULE__,:tagblock)
    Core.eval(mod,:(function $lookup(::$(Type{A}),::$(Val{start}))
        $(Expr(:meta,:inline))
        next=$lookup($A,$(Val(length(f.members)+1)))
        $something(next,$(QuoteNode((f.members,members))))
    end))
end

@noinline Base.@nospecializeinfer function fallbacktag(f::DispatchFamily{A},@nospecialize(x))::UInt where A
    x isa A || throw(ArgumentError("$(typeof(x)) is not a subtype of $A"))
    typeid(f,typeof(x))
end

@inline function registeredtag(f::DispatchFamily{A},x) where A
    block=tagblock(A,Val(1))
    if block===nothing
        x isa A || return fallbacktag(f,x)
        return typeid(f,typeof(x))::UInt
    elseif first(block)===f.members
        tag=findtag(last(block),x)
        iszero(tag) || return tag
    end
    fallbacktag(f,x)
end

