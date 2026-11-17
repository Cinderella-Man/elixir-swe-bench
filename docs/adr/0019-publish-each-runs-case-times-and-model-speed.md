# Publish each run's case times and model speed

Since run series began (public schema 5), the results page has published no timing: a series combines runs from different machines and days, and this project does not score speed. Private run records kept each Pi attempt's elapsed time and, since 2026-11-09, its model speed, but only the dashboard and run reports showed them. On 2026-11-17 the user asked for time and speed as part of each published run.

Public schema 9 adds `timing` to each run and to each of its cases. A case's timing is its attempt's elapsed time in whole milliseconds, Pi startup through completion, with its model speed: prompt tokens and milliseconds, generated tokens and milliseconds, model calls, llama.cpp's draft tokens and how many were accepted, and whether the server reported the timings or the controller timed them with the network included. A run's timing is the sum over its timed cases, with how many there were. The schema checks that the run's figures add up to its cases' figures. Timing is null when nothing was recorded: when the run worked on several cases at once (ADR 0014), and for Claude Code, whose attempts record no time.

Timing belongs to the run, never to the series: the page lists each run's total case time and tokens per second in a **Time & speed** table, and each case's time and generation speed per run. Nothing averages them across runs, ranks series by them or puts them on the chart. The score is unchanged.

Series published as schema 8 keep their files unchanged and still validate. A schema 8 series that takes another run is upgraded then, with null timing for the runs it already had. The earlier v5 release is left as published.

## Considered options

- **Average speed per series, like the score**: runs of one series may come from different hardware, servers and days, so a mean would describe no machine.
- **Migrate every published file to schema 9 with null timing**: the precedent for schemas 7 and 8, but it rewrites the frozen v5 release for fields it can never fill.
- **Backfill published v6 runs from their private records**: possible, since the records hold the measurements. It is a separate choice about changing published results, and is not part of this decision.
- **Wall-clock run duration**: run records keep a start time but no finish time. That span would also include preparation, waiting and grading, which depend on the controller's other work rather than the model.
