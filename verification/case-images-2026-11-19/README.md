# The case images rebuilt with the programs agents reach for, 2026-11-19

[ADR 0024](../../docs/adr/0024-give-case-images-the-programs-agents-reach-for.md) added Python, Perl, `jq` and a few other programs to every case image. This records what was checked when this machine's controller rebuilt its images. No model was run.

## What was done

1. **The package list was tried first** as root in one existing image of each distribution the cases use: Ubuntu 20.04, 22.04 and 24.04, Debian 12 and Alpine 3.22. It installed on all five.
2. **Each case's qualification receipt was saved** from the idle controller before the rebuild.
3. **The controller was rebuilt** from the changed code and **Prepare all cases** was run. It rebuilt all 20 project images, attached Pi to each and qualified every case again. It ended with "Every case is prepared and checked." and no errors.
4. **The receipts were compared.** A receipt holds the grader's four controls: the reference repair, the unchanged source, the incomplete repair and the early exit. For each control it holds the verdict and the named result of every hidden, preservation and submitted test.
5. **Every new image was probed** with [`probe.sh`](../../docs/research/agent-environment-gaps-2026-11-19/probe.sh), and a short script used each new program as the `agent` user in a container started the way the sandbox starts one: no network, no capabilities, `/tmp` as the harness mounts it.

## Result

All 20 cases are valid on the new images. All **16,367 named test outcomes** are the same as before, with the same verdicts, return codes, failure phases and failure types. The added programs changed nothing the grader looks at.

Every image has `python3`, `python`, `perl`, `jq`, `file`, `bc`, `tree`, `xxd`, `curl`, `sqlite3`, `ss`, `netstat`, `nc` and `column`. The nine cases with a PostgreSQL database also have `psql` and `pg_isready`, and the other eleven do not. In all 20 a Python script read and rewrote a file, `perl -0pi` edited one, and the other programs ran.

| Case | Distribution | PostgreSQL client | Named outcomes | Before and after | Image, MB |
|---|---|---|---:|---|---:|
| `absinthe-pr-1176` | Ubuntu 22.04.5 LTS | no | 3,732 | identical | 963 |
| `accent-pr-183` | Ubuntu 20.04.6 LTS | yes | 132 | identical | 946 |
| `ash-pr-3031` | Ubuntu 24.04.4 LTS | no | 800 | identical | 1,235 |
| `beacon-pr-687` | Ubuntu 24.04.4 LTS | yes | 1,191 | identical | 1,376 |
| `cachex-pr-341` | Ubuntu 24.04.4 LTS | no | 401 | identical | 1,067 |
| `guardian-pr-748` | Ubuntu 24.04.4 LTS | no | 1,047 | identical | 1,084 |
| `livebeats-pr-37` | Ubuntu 24.04.5 LTS | yes | 42 | identical | 3,685 |
| `livebook-pr-2219` | Ubuntu 20.04.5 LTS | no | 2,175 | identical | 1,034 |
| `livebook-pr-2527` | Debian GNU/Linux 12 (bookworm) | no | 418 | identical | 1,100 |
| `livebook-pr-2663` | Ubuntu 20.04.6 LTS | no | 423 | identical | 1,114 |
| `livebook-pr-2800` | Ubuntu 22.04.4 LTS | no | 533 | identical | 1,227 |
| `livebook-pr-2822` | Ubuntu 22.04.4 LTS | no | 489 | identical | 1,227 |
| `livebook-pr-3076` | Ubuntu 24.04.2 LTS | no | 107 | identical | 1,222 |
| `operately-pr-1069` | Ubuntu 22.04.5 LTS | yes | 121 | identical | 1,053 |
| `operately-pr-1205` | Debian GNU/Linux 12 (bookworm) | yes | 145 | identical | 1,088 |
| `pinchflat-pr-610` | Debian GNU/Linux 12 (bookworm) | no | 1,551 | identical | 1,112 |
| `plausible-pr-5939` | Alpine Linux v3.22 | yes | 176 | identical | 1,520 |
| `plausible-pr-5956` | Alpine Linux v3.22 | yes | 147 | identical | 1,520 |
| `plausible-pr-6449` | Alpine Linux v3.22 | yes | 188 | identical | 1,510 |
| `vutuv-pr-1759` | Ubuntu 24.04.4 LTS | yes | 2,549 | identical | 1,343 |

The project images grew by 60 to 167 MB each. [`qualification-comparison.json`](qualification-comparison.json) has each case's image identities before and after.

## What was not checked

- **Each project's whole test suite.** The comparison covers the tests the grader runs: each case's acceptance and preservation commands. Tests outside those lists were not run before and after.
- **A model.** Whether agents solve more with these programs is what the new v6 runs will show.

## Repeating it on another controller

Before pulling the change, with the controller idle:

```bash
docker compose exec -T benchmark bin/eab rpc "$(cat verification/case-images-2026-11-19/dump-receipts.exs)" > before.txt
```

After pulling, `docker compose up --build -d` and **Prepare all cases** with the internet on. Then the same command into `after.txt`, and:

```bash
for f in before after; do sed -n 's/.*JSON_START\(.*\)JSON_END.*/\1/p' $f.txt > $f.json; done
python3 verification/case-images-2026-11-19/compare-receipts.py before.json after.json
```

It prints one line per case and ends with how many have identical outcomes.
