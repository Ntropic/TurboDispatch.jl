storeddeclaration(::Val)=nothing
function declarations()
    active=Dict{Tuple,Tuple}()
    for method in methods(declaredfamily)
        T=Base.unwrap_unionall(method.sig).parameters[2]
        T isa DataType && T<:Type && length(T.parameters)==1 && T.parameters[1] isa Type || continue
        family(T.parameters[1])
    end
    for method in sort!(collect(methods(storeddeclaration));by=m->m.primary_world)
        sig=Base.unwrap_unionall(method.sig)
        token=sig.parameters[2]
        isconcretetype(token) && token<:Val || continue
        item=Base.invokelatest(storeddeclaration,token())
        item===nothing && continue
        mod,body,binding,roots,f,positions=item
        for i in positions; family(roots[i]); end
        active[(mod,roots,f,positions)]=item
    end
    values(active)
end
function declarefamily!(mod,A;order=nothing)
    f=family(A)
    updatefamilies!(A;hot=order,mod)
    if !isdeclared(A)
        argument=Expr(:(::),Expr(:curly,GlobalRef(Core,:Type),A))
        Core.eval(mod,Expr(:(=),Expr(:call,GlobalRef(@__MODULE__,:declaredfamily),argument),QuoteNode(f)))
    end
    f
end
replacebinding(x,old,new)=x===old ? new : x isa Expr ? Expr(x.head,map(a->replacebinding(a,old,new),x.args)...) : x
function evaluatedispatch!(mod,body,binding)
    statements=filter(x->!(x isa LineNumberNode),body.args)
    registration=first(statements).args[1].args[2]
    prepared=Core.eval(mod,registration)
    for method in statements[2:end-1]
        Core.eval(mod,replacebinding(method,binding,QuoteNode(prepared)))
    end
    prepared
end
function installdispatch!(mod,body,binding,roots,f,positions)
    lock(REGISTRY_LOCK) do
        all(i->haskey(FAMILIES,roots[i]) || isdeclared(roots[i]),positions) || throw(ArgumentError("declare dispatched families with @dispatchfamily first"))
        result=evaluatedispatch!(mod,body,binding)
        token=gensym(:declaration)
        signature=Expr(:call,GlobalRef(@__MODULE__,:storeddeclaration),Expr(:(::),Expr(:curly,GlobalRef(Base,:Val),QuoteNode(token))))
        Core.eval(mod,Expr(:(=),signature,QuoteNode((mod,body,binding,roots,f,positions))))
        result
    end
end
function updatedispatchers!(items=declarations();mod=nothing)
    if mod!==nothing
        lock(REGISTRY_LOCK) do
            for f in values(FAMILIES)
                publishtags!(mod,f)
            end
        end
    end
    for (mod,body,binding,roots,f,positions) in items
        evaluatedispatch!(mod,body,binding)
    end
    nothing
end
function updatefamilies!(roots...;hot=nothing,mod=nothing)
    lock(REGISTRY_LOCK) do
        items=declarations()
        targets=isempty(roots) ? collect(keys(FAMILIES)) : roots
        for A in targets
            haskey(FAMILIES,A) || throw(ArgumentError("declare the family first"))
            discover!(A)
            hot===nothing || setfamilyorder!(family(A),hot)
        end
        empty!(PREPARED)
        updatedispatchers!(items;mod)
    end
    nothing
end
