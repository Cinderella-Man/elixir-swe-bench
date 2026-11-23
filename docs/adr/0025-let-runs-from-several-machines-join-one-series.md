# Let runs from several machines join one series

Two controllers make runs now: this repository's machine and a second one that serves other models. Each one started a run at seed 101, and **Runs in a row** went on with 102 and 103. A series took one run per seed ([ADR 0011](0011-publish-three-run-series.md)), so two machines making runs of one model picked the same seeds. On 2026-11-22 the second controller made another seed-101 run of Qwen3.8-27B UD-Q4_K_XL after the first one was published. This machine made seed-101 and seed-102 runs of Qwen3.8-Flash-Next UD-IQ2_XS, whose series had started on the other controller.

Those runs had no memory collection either. This machine's collector was not set up for that model host. The dashboard said so in one line, and the runs started anyway. Without the collector a run has no file hashes or maker, so its setup could not match the series that has them ([ADR 0018](0018-declare-and-hash-model-sources.md)). Adding it to the results page created a second line for the same model. The user had missed that line several times.

**A seed does not make a run repeat.** The two seed-101 Qwen3.8-27B runs used the same server build, sampling settings and seed. All 20 cases took a different path in each, and three cases flipped, for 15 and 16 passes. In plausible-pr-5939 the first reply was identical word for word. The second reply, sent the same prompt, chose another `find` command, and from there the attempts differed (126 and 97 messages). The server's arithmetic varies slightly between runs, and at temperature 1.0 a tiny change can tip the choice between two close words. ADR 0011 already said seeded runs vary.

**A series takes its first three runs with final scores, whatever their seeds.** A repeated seed counts like any other. Public schema 13 records `"seeds": "any"`. A series published with seeds 101, 102 and 103 keeps its file. When it takes another run it moves to schema 13, and its runs keep their seeds.

**Each run still draws a random seed,** so runs from different machines record different seeds. A blank seed field draws a seed from 1 to 2,147,483,647, and each run in a row draws its own. That is the largest seed the benchmark sends a model server: llama.cpp reads a 32-bit seed, with 4,294,967,295 meaning "pick one". A larger number would be cut down without notice. A seed typed by hand is used as given. A resumed run keeps its own seed.

**A local model's run needs its memory collected.** A run of a model served by llama.cpp, Strata or Project Maya does not start unless the memory collector is set up for its host. `EAB_MEMORY` must not be off, the host must be in `EAB_MEMORY_HOSTS` when that list is set, and its SSH host key must be trusted. A subscription API has no memory to sample and runs without a collector.

**Mismatches are refused before the run, or before it is added.** A row of contributions longer than the runs its series still needs is refused before it starts. **Add to results page** refuses a run that matches a published series except for the file hashes or maker it lacks.

This amends [ADR 0011](0011-publish-three-run-series.md), whose series took seeds 101, 102 and 103 once each, and [ADR 0018](0018-declare-and-hash-model-sources.md), under which a deployment without a collector ran without hashes.

## Considered options

- **Keep one run per seed, with random seeds.** Random seeds make a repeat unlikely, but the rule would still throw away a finished run for a number that does not make runs repeat. On 2026-11-23 it excluded a 16-of-20 Qwen3.8-27B run that would otherwise have cost another twelve hours to replace.
- **Seeds of 10 to 20 digits.** The server would cut them down to 32 bits, so two seeds that differ on the page could be the same seed on the server.
- **A seed range per machine,** such as 101–103 on one and 201–203 on the other. It needs every contributor to be given a range, and a third machine would still collide.
- **Warn instead of refusing a run without memory collection.** The warning existed and was missed.

## Consequences

- A seed is no longer something to choose. **Contribute a run** leaves the seed blank.
- The dashboard and the results page no longer list missing seeds, only how many runs a series has.
- `EAB_MEMORY=off` now means no local model runs at all. A new model host must be listed and its key trusted before its first run.
- A controller that does not know schema 13 refuses a series file that another controller has moved to it. Update both controllers before either adds a run to a series the other has published.
- The 2026-11-22 seed-101 Qwen3.8-27B run became that series' third run.
