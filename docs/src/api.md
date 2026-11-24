# API reference

## Families and dispatch functions

Use an unnamed family type at each tagged argument position. For example, `@turbodispatch f(::Left, offset::Int, ::Right)` selects a method using both tags and forwards `offset`.

```@docs
@dispatchfamily
@turbodispatch
```

Use `tag=ResultFamily` to wrap a result for another dispatched call. For a tuple result, each position names either a declared family to tag or an ordinary type to check and pass through. Here `ResultFamily` is declared with `@dispatchfamily`, and `describe` returns an integer and a member of that family.

```julia
@turbodispatch describe(::Item) tag=(Int, ResultFamily)
count, tagged_result = describe(tagged_item)
```

## Tagged values

```@docs
tagged
TaggedArg
raw
```

Use `tagged` to wrap a family member and `raw` to recover the original value.

```julia
const NumberPair = Union{Int,Float64}
@dispatchfamily NumberPair
value = tagged(NumberPair, 7)
raw(value)
```

## Updating a family

After adding or changing methods, run `@dispatchupdate Family` outside concurrent dispatch calls. Existing tags stay valid.

```@docs
@dispatchadd
@dispatchupdate
```

Given a declared `Signal` family, use `@dispatchadd` to register `Step` immediately. Define `Ramp` separately and discover it with `@dispatchupdate`.

```julia
@dispatchadd struct Step <: Signal end
struct Ramp <: Signal end
@dispatchupdate Signal
```
