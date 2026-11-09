# Model-host memory collector

This dependency-free Elixir/OTP release samples the inference service on its own host. It reads counters and model properties; it performs no inference. The benchmark starts it over SSH and saves its NDJSON output throughout each run.

Build from the repository root using Docker:

```sh
docker build -f tools/memory_collector/Dockerfile \
  --output type=local,dest=.local/memory-elixir .
```

The resulting `.local/memory-elixir/memory-collector/` includes Erlang/OTP and the native SCTP library. It is built on Ubuntu 24.04 x86-64 and runs on a model host with Ubuntu 26.04. Copy the whole directory to `/srv/elixir-agent-benchmark/memory-collector` on the model host. Do not replace a release while a benchmark is collecting memory. No system Elixir installation or collector daemon is needed; the benchmark launches one process per collection session.

The benchmark looks for `bin/eab_memory_collector` at that path; `EAB_MEMORY_REMOTE_COLLECTOR` names another ([runner setup](../../README.md#run-memory-on-the-model-host)). The host also needs `ss`, `nvidia-smi`, procfs and a dedicated cgroup v2 model service. The benchmark sends the model server's API key in the collector's request over SSH, and the collector uses it only for that server's own endpoints; a request without one falls back to the key file the request names on the host.

llama.cpp, Strata and Maya's Strata wrapper use the same service/GPU counters. Runtime identification accepts Strata's `/health` service field or the Strata engine reported in `/props` build metadata. The ready identity includes optional `weight_files`: exact GGUF file sizes, including every numbered shard, with basenames only. When the server reports a Strata pack folder, the files are the ones its `tensors.txt` lists, in the folder its `ds4.txt` names. A pack can mix shards of one release with a file from another, such as a separate Engram table, so this need not be a complete shard set; a file holding only the speculative drafter's `mtp.*` tensors is not counted. Missing files, incomplete shard sets and other artifact formats leave this field unknown without stopping memory collection. This is file-size evidence, not a weight checksum or memory requirement. `weight_files.quantized_by` is the maker the first file's GGUF header names (`general.quantized_by`), read from the start of the header only; a file that names no one, or a header that does not parse, leaves it out.

The command `bin/eab_memory_collector eval 'Eab.MemoryCollector.CLI.main()'` accepts one JSON request line on stdin. A streaming request specifies `port`, `key_file`, `artifact`, `context_tokens` and `backend`. It emits a ready identity, samples at a target one-second interval, and a final sample when stdin closes or receives another byte. A request with `"mode":"snapshot"`, `pid`, `port` and `key_file` emits a single observation; see the [snapshot example](../../results-page/README.md#capture-memory-and-future-timings).

Implementation lives in `lib/eab/memory_collector/` so the runner's ExUnit suite tests the same source as this release:

```sh
mix test test/eab/memory_collector_test.exs test/eab/memory_monitor_test.exs --max-cases 2
```

For case preparation and validation, follow [prepared fork sources](../../docs/prepared-fork-sources.md) and the [source audit](../../verification/prepared-forks-2026-10-20/README.md). Runnable cases pin prepared branches in the user’s forks; their source preparation is separate from model-host memory collection.
