```@raw html
<h1 class="package-title">
  <img class="package-logo-light" src="assets/turbodispatch-light.svg" alt="TurboDispatch.jl" width="364">
  <img class="package-logo-dark" src="assets/turbodispatch-dark.svg" alt="TurboDispatch.jl" width="364">
</h1>
```

**Tag mixed values once and reuse their tags for fast Julia multiple dispatch.**

- Call the methods you already use for each concrete type.
- Dispatch on one or more tagged arguments in the same call.
- Tag values automatically as you add them to an ordinary vector.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/Ntropic/TurboDispatch.jl")
```

## Core idea

A **family** assigns a small integer tag to each concrete member type. A **tagged value** stores the payload with its tag. A **dispatch function** branches on those tags to call the matching Julia method.

## Basic usage

#### Declare a family

Define the four types that `shift` will accept, then register their common supertype.

```julia
using TurboDispatch

abstract type Item end
struct Count <: Item; n::Int; end
struct Level <: Item; value::Float64; end
struct Phasor <: Item; amplitude::ComplexF64; end
struct Samples <: Item; values::Vector{Int}; end
@dispatchfamily Item
```

#### Tag a value or a vector

`tagged(Item, x)` returns a `TaggedArg{Item}` for a single item or a `Vector{TaggedArg{Item}}` for a vector of items. `raw` unwraps a tagged value.

```julia
level = tagged(Item, Level(5.5))
raw(level)  # Level(5.5)

items = tagged(Item, [Count(3)])
push!(items, level)  # Reuses the existing tag.
push!(items, Phasor(3 + 4im))
append!(items, [Samples([1, 2, 3])])
```

`push!` tags one value on insertion. `append!` does the same for each value in an iterator.

#### Dispatch Function

Define the ordinary methods first. At the call site, `@turbodispatch` dispatches on the tag of the `Item` argument and passes `offset::Int` through.

```julia
shift(x::Count, offset::Int) = x.n + offset
shift(x::Level, offset::Int) = round(Int, x.value) + offset
shift(x::Phasor, offset::Int) = round(Int, abs(x.amplitude)) + offset
shift(x::Samples, offset::Int) = sum(x.values) + offset

x = items[3]
offset = 2
@turbodispatch result = shift(x::Item, offset::Int)  # 7
```

For more on managing families, tagging values, and calling functions, see the [User Guide](examples.md).
