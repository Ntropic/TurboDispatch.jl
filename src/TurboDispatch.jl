module TurboDispatch
using InteractiveUtils: subtypes
export TaggedArg, tagged, raw, @dispatchfamily, @dispatchadd, @dispatchupdate, @turbodispatch

const REGISTRY_LOCK = ReentrantLock()
const DECLARATIONS = Dict{Any,Vector{Any}}()
const FAMILIES = Dict{Any,Any}()
isdeclared(A::Type)=declaredfamily(A)!==nothing
declaredfamily(::Type)=nothing

"""
    DispatchFamily{A}(members[, order])

**Inputs**

- `A` — the family type.
- `members` — registered type alternatives.
- `order` — optional priority types or groups.

**Outputs**

- A family with stable local tags.

Use [`family`](@ref) to get the shared family.
"""
mutable struct DispatchFamily{A}
    members::Vector{Any}
    order::Tuple
end
DispatchFamily{A}(members) where A = DispatchFamily{A}(members,())
root(::DispatchFamily{A}) where A = A

function setfamilyorder!(f,order)
    priorities=Tuple(order)
    for T in priorities
        T isa Type && any(M->M<:T,f.members) || throw(ArgumentError("priority must name a type or group in this family"))
    end
    f.order=priorities
    f
end
function familyhotgroups(f)
    groups=Tuple[];seen=Int[]
    for T in f.order
        ids=Tuple(i for i in eachindex(f.members) if f.members[i]<:T && !(i in seen))
        isempty(ids) && continue
        push!(groups,ids)
        append!(seen,ids)
    end
    Tuple(groups)
end
function familyorder(f)
    ids=Int[i for group in familyhotgroups(f) for i in group]
    append!(ids,filter(i->!(i in ids),eachindex(f.members)))
    Tuple(ids)
end

function leaves(T)
    T === Union{} && return Any[]
    T isa Union && return reduce(vcat,(leaves(member) for member in Base.uniontypes(T));init=Any[])
    children = subtypes(T)
    isempty(children) && return isabstracttype(T) ? Any[] : Any[T]
    reduce(vcat, (leaves(child) for child in children); init=Any[])
end

function appendmember!(members, T)
    any(M -> T <: M, members) && return members
    any(M -> typeintersect(M, T) !== Union{}, members) &&
        throw(ArgumentError("overlapping family members $T and $members; existing IDs cannot be reassigned"))
    push!(members, T)
end

function publishids!(f::DispatchFamily{A}, start::Int=1) where A
    ccall(:jl_generating_output,Cint,()) != 0 && return
    for id in start:length(f.members)
        M=f.members[id]
        @eval @inline function lookupid(candidate::DispatchFamily{$A}, ::Type{T}) where {T<:$M}
            if $id <= length(candidate.members) && candidate.members[$id] === $M
                return UInt($id)
            end
            scanid(candidate,T)
        end
    end
end

function scanid(f::DispatchFamily{A}, ::Type{T}) where {A,T}
    id = findfirst(M -> T <: M, f.members)
    id === nothing && throw(ArgumentError("$T is not registered in family $A"))
    UInt(id)
end
@inline lookupid(f::DispatchFamily,::Type{T}) where T = scanid(f,T)
"""
    typeid(f, T)

**Inputs**

- `f` — a dispatch family.
- `T` — a registered concrete type.

**Outputs**

- The stable family-local tag as a `UInt`.

Look up the tag assigned to a type.
"""
@inline typeid(f::DispatchFamily{A}, ::Type{T}) where {A,T} = lookupid(f,T)

"""
    family(A; discover=true, order=nothing)

**Inputs**

- `A` — a family type.
- `discover` — whether to scan for concrete subtypes at creation.
- `order` — priority types or groups. Use `()` to clear priorities.

**Outputs**

- The shared `DispatchFamily{A}`.

Get or create a family and refresh prepared dispatchers separately after changing priorities.
"""
function family(A::Type; discover::Bool=true,order=nothing)
    lock(REGISTRY_LOCK) do
        get!(() -> Any[],DECLARATIONS,A)
        declared=declaredfamily(A)
        declared===nothing || (FAMILIES[A]=declared)
        if haskey(FAMILIES,A)
            f = FAMILIES[A]::DispatchFamily{A}
            return order===nothing ? f : setfamilyorder!(f,order)
        end
        members = Any[]
        for (parent, registered) in DECLARATIONS
            A <: parent || continue
            for M in registered
                T = typeintersect(A,M)
                T === Union{} || appendmember!(members,T)
            end
        end
        if discover
            for T in leaves(A); appendmember!(members,T); end
        end
        f = DispatchFamily{A}(members)
        order===nothing || setfamilyorder!(f,order)
        FAMILIES[A] = f
        publishids!(f)
        f
    end
end

rootwrapper(A)=A isa Union ? Union{map(rootwrapper,Base.uniontypes(A))...} : Base.unwrap_unionall(A).name.wrapper

"""
    register!(A, M)

**Inputs**

- `A` — the family type.
- `M` — a type whose concrete members belong to the family.

**Outputs**

- The family type `A`.

Add concrete members while preserving tags, then refresh prepared dispatchers separately.
"""
function register!(A::Type, M::Type)
    wrapper = rootwrapper(A)
    M <: wrapper || throw(ArgumentError("$M is not a subtype of $A"))
    intersection=typeintersect(A,M)
    intersection === Union{} && throw(ArgumentError("$M has no members in family $A"))
    candidates = leaves(intersection)
    lock(REGISTRY_LOCK) do
        registered = get!(DECLARATIONS,A,Any[])
        updates = Pair{Any,Vector{Any}}[]
        for f in values(FAMILIES)
            root(f) <: A || continue
            next = copy(f.members)
            for candidate in candidates
                T = typeintersect(root(f),candidate)
                T === Union{} || appendmember!(next,T)
            end
            next == f.members || push!(updates,f=>next)
        end
        for (f,next) in updates
            start=length(f.members)+1
            f.members=next
            publishids!(f,start)
        end
        for candidate in candidates
            candidate in registered || push!(registered,candidate)
        end
    end
    A
end

"""
    registermember!(M)

**Inputs**

- `M` — the type to register.

**Outputs**

- The registered type `M`.

Add the type to matching declared ancestor and union families.
"""
function registermember!(M::Type)
    M isa Union && (foreach(registermember!,Base.uniontypes(M)); return M)
    lock(REGISTRY_LOCK) do
        declarations()
        targets=collect(keys(DECLARATIONS))
        for A in targets
            M <: rootwrapper(A) && typeintersect(A,M) !== Union{} && register!(A,M)
        end
    end
    M
end

"""
    discover!(A)

**Inputs**

- `A` — the family type.

**Outputs**

- The shared `DispatchFamily{A}`.

Register discoverable concrete subtypes and refresh prepared dispatchers separately.
"""
function discover!(A::Type)
    for T in leaves(A); register!(A,T); end
    family(A)
end

include("arrays.jl")
include("values.jl")
include("prepared.jl")
include("updates.jl")
include("macros.jl")
end
