# User Guide

## Family management

### Abstract-type families

Declare the common abstract type to register its concrete subtypes.

```@example items
using TurboDispatch

abstract type Item end
struct Count <: Item; n::Int; end
struct Level <: Item; value::Float64; end
@dispatchfamily Item
nothing # hide
```

#### Register one new subtype

Use `@dispatchadd` to register a specific subtype. Existing entries keep their tags.

```@example items
@dispatchadd struct Phasor <: Item; amplitude::ComplexF64; end
nothing # hide
```

#### Rescan a family

Define `Samples`, then use `@dispatchupdate Item` to discover it.

```@example items
struct Samples <: Item; values::Vector{Int}; end
@dispatchupdate Item
nothing # hide
```

### Union-based families

Declare a union to choose exactly which concrete types belong to the family.

```@example items
const ScalarItem = Union{Count,Level}
@dispatchfamily ScalarItem

scalars = tagged(ScalarItem, [Count(3)])
push!(scalars, Level(5.5))
nothing # hide
```

To include another concrete type, declare a wider union. Use `raw` to recover the values and tag them for the wider family.

```@example items
const NumericItem = Union{ScalarItem,Phasor}
@dispatchfamily NumericItem

numbers = tagged(NumericItem, raw(scalars))
push!(numbers, Phasor(3 + 4im))
@assert raw(numbers) == [Count(3), Level(5.5), Phasor(3 + 4im)] # hide
nothing # hide
```

## Tagging

#### Tag and unwrap one value

Use `tagged` to wrap one value and `raw` to recover it.

```@example items
level = tagged(Item, Level(5.5))
raw(level).value
```

#### Add values to a tagged vector

Use `push!` for one value and `append!` for a batch. Inserting a previously tagged value reuses its tag.

```@example items
items = tagged(Item, [Count(3)])
push!(items, level)
push!(items, Phasor(3 + 4im))
append!(items, [Samples([1, 2, 3])])
nothing # hide
```

#### Unwrap a batch

`raw(items)` returns an array of the original values.

```@example items
payloads = raw(items)
@assert payloads[2] === raw(level) # hide
nothing # hide
```

## Defining and calling functions

#### Dispatch on tagged arguments

Annotate both tagged arguments with their declared family. The macro prepares the overload once per function and signature and leaves a direct call. Here `offset::Int` passes through.

```@example items
shift(x::Count, offset::Int) = x.n + offset
shift(x::Level, offset::Int) = round(Int, x.value) + offset
shift(x::Phasor, offset::Int) = round(Int, abs(x.amplitude)) + offset
shift(x::Samples, offset::Int) = sum(x.values) + offset
@turbodispatch shift(::Item, offset::Int)
nothing # hide
```

```@example items
# Both Item arguments participate in tagged dispatch.
add_offset(a::Item, b::Item, offset::Int) = shift(a, 0) + shift(b, 0) + offset
x, y = items[1], items[3]
offset = 2
@turbodispatch result = add_offset(x::Item, y::Item, offset::Int)

result
```

Once the overload is installed, call it directly.

```@example items
add_offset(x, y, 3)
nothing # hide
```

#### Example dispatch tree for shift

The `Phasor` at `items[3]` carries tag 3. Calling `shift(items[3], 2)` skips the branch for tags 1 and 2, then passes the original `Phasor` and the offset to the matching method. The generated overload follows this tree.

```julia
function shift(x::TaggedArg{Item}, offset::Int)
    value = raw(x)
    if x.tag <= 2
        if x.tag == 1
            shift(value::Count, offset)
        else
            shift(value::Level, offset)
        end
    elseif x.tag == 3
        shift(value::Phasor, offset)
    else
        shift(value::Samples, offset)
    end
end
```

#### Refresh dispatch after changing a method

Update the family after changing a method so existing tagged values use the revised definition.

```@example items
samples = items[4]
before = shift(samples, 2)

shift(x::Samples, offset::Int) = maximum(x.values) + offset
@dispatchupdate Item
(before, shift(samples, 2))
```
