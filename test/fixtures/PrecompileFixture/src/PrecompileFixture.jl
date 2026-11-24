module PrecompileFixture
using TurboDispatch
@dispatchfamily abstract type Item end
@dispatchadd struct First <: Item
    value::Int
end
score(x::Item)=x.value
function check()
    v=tagged(Item,Item[First(3)])
    @turbodispatch result = score(v[1]::Item)
    @assert result==3
    v
end
end
