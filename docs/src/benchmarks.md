# Benchmarks

## Dispatch

Estimated dispatch overhead in **ns/call**.

| Args | Types | Julia | TurboDispatch | ManualDispatch | WrappedUnions | LightSumTypes | SumTypes | Unityper | TurboDispatch (80% hot) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 4  | 14.98 | **0.85 (17.6×)** | 7.01 | 1.09 | 0.99 | 1.09 | 3.79 | 0.48 |
| 1 | 8  | 34.58 | **0.83 (41.7×)** | 7.44 | 6.62 | 1.75 | 2.02 | 3.84 | 0.52 |
| 1 | 16 | 46.05 | **1.07 (43.0×)** | 7.35 | 7.41 | 3.34 | 4.60 | 4.12 | 0.58 |
| 2 | 4  | 52.13 | **1.69 (30.8×)** | 8.71 | 10.21 | 67.41 | 2.86 | 6.97 | 1.27 |
| 2 | 8  | 63.29 | **2.19 (28.9×)** | 10.79 | 10.71 | 86.42 | 10.17 | 7.79 | 1.00 |
| 2 | 16 | 78.15 | **2.81 (27.8×)** | 11.23 | 11.83 | 114.51 | 39.31 | 8.87 | 1.08 |

Parentheses show speedup over Julia for uniformly mixed inputs. In the hot run, each argument takes one prioritized type 80% of the time.

## Tagging and insertion

Times in **ns/item**. **Push plain** uses `Any[]`, and **Tag + push** uses `TaggedArg{Input}[]`. **Extra** is the difference.

| Source | Tag via `convert` | `tagged(Input, x)` | Push plain | Tag + push | Extra |
|:---|---:|---:|---:|---:|---:|
| One concrete type | 0.54 | 0.54 | 3.72 | 4.90 | 1.18 |
| Union of 2, stored | 0.73 | 0.73 | 5.24 | 5.46 | 0.22 |
| Union of 2, returned | 2.01 | 2.00 | 6.43 | 7.34 | 0.91 |
| Union of 8, stored | 6.52 | 6.52 | 12.19 | 12.29 | 0.10 |
| Abstract family, 8 types | 1.45 | 1.57 | 0.70 | 3.13 | 2.43 |
| `Any`, 8 types | 2.74 | 38.90 | 0.85 | 3.31 | 2.46 |
| `Any`, one type | 2.20 | 21.69 | 0.86 | 2.88 | 2.02 |
| Already tagged | 0.34 | 0.34 | 5.86 | 1.31 | — |

The returned-union row includes the producer call.

## Reproduce

Measured on a Ryzen 9 7950X with Julia 1.13.3 and one thread.

Run from the checkout root on Linux. Choose an available CPU for `taskset`.

```sh
taskset -c 2 julia --startup-file=no --threads=1 --project=. benchmark/construction.jl
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'
taskset -c 2 julia --startup-file=no --threads=1 --project=benchmark benchmark/run.jl 8 both direct uniform
taskset -c 2 julia --startup-file=no --threads=1 --project=benchmark benchmark/run.jl 8 both binary uniform
```

For dispatch, choose 4, 8 or 16 types and one or both arities (`1`, `2`, `both`). Subtract `direct` from the matching `binary`, `julia`, `manual`, `wrapped`, `light`, `sum` or `unity` time. Use `hot` in place of `uniform` for the prioritized workload.

Comparison packages were ManualDispatch 0.1.0, WrappedUnions 0.3.4, LightSumTypes 5.2.2, SumTypes 0.5.9 and Unityper 0.1.6.
