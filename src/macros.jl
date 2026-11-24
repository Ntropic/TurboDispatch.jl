function typename(ex)
    ex isa Symbol && return ex
    ex isa Expr || throw(ArgumentError("expected a type declaration"))
    ex.head in (:(<:),:curly) && return typename(ex.args[1])
    throw(ArgumentError("unsupported type declaration"))
end
"""
    @dispatchfamily Family [hot=(CommonType, AbstractGroup)]

**Inputs**

- `Family` — an abstract type, an inline abstract type declaration, or a union.
- `hot` — optional priority types or groups. Use `()` to clear priorities.

**Outputs**

- The declared family type.

Discover concrete members and rebuild prepared overloads while preserving existing tags.
"""
macro dispatchfamily(ex,options...)
    declaration=ex isa Expr && ex.head === :abstract ? ex : nothing
    name=declaration === nothing ? ex : typename(ex.args[1])
    keywords=Any[]
    for option in options
        option isa Expr && option.head===:(=) && option.args[1]===:hot ||
            throw(ArgumentError("use @dispatchfamily Root hot=(CommonType, ...)"))
        isempty(keywords) || throw(ArgumentError("hot may only be specified once"))
        push!(keywords,Expr(:kw,:order,option.args[2]))
    end
    configure=Expr(:call,GlobalRef(@__MODULE__,:declarefamily!),Expr(:parameters,keywords...),QuoteNode(__module__),name)
    esc(quote
        $(declaration === nothing ? nothing : declaration)
        $configure
        $name
    end)
end
"""
    @dispatchadd Type
    @dispatchadd struct Member <: Root ... end

**Inputs**

- `Type` — an existing type or an inline type declaration.

**Outputs**

- `nothing`.

Register the type with all matching declared families and rebuild prepared overloads.
"""
macro dispatchadd(ex)
    declaration=ex isa Expr && ex.head in (:struct,:abstract) ? ex : nothing
    name=declaration===nothing ? ex : typename(ex.args[ex.head === :struct ? 2 : 1])
    register=GlobalRef(@__MODULE__,:registermember!)
    esc(quote
        $(declaration===nothing ? nothing : declaration)
        $register($name)
        $(GlobalRef(@__MODULE__,:updatedispatchers!))(;mod=$(QuoteNode(__module__)))
    end)
end
"""
    @dispatchupdate [Family]

**Inputs**

- `Family` — the family to rescan. Omit it to rescan all families.

**Outputs**

- `nothing`.

Discover new members and rebuild prepared overloads outside concurrent dispatch calls.
"""
macro dispatchupdate(roots...)
    length(roots)<=1 || throw(ArgumentError("use @dispatchupdate or @dispatchupdate Family"))
    Expr(:call,GlobalRef(@__MODULE__,:updatefamilies!),Expr(:parameters,Expr(:kw,:mod,QuoteNode(__module__))),map(esc,roots)...)
end

"""
    @turbodispatch f(::Family, extra::ExtraType)
    @turbodispatch result = f(x::Family, extra::ExtraType)
    @turbodispatch :lazy f(::Family)::ReturnType

**Inputs**

- `f` — the function to prepare.
- `::Family` or `x::Family` — a tagged argument from a declared family.
- `extra::ExtraType` — an ordinary positional argument.
- `:lazy` — optional first-use compilation on Julia 1.13.3 for Linux x86-64, at runtime.
- `::ReturnType` — optional result type assertion.

**Outputs**

- A prepared callable or, in assignment form, the result of the call.

Install overloads that let the function accept tagged arguments.
In assignment form, annotations naming declared families select the tagged arguments. Other arguments pass through. Define the function and declare its families before the caller.
"""
macro turbodispatch(signature,options...)
    if signature isa Expr && signature.head === :(=)
        isempty(options) || throw(ArgumentError("use @turbodispatch result = f(x::Family, extra::ExtraType)"))
        return esc(Base.invokelatest(dispatchcall!,__module__,signature))
    end
    compilation=:eager
    if signature isa QuoteNode
        signature.value===:lazy || throw(ArgumentError("the optional first argument must be :lazy"))
        isempty(options) && throw(ArgumentError("a function signature must follow :lazy"))
        compilation=:lazy
        signature,options=first(options),Base.tail(options)
    end
    return_type=nothing
    if signature isa Expr && signature.head===:(::) && length(signature.args)==2
        signature,return_type=signature.args
    end
    signature isa Expr && signature.head === :call || throw(ArgumentError("use @turbodispatch f(::Root, context::ContextType) with bound root types"))
    f=signature.args[1]
    roots=Any[];arguments=Any[];forwarded=Any[];positions=Int[]
    for arg in signature.args[2:end]
        arg isa Expr && arg.head === :(::) || throw(ArgumentError("each argument must have a type annotation"))
        name=gensym(:argument)
        if length(arg.args)==1
            push!(positions,length(roots)+1)
            A=arg.args[1]
            tagged_type=Expr(:curly,GlobalRef(@__MODULE__,:TaggedArg),A)
            push!(arguments,:($name::$tagged_type))
        else
            A=arg.args[2]
            push!(arguments,:($name::$A))
        end
        push!(roots,A);push!(forwarded,name)
    end
    isempty(positions) && throw(ArgumentError("at least one unnamed ::Root argument is needed to install a tagged overload"))
    registered=gensym(:registered)
    methods=Any[]
    for (axis,pos) in enumerate(positions)
        overload=copy(arguments)
        for (j,p) in enumerate(positions)
            name=forwarded[p]; A=roots[p]
            if j<axis
                overload[p]=:($name::$A)
            elseif j>axis
                tagtype=Expr(:curly,GlobalRef(@__MODULE__,:TaggedArg),A)
                overload[p]=:($name::Union{$A,$tagtype})
            end
        end
        call=Expr(:call,f,overload...)
        method=Expr(:(=),call,Expr(:block,Expr(:call,registered,forwarded...)))
        push!(methods,Expr(:macrocall,GlobalRef(Base,Symbol("@inline")),LineNumberNode(0),method))
    end
    register=GlobalRef(@__MODULE__,:registerfunction!)
    keywords=Any[Expr(:kw,:dispatch_positions,Tuple(positions)),Expr(:kw,:compilation,QuoteNode(compilation))]
    return_type===nothing || push!(keywords,Expr(:kw,:return_type,return_type))
    isempty(options) || throw(ArgumentError("use a leading :lazy and an optional ::ReturnType; hot belongs on @dispatchfamily"))
    registration=Expr(:call,register,Expr(:parameters,keywords...),f,roots...)
    body=quote
        const $registered=$registration
        $(methods...)
        $registered
    end
    esc(:($(GlobalRef(@__MODULE__,:installdispatch!))($(QuoteNode(__module__)),$(QuoteNode(body)),$(QuoteNode(registered)),($(roots...),),$f,$(Tuple(positions)))))
end

function dispatchcall!(mod,assignment)
    result,call=assignment.args
    call isa Expr && call.head === :call ||
        throw(ArgumentError("expected an annotated function call on the right-hand side"))
    f=call.args[1]
    signature=Expr(:call,f)
    direct=Expr(:call,f)
    lock(REGISTRY_LOCK) do
        roots=map(call.args[2:end]) do arg
            arg isa Expr && arg.head === :(::) && length(arg.args)==2 ||
                throw(ArgumentError("each call argument needs a value and a type annotation"))
            value,annotation=arg.args
            root=Core.eval(mod,annotation)
            root isa Type || throw(ArgumentError("argument annotations must name types"))
            push!(signature.args,isdeclared(root) ? Expr(:(::),root) : Expr(:(::),gensym(:ordinary),root))
            push!(direct.args,value)
            root
        end
        positions=Tuple(i for i in eachindex(roots) if isdeclared(roots[i]))
        isempty(positions) && throw(ArgumentError("declare at least one argument family with @dispatchfamily first"))
        callable=Core.eval(mod,f)
        installed=any(item->item[4]==Tuple(roots) && item[5]===callable && item[6]==positions,declarations())
        if !installed
            install=Expr(:macrocall,GlobalRef(@__MODULE__,Symbol("@turbodispatch")),LineNumberNode(0),signature)
            Core.eval(mod,install)
        end
    end
    Expr(:(=),result,direct)
end
