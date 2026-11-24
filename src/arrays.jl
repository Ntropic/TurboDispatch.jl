"""
    TaggedArg{A}

**Inputs**

- `A` — the declared family type.

**Outputs**

- A value carrying its payload and family-local tag.

Construct a tagged argument with [`tagged`](@ref).
"""
struct TaggedArg{A}
    value::Any
    tag::UInt
    function TaggedArg{A}(value,tag::UInt,::Val{:checked}) where A
        new{A}(value,tag)
    end
end

"""
    raw(value)
    raw(array)

**Inputs**

- `value` — a tagged value, or `array` — an array of tagged values.

**Outputs**

- The original payload or an array of payloads with the same shape.

Unwrap values tagged with [`tagged`](@ref).
"""
@inline raw(value::TaggedArg) = value.value

const TaggedArray = AbstractArray{<:TaggedArg}
raw(array::TaggedArray) = raw.(array)
rootfamily(::AbstractArray{TaggedArg{A}}) where A = A

Base.@propagate_inbounds tagged(v::TaggedArray,indices::Vararg{Union{Integer,CartesianIndex}}) = v[indices...]

@inline function tagvalue(x,f::DispatchFamily{A}) where A
    TaggedArg{A}(boxedinput(x),registeredtag(f,x),Val(:checked))
end

@inline function Base.convert(::Type{TaggedArg{A}},x) where A
    f=declaredfamily(A)
    tagvalue(x,f===nothing ? family(A) : f)
end
Base.convert(::Type{TaggedArg{A}},x::TaggedArg{A}) where A = x
function Base.convert(::Type{TaggedArg{A}},x::TaggedArg) where A
    checkedpayload(family(A),x)
    x::TaggedArg{A}
end

function Base.map(f,v::TaggedArray)
    isempty(v) && isempty(family(rootfamily(v)).members) && return map(f,similar(v,Any))
    registered=registerfunction!(f,rootfamily(v))
    mapregistered(registered,v)
end
function Base.map(f,v::TaggedArray,w::TaggedArray,rest::TaggedArray...)
    arrays=(v,w,rest...)
    all(a->axes(a)==axes(v),arrays) || throw(DimensionMismatch("dispatch arrays must have matching axes"))
    isempty(v) && any(a->isempty(family(rootfamily(a)).members),arrays) &&
        return map(f,map(a->similar(a,Any),arrays)...)
    registered=registerfunction!(f,map(a->rootfamily(a),arrays)...)
    mapregistered(registered,arrays)
end
function Base.foreach(f::F,v::TaggedArray,rest::Vararg{TaggedArray,N}) where {F,N}
    arrays=(v,rest...)
    all(a->axes(a)==axes(v),arrays) || throw(DimensionMismatch("dispatch arrays must have matching axes"))
    isempty(v) && return nothing
    registered=registerfunction!(f,map(a->rootfamily(a),arrays)...)
    foreachregistered(registered,arrays)
end
function Base.map!(f::F,out::AbstractArray,v::TaggedArray,rest::Vararg{TaggedArray,N}) where {F,N}
    arrays=(v,rest...)
    all(a->axes(a)==axes(out),arrays) || throw(DimensionMismatch("dispatch arrays must have matching axes"))
    isempty(out) && return out
    registered=registerfunction!(f,map(a->rootfamily(a),arrays)...)
    mapregistered!(registered,out,arrays)
end

function mapregistered(registered::R,v::V) where {R,V<:TaggedArray}
    map(i->@inbounds(registered(tagged(v,i))),CartesianIndices(v))
end
function mapregistered(registered::R,arrays::As) where {R,As<:Tuple}
    map(i->registered(map(a->@inbounds(tagged(a,i)),arrays)...),CartesianIndices(first(arrays)))
end
function foreachregistered(registered::R,arrays::As) where {R,As<:Tuple}
    @inbounds for i in eachindex(arrays...)
        registered(map(a->tagged(a,i),arrays)...)
    end
    nothing
end
# Unary loops avoid tuple mapping in the per-element hot path.
function foreachregistered(registered::R,arrays::Tuple{V}) where {R,V<:TaggedArray}
    v=only(arrays)
    @inbounds for i in eachindex(v);registered(tagged(v,i));end
    nothing
end
function mapregistered!(registered::R,out::O,arrays::Tuple{V}) where {R,O<:AbstractArray,V<:TaggedArray}
    v=only(arrays)
    @inbounds for i in eachindex(out,v);out[i]=registered(tagged(v,i));end
    out
end
function mapregistered!(registered::R,out::O,arrays::As) where {R,O<:AbstractArray,As<:Tuple}
    @inbounds for i in eachindex(out,arrays...)
        out[i]=registered(map(a->tagged(a,i),arrays)...)
    end
    out
end

@inline function taggingfamily(::Type{A}) where A
    declared=declaredfamily(A)
    declared!==nothing && return declared
    haskey(FAMILIES,A) || throw(ArgumentError("declare the family with @dispatchfamily first"))
    family(A)
end

"""
    tagged(Family, value)
    tagged(Family, array)

**Inputs**

- `Family` — the declared family type.
- `value` — a family member, or `array` — an array of members.

**Outputs**

- A `TaggedArg{Family}` or ordinary array of tagged values.

Attach family-local tags for reuse across dispatch calls.
"""
@inline function tagged(::Type{A},x) where A
    f=taggingfamily(A)
    if x isa TaggedArg
        checkedpayload(f,x)
        return x::TaggedArg{A}
    end
    x isa A && return tagvalue(x,f)
    throw(ArgumentError("value does not belong to the declared family"))
end

function tagged(::Type{A},input::AbstractArray) where A
    f=taggingfamily(A)
    input isa A && return tagvalue(input,f)
    input isa Array{TaggedArg{A}} && return input
    out=Array{TaggedArg{A}}(undef,size(input))
    for (i,value) in enumerate(input)
        if value isa TaggedArg
            checkedpayload(f,value)
            out[i]=value
        else
            out[i]=tagvalue(value,f)
        end
    end
    out
end

@inline function checkedpayload(f::DispatchFamily{A},x::TaggedArg) where A
    x isa TaggedArg{A} || throw(ArgumentError("tagged value belongs to a different family"))
    raw(x)
end
