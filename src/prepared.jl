const PREPARED = WeakRef[]

function registerfunction!(f, roots::Type...; return_type=:auto, backend=:auto, compilation=:eager, dispatch_positions=Tuple(eachindex(roots)), tag=nothing)
    lock(REGISTRY_LOCK) do
        preparedispatch(f,roots;return_type,backend,compilation,dispatch_positions,output=outputtag(tag))
    end
end

struct CallSignature{T} end
signaturetypes(::Type{CallSignature{T}}) where T=T.parameters
struct DispatchConfig{S,P,M,O,C,R,H,T} end
struct OutputTag{A} end

outputtag(::Nothing)=Nothing
function outputtag(tag::Type)
    isdeclared(tag) || throw(ArgumentError("declare the output family with @dispatchfamily first"))
    OutputTag{tag}
end
function outputtag(spec::Tuple)
    all(T->T isa Type,spec) || throw(ArgumentError("tuple tag entries must be types"))
    Tuple{map(T->isdeclared(T) ? OutputTag{T} : T,spec)...}
end
outputtag(spec)=throw(ArgumentError("tag must specify a declared family or a tuple of types"))

@inline tagresult(::Type{Nothing},value)=value
@inline tagresult(::Type{OutputTag{A}},value) where A=convert(TaggedArg{A},value)
@inline tagfield(::Type{T},value) where T=value::T
@inline tagfield(::Type{OutputTag{A}},value) where A=tagresult(OutputTag{A},value)
@inline @generated function tagresult(::Type{T},value) where T<:Tuple
    fields=[:(tagfield($field,value[$i])) for (i,field) in enumerate(T.parameters)]
    quote
        value isa Tuple && length(value)==$(length(fields)) ||
            throw(ArgumentError("result must be a tuple matching the tag specification"))
        ($(fields...),)
    end
end
mutable struct LazyEntry
    @atomic pointer::Ptr{Cvoid}
    LazyEntry()=new(C_NULL)
end
mutable struct PreparedDispatch{F,Fs,K} <: Function
    const f::F
    const families::Fs
    const entries::Vector{LazyEntry}
    const owners::Vector{Core.CodeInstance}
end
"""
    backend(run)

**Inputs**

- `run` — a prepared dispatcher.

**Outputs**

- `:binary`.

Report the dispatch backend.
"""
backend(::PreparedDispatch)=:binary
preparedorder(::PreparedDispatch{F,Fs,K}) where {F,Fs,K}=K.parameters[4]

function preparedispatch(f,signature;backend=:auto,compilation=:eager,
                          dispatch_positions=Tuple(eachindex(signature)),return_type=:auto,output=Nothing)
    backend in (:auto,:binary) || throw(ArgumentError("backend must be :auto or :binary"))
    compilation in (:eager,:lazy) || throw(ArgumentError("compilation must be :eager or :lazy"))
    positions=Tuple(dispatch_positions)
    !isempty(positions) && issorted(collect(positions)) && allunique(positions) &&
        all(i->i isa Int && 1<=i<=length(signature),positions) || throw(ArgumentError("dispatch_positions must be increasing, unique argument positions"))
    families=map(i->family(signature[i]),positions)
    members=map(f->Tuple(f.members),families)
    all(ms->!isempty(ms) && all(isconcretetype,ms),members) || throw(ArgumentError("dispatched families must contain concrete alternatives"))
    orders=map(familyorder,families)
    hot_groups=map(familyhotgroups,families)
    count=foldl((n,ms)->Base.Checked.checked_mul(n,length(ms)),members;init=1)
    R=return_type===:auto ? Any : return_type
    R isa Type || throw(ArgumentError("return_type must be a type or :auto"))
    if compilation===:lazy
        VERSION==v"1.13.3" && Sys.islinux() && Sys.ARCH===:x86_64 || throw(ArgumentError("native entries require Julia 1.13.3 Linux x86-64"))
        ccall(:jl_generating_output,Cint,())==0 || throw(ArgumentError("create native registrations at runtime, not during package precompilation"))
    end
    filter!(ref->ref.value!==nothing,PREPARED)
    for ref in PREPARED
        r=ref.value
        r===nothing && continue
        typeof(r.f)===typeof(f) && r.f===f || continue
        key=(CallSignature{Tuple{signature...}},positions,Tuple{map(ms->Tuple{ms...},members)...},orders,compilation,R,hot_groups,output)
        Tuple(typeof(r).parameters[3].parameters)==key && return r
    end
    T=PreparedDispatch{typeof(f),typeof(families),DispatchConfig{CallSignature{Tuple{signature...}},positions,Tuple{map(ms->Tuple{ms...},members)...},orders,compilation,R,hot_groups,output}}
    r=T(f,families,[LazyEntry() for _ in 1:(compilation===:lazy ? count : 0)],Core.CodeInstance[])
    if compilation===:eager
        for combination in Iterators.product(members...)
            types=Any[signature...]
            for (axis,pos) in enumerate(positions); types[pos]=combination[axis]; end
            Base.precompile(f,Tuple(types))
        end
    end
    push!(PREPARED,WeakRef(r))
    r
end

struct NativeValueLeaf{F,Types,R,T} end
@inline @generated function nativeleafapply(::NativeValueLeaf{F,Types,R,T},f,args) where {F,Types,R,T}
    values=[:(pointervalue($T,args[$i])) for (i,T) in enumerate(Types.parameters)]
    callable=Base.issingletontype(F) ? QuoteNode(F.instance) : :(f::$F)
    expression=:($callable($(values...))::$R)
    # A boxed native result ABI supports arbitrary user returns without guessing their layout.
    if T!==Nothing
        expression=:(tagresult($T,$expression))
    end
    R===Int && T===Nothing ? expression : :(Base.inferencebarrier($expression))
end
const NATIVE_ARITIES=Set{Int}()
function nativearity!(n)
    n in NATIVE_ARITIES && return
    names=[gensym(:arg) for _ in 1:n]
    signature=[:($name::Ptr{Cvoid}) for name in names]
    @eval @noinline function (leaf::NativeValueLeaf{F,Types,R,T})(f::Any,$(signature...)) where {F,Types,R,T}
        nativeleafapply(leaf,f,($(names...),))
    end
    @eval @noinline function (leaf::NativeValueLeaf{F,Types,R,T})($(signature...)) where {F,Types,R,T}
        nativeleafapply(leaf,F.instance,($(names...),))
    end
    push!(NATIVE_ARITIES,n)
end

@noinline Base.@nospecializeinfer function initializeentry!(r,slot::Int)::Ptr{Cvoid}
    Base.@nospecialize r
    lock(REGISTRY_LOCK) do
        entry=r.entries[slot]
        pointer=@atomic :acquire entry.pointer
        pointer==C_NULL || return pointer
        compileentry!(r,entry,slot)
    end
end
@noinline Base.@nospecializeinfer function compileentry!(r,entry::LazyEntry,slot::Int)::Ptr{Cvoid}
    Base.@nospecialize r
    F=typeof(r).parameters[1]
    S,P,M,O,C,R,H,T=typeof(r).parameters[3].parameters
    types=Any[signaturetypes(S)...]
    index=CartesianIndices(Tuple(length(ms.parameters) for ms in M.parameters))[slot]
    for (axis,pos) in enumerate(P)
        ms=M.parameters[axis].parameters
        types[pos]=ms[index[axis]]
    end
    leaf=NativeValueLeaf{F,Tuple{types...},R,T}()
    nativearity!(length(types))
    sig=Base.issingletontype(F) ? Tuple{typeof(leaf),fill(Ptr{Cvoid},length(types))...} : Tuple{typeof(leaf),Any,fill(Ptr{Cvoid},length(types))...}
    mi=Base.specialize_method(Base._which(sig;world=Base.get_world_counter()))
    ci=Base.Compiler.typeinf_ext_toplevel(Base.Compiler.NativeInterpreter(Base.get_world_counter()),mi,Base.Compiler.SOURCE_MODE_ABI)
    flags=Ref{UInt8}(0);invoke=Ref{Ptr{Cvoid}}(C_NULL);spec=Ref{Ptr{Cvoid}}(C_NULL)
    ccall(:jl_read_codeinst_invoke,Cvoid,(Any,Ref{UInt8},Ref{Ptr{Cvoid}},Ref{Ptr{Cvoid}},Cint),ci,flags,invoke,spec,1)
    abi_return=R===Int && T===Nothing ? Int : Any
    ci.rettype in (abi_return,Union{}) && flags[]&1==1 && spec[]!=C_NULL || error("unsupported native entry ABI")
    push!(r.owners,ci)
    @atomic :release entry.pointer=spec[]
    spec[]
end

@inline @generated function nativevaluecall(pointer::Ptr{Cvoid},f::F,args::NTuple{N,Ptr{Cvoid}},::Type{R}) where {F,N,R}
    singleton=Base.issingletontype(F)
    abi_return=R===Int ? Int : Any
    llvm_return=R===Int ? "i64" : "ptr addrspace(10)"
    function_argument=singleton ? "" : "ptr addrspace(10) %f, "
    arguments=join(["ptr %a$i" for i in 1:N],", ")
    ir="""
        declare ptr @julia.get_pgcstack()
        define $llvm_return @entry(i64 %address, $function_argument$arguments) alwaysinline {
            %gc = call ptr @julia.get_pgcstack()
            %fn = inttoptr i64 %address to ptr
            %result = call swiftcc $llvm_return %fn(ptr swiftself %gc, $function_argument$arguments)
            ret $llvm_return %result
        }
        """
    abi=singleton ? Tuple{UInt,fill(Ptr{Cvoid},N)...} : Tuple{UInt,Any,fill(Ptr{Cvoid},N)...}
    values=[:(args[$i]) for i in 1:N]
    singleton ? :(Base.llvmcall(($ir,"entry"),$abi_return,$abi,UInt(pointer),$(values...))) : :(Base.llvmcall(($ir,"entry"),$abi_return,$abi,UInt(pointer),f,$(values...)))
end

@inline function preparedentry(r::PreparedDispatch{F,Fs,K},slot,args) where {F,Fs,K}
    entry=@inbounds r.entries[slot]
    pointer=@atomic :acquire entry.pointer
    pointer==C_NULL && (pointer=initializeentry!(r,slot))
    R=K.parameters[8]===Nothing ? K.parameters[6] : Any
    GC.@preserve r nativevaluecall(pointer,r.f,args,R)::R
end

@inline function preparedtag(family,::Type{Members},arg)::UInt where Members
    if arg isa TaggedArg
        arg isa TaggedArg{root(family)} || throw(ArgumentError("tagged argument belongs to a different family"))
        tag=getfield(arg,:tag)
        1<=tag<=length(Members.parameters) || throw(ArgumentError("registration is stale; refresh it after extension"))
        return tag
    end
    valuetag(Members,arg)
end

function branchcode(S,P,M,O,C,R,H,T,start,types,slot)
    strides=cumprod([1;[length(ms.parameters) for ms in M.parameters][1:end-1]])
    function emit(axis,types,slot)
        if axis>length(P)
            if C===:lazy; return :(preparedentry(r,$slot,values)); end
            vals=[:(pointervalue($(types[i]),values[$i])) for i in eachindex(types)]
            result=:(r.f($(vals...))::$R)
            return T===Nothing ? result : :(tagresult($T,$result))
        end
        function tagtest(ids)
            sorted=sort(collect(ids));terms=Any[];lo=hi=first(sorted)
            for id in sorted[2:end]
                if id==hi+1;hi=id
                else
                    push!(terms,lo==hi ? :(tags[$axis]==$(UInt(lo))) : :($(UInt(lo))<=tags[$axis]<=$(UInt(hi))))
                    lo=hi=id
                end
            end
            push!(terms,lo==hi ? :(tags[$axis]==$(UInt(lo))) : :($(UInt(lo))<=tags[$axis]<=$(UInt(hi))))
            foldl((a,b)->:($a || $b),terms)
        end
        function tree(ids)
            if length(ids)==1
                id=only(ids);next=copy(types);next[P[axis]]=M.parameters[axis].parameters[id]
                nextslot=slot+(id-1)*strides[axis]
                if axis<length(P) && id!=first(O[axis])
                    arguments=[:(values[$i]) for i in 1:length(signaturetypes(S))]
                    prefix=Tuple(findfirst(==(next[P[i]]),M.parameters[i].parameters) for i in 1:axis)
                    return :(preparedtail(r,Val($(axis+1)),Val($(QuoteNode(prefix))),Val($nextslot),tags,$(arguments...)))
                end
                return emit(axis+1,next,nextslot)
            end
            cut=length(ids)÷2
            left=ids[1:cut];right=ids[cut+1:end]
            test=tagtest(left)
            :(if $test; $(tree(left)); else; $(tree(right)); end)
        end
        hot=H[axis]
        cold=Tuple(id for id in O[axis] if !any(group->id in group,hot))
        body=isempty(cold) ? tree(last(hot)) : tree(cold)
        checked=isempty(cold) ? hot[1:end-1] : hot
        for group in reverse(checked)
            body=:(if $(tagtest(group)); $(tree(group)); else; $body; end)
        end
        body
    end
    emit(start,types,slot)
end

for n in 1:14
    names=[gensym(:value) for _ in 1:n]
    tuple=QuoteNode(Expr(:tuple,names...))
    @eval @inline @generated function preparedtail(r::PreparedDispatch{F,Fs,K},::Val{Axis},::Val{Prefix},::Val{Slot},tags::NTuple{L,UInt},$(names...)) where {F,Fs,K,Axis,Prefix,Slot,L}
        S,P,M,O,C,R,H,T=K.parameters
        types=Any[signaturetypes(S)...]
        for i in eachindex(Prefix);types[P[i]]=M.parameters[i].parameters[Prefix[i]];end
        body=branchcode(S,P,M,O,C,R,H,T,Axis,types,Slot)
        quote
            values=$($tuple)
            $body
        end
    end
end
@inline @generated function preparedtail(r::PreparedDispatch{F,Fs,K},::Val{Axis},::Val{Prefix},::Val{Slot},tags,args...) where {F,Fs,K,Axis,Prefix,Slot}
    S,P,M,O,C,R,H,T=K.parameters
    types=Any[signaturetypes(S)...]
    for i in eachindex(Prefix);types[P[i]]=M.parameters[i].parameters[Prefix[i]];end
    body=branchcode(S,P,M,O,C,R,H,T,Axis,types,Slot)
    quote
        values=args
        $body
    end
end

@inline @generated function pointervalue(::Type{T},p::Ptr{Cvoid}) where T
    isconcretetype(T) && isbitstype(T) ? :(unsafe_load(Ptr{$T}(p))) : :(unsafe_pointer_to_objref(p)::$T)
end

@noinline Base.@nospecializeinfer function boxedinput(x)
    Base.@nospecialize x
    x
end
@inline function payloadobject(r::PreparedDispatch{F,Fs,K},::Val{I},x) where {F,Fs,K,I}
    I in K.parameters[2] && x isa TaggedArg ? getfield(x,:value) : boxedinput(x)
end

@inline @generated function frontendtag(r::PreparedDispatch{F,Fs,K},::Val{I},x)::UInt where {F,Fs,K,I}
    S,P,M=K.parameters
    axis=findfirst(==(I),P)
    axis===nothing && return :(x isa $(signaturetypes(S)[I]) ? UInt(0) : throw(ArgumentError("extra argument does not match its declared type")))
    :(preparedtag(r.families[$axis],$(M.parameters[axis]),x))
end

@inline @generated function pointerkernel(r::PreparedDispatch{F,Fs,K},alltags::NTuple{N,UInt},pointers::NTuple{N,Ptr{Cvoid}}) where {F,Fs,K,N}
    S,P,M,O,C,R,H,T=K.parameters
    N==length(signaturetypes(S)) || return :(throw(ArgumentError("incorrect argument count")))
    tags=[:(alltags[$i]) for i in P]
    body=branchcode(S,P,M,O,C,R,H,T,1,Any[signaturetypes(S)...],1)
    quote
        tags=($(tags...),)
        values=pointers
        $body
    end
end

@inline function (r::PreparedDispatch)(args...)
    length(args)==length(signaturetypes(typeof(r).parameters[3].parameters[1])) || throw(ArgumentError("incorrect argument count"))
    alltags=ntuple(i->frontendtag(r,Val(i),args[i]),length(args))
    # Keep wide-call roots as references even when every payload is an isbits value.
    objects=Any[payloadobject(r,Val(i),x) for (i,x) in enumerate(args)]
    GC.@preserve r objects begin
        pointers=ntuple(i->ccall(:jl_value_ptr,Ptr{Cvoid},(Any,),objects[i]),length(args))
        pointerkernel(r,alltags,pointers)
    end
end
for n in 1:16
    names=[gensym(:arg) for _ in 1:n]
    objects=[gensym(:object) for _ in names]
    bindings=[:($(objects[i])=payloadobject(r,Val($i),$(names[i]))) for i in 1:n]
    tags=[:(frontendtag(r,Val($i),$(names[i]))) for i in 1:n]
    pointers=[:(ccall(:jl_value_ptr,Ptr{Cvoid},(Any,),$(objects[i]))) for i in 1:n]
    @eval @inline function (r::PreparedDispatch{F,Fs,K})($(names...)) where {F,Fs,K}
        $(n)==length(signaturetypes(K.parameters[1])) || throw(ArgumentError("incorrect argument count"))
        alltags=($(tags...),)
        $(bindings...)
        GC.@preserve r $(objects...) begin
            pointerkernel(r,alltags,($(pointers...),))
        end
    end
end
@inline function Core.kwcall(kwargs::NamedTuple,r::PreparedDispatch,args...)
    isempty(kwargs) || throw(ArgumentError("declare extra values as positional arguments; keyword dispatch is not supported by prepared backends"))
    r(args...)
end

"""
    refresh!(run)

**Inputs**

- `run` — a prepared dispatcher.

**Outputs**

- A prepared dispatcher for current membership, priorities, and methods.

Assign the result back to `run` to use the new dispatcher.
"""
function refresh!(r::PreparedDispatch{F,Fs,K}) where {F,Fs,K}
    lock(REGISTRY_LOCK) do
        S,P,M,O,C,R,H,T=K.parameters
        filter!(ref->ref.value!==nothing && ref.value!==r,PREPARED)
        preparedispatch(r.f,Tuple(signaturetypes(S));compilation=C,dispatch_positions=P,return_type=R,output=T)
    end
end
"""
    dispatch(run, args...)

**Inputs**

- `run` — a prepared dispatcher.
- `args` — the positional call arguments.

**Outputs**

- The wrapped function's result.

Invoke the prepared dispatcher as `run(args...)`.
"""
@inline dispatch(r::PreparedDispatch,args...;kwargs...)=r(args...;kwargs...)
