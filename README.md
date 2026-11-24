<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Logo/TurboDispatch-dark.svg">
  <img alt="TurboDispatch.jl" src="Logo/TurboDispatch-light.svg" width="364">
</picture>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![Julia 1.13.3+](https://img.shields.io/badge/Julia-1.13.3%2B-9558B2)](Project.toml)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://ntropic.github.io/TurboDispatch.jl/dev/)
[![Tests](https://github.com/Ntropic/TurboDispatch.jl/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Ntropic/TurboDispatch.jl/actions/workflows/ci.yml)

**Binary dispatch trees for faster multiple dispatch in Julia.**

- Declare a group of types to dispatch on. TurboDispatch assigns each concrete type in the group an integer tag.
- Tag values with `tagged`, or let `push!` and `append!` tag them as you add them to a tagged array.
- `@turbodispatch` generates a binary tree that uses the stored argument tags to select an existing Julia method.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/Ntropic/TurboDispatch.jl")
```

## Basic usage

#### Declare a family

Here, `score` accepts four kinds of `Item`. These four concrete types form a *family*. Declare their common supertype with `@dispatchfamily Item` to assign each member a tag.

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

Define the ordinary methods first. At the call site, `@turbodispatch` prepares the tagged overload and calls it. The two `Item` annotations select the tagged arguments, and `shift::Int` passes through.

```julia
score(x::Count, offset::Int) = x.n + offset
score(x::Level, offset::Int) = round(Int, x.value) + offset
score(x::Phasor, offset::Int) = round(Int, abs(x.amplitude)) + offset
score(x::Samples, offset::Int) = sum(x.values) + offset
score(x::Item, y::Item, shift::Int) = score(x, 0) + score(y, 0) + shift

x, y = items[1], items[3]
shift = 2
@turbodispatch result = score(x::Item, y::Item, shift::Int)  # 10
```

## Benchmark summary

Dispatch overhead in **ns/call**.

|  <br>Types per argument | 1 argument<br>Julia → TurboDispatch | 2 arguments<br>Julia → TurboDispatch |
|---:|---:|---:|
| 4  | 14.98 → **0.85 (17.6×)** | 52.13 → **1.69 (30.8×)** |
| 8  | 34.58 → **0.83 (41.7×)** | 63.29 → **2.19 (28.9×)** |
| 16 | 46.05 → **1.07 (43.0×)** | 78.15 → **2.81 (27.8×)** |

Speedup (in parentheses). Timings exclude tagging and without the cost of the actual function, additional timings of the tagging by case and comparison with other dispatch libraries in the docs in [Benchmarks](docs/src/benchmarks.md). Tested on Julia 1.13.3 (Ryzen 9 7950X).

## Author

Michael Schilling (Ntropic)
