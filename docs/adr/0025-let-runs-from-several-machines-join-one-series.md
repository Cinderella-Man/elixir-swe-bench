# Let runs from several machines join one series

Two controllers make runs now: this repository's machine and a second one that serves other models. Each one started a run at seed 101, and **Runs in a row** went on with 102 and 103. A series takes one run per seed ([ADR 0011](0011-publish-three-run-series.md)), so two machines making runs of one model picked the same seeds. On 2026-11-22 the second controller made another seed-101 run of Qwen3.8-27B UD-Q4_K_XL after the first one was published, and that run can never be added. This machine made seed-101 and seed-102 runs of Qwen3.8-Flash-Next UD-IQ2_XS, whose series had started on the other controller.

Those runs had no memory collection either. This machine's collector was not set up for that model host. The dashboard said so in one line, and the runs started anyway. Without the collector a run has no file hashes or maker, so its setup could not match the series that has them ([ADR 0018](0018-declare-and-hash-model-sources.md)). Adding it to the results page created a second line for the same model. The user had missed that line several times.

**Each run draws a random seed.** A blank seed field draws a seed from 1 to 2,147,483,647, and each run in a row draws its own. That is the largest seed the benchmark sends a model server: llama.cpp reads a 32-bit seed, with 4,294,967,295 meaning "pick one". A larger number would be cut down without notice. Three runs of a series share a seed with a chance of about 1 in 700 million. A seed typed by hand is used as given. A resumed run keeps its own seed.

**A series takes its first three runs with distinct seeds.** Public schema 13 records `"seeds": "distinct"`. A series published with seeds 101, 102 and 103 keeps its file. When it takes another run it moves to schema 13: its runs keep their seeds, and it takes any seed it does not have yet. The dashboard and the results page no longer list missing seeds, only how many runs a series has.

**A local model's run needs its memory collected.** A run of a model served by llama.cpp, Strata or Project Maya does not start unless the memory collector is set up for its host. `EAB_MEMORY` must not be off, the host must be in `EAB_MEMORY_HOSTS` when that list is set, and its SSH host key must be trusted. A subscription API has no memory to sample and runs without a collector.

**Mismatches are refused at start and at publication.** A full run is refused at start when it matches a published series that still takes runs and that series already has its seed. A contribution is refused when its seed is already in its series. A row of contributions longer than the runs its series still needs is refused too. **Add to results page** refuses a run that matches a published series except for the file hashes or maker it lacks.

This amends [ADR 0011](0011-publish-three-run-series.md), whose series used seeds 101, 102 and 103, and [ADR 0018](0018-declare-and-hash-model-sources.md), under which a deployment without a collector ran without hashes.

## Considered options

- **Seeds of 10 to 20 digits.** The server would cut them down to 32 bits, so two seeds that differ on the page could be the same seed on the server.
- **A seed range per machine,** such as 101–103 on one and 201–203 on the other. It needs every contributor to be given a range, and a third machine would still collide.
- **Keep 101, 102 and 103 and check the published series before starting.** It catches only what is already published. Two machines running at the same time still pick the same seed.
- **Warn instead of refusing a run without memory collection.** The warning existed and was missed.

## Consequences

- A seed is no longer something to choose. **Contribute a run** leaves the seed blank.
- `EAB_MEMORY=off` now means no local model runs at all. A new model host must be listed and its key trusted before its first run.
- A controller that does not know schema 13 refuses a series file that another controller has moved to it. Update both controllers before either adds a run to a series the other has published.
- The 2026-11-22 Qwen3.8-27B seed-101 run stays unpublished. The same day's seed-102 run of that model can still be added to its series.
