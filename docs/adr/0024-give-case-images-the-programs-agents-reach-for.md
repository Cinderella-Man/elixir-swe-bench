# Give the case images the programs agents reach for

A case image was its `hexpm/elixir` base plus what building and searching need: git, bash, a C toolchain, cmake, ripgrep and the GNU versions of grep, find, diff and coreutils. Nothing else was added, and the task instructions do not say which programs exist.

On 2026-11-19 the saved logs of 309 attempts were read for programs the agents ran and the image did not have ([research note](../research/agent-environment-gaps-2026-11-19/README.md)). Python was run in 209 of them, by every model: 67% of the local-model attempts and 68% of the Claude attempts. No image had it. `pg_isready` or `psql` was run in 40 attempts, `ss` or `netstat` in 15, `file` in 9, and `xxd`, `curl` and `sqlite3` in one or two each. Perl was present on the 17 Ubuntu and Debian images only because `build-essential` depends on it, and missing on the three Alpine ones.

The cost that shows in the logs is one failed call. The cost that does not show is what follows: a model that has seen `python3: command not found` stops trying, so every later use it would have made of Python is gone from that attempt. Where Python exists, about a tenth of Claude's in-place file edits go through it. Nearly every image these models are otherwise run or evaluated in has Python, including the one other benchmark found with Elixir tasks and the one vendor image that ships Elixir.

The user decided the same day that the images get the programs the models use, and that v6 starts from scratch on them: its earlier results are archived, not carried over.

**Every case image now also installs these.**

| | Ubuntu and Debian | Alpine |
|---|---|---|
| Python 3, as `python3` and `python`, standard library only | `python3 python-is-python3` | `python3` |
| Perl | `perl` | `perl` |
| `jq`, `file`, `curl`, `sqlite3` | `jq file curl sqlite3` | `jq file curl sqlite` |
| `ss` and `ip`, `netstat`, `nc` | `iproute2 net-tools netcat-openbsd` | `iproute2`; BusyBox has `netstat` and `nc` |
| `column` | `bsdextrautils`, or `bsdmainutils` on Ubuntu 20.04 | `util-linux-misc` |
| `bc`, `tree`, `xxd` | `bc tree xxd` | BusyBox has them |

**A case whose database is PostgreSQL also gets `postgresql-client`,** for `pg_isready` and `psql`. Its version is the distribution's, not the server's.

**The list is what was reached for, plus what Claude uses most on a desktop.** The first group comes from the attempts. `jq`, `column`, `bc`, `tree` and `nc` come from the Bash calls of 859 Claude Code sessions on the user's machine, where they are the most used programs the images lacked after Python and Perl.

**Left out.** `sudo`, `docker`, `ruby` and `locate` were each tried in three attempts or fewer, and the first two cannot work in a container without privileges. `pip` is left out because the workspace has no network to install from. `wget` was tried once; `curl` is there for a server the agent starts on loopback. The ClickHouse client was never tried. Alpine keeps BusyBox's `sed` and `awk`: 730 `sed` calls on the Plausible cases produced no option error.

**The instructions still do not list the programs.** Two thirds of attempts try Python unprompted, so the images alone remove the failure.

## Considered options

- **Leave the images and say "there is no Python" in the instructions.** It saves the failed call and keeps the hidden cost: the model still works without the scripting language it would have used.
- **Install only Python.** It is two thirds of the calls to a missing program. The rest are small, were also asked for, and make the Alpine images behave like the others.
- **Build on the Docker Official `elixir` image,** which carries git, curl, make and gcc already. Each case pins the `hexpm/elixir` tag its project was prepared and qualified on, so a new base would change far more than the missing programs.
- **Start a new release name.** v7 would have let the earlier series stay on the page as a release of their own. The user chose to keep the name v6 and archive them. At that point v6 had collected results for six days, three of its eleven series were assembled from other runs, and v5 was still the page's primary release.

## Consequences

- **No case file changed.** The recipe is harness code (`Eab.Fixtures.dockerfile/4`), so every admission stays valid. Its hash is part of each project image's inputs: after this change the controller rebuilds all 20 images, attaches Pi again and re-qualifies every case before it can run. **Prepare all cases** does that and needs the internet.
- **v6's earlier results are archived.** A series is identified by its benchmark, cases, harness, model and settings, not by the code version, so a new run would have joined its model's existing series without replacing a seed already filled. The eleven series and the nine saved run logs moved, unchanged, to [`verification/v6-archive-2026-11-19/`](../../verification/v6-archive-2026-11-19/README.md); `results-page/results/` and `verification/runs/` start empty. The page tells releases apart by benchmark ID, so the archived series are not on it.
- **Each controller archives its own v6 runs too.** It groups the runs in its data folder into series the same way. They move from `runs/` to `archive/v6-2026-11-19/runs/` inside the data folder; the archive's README has the two commands.
- **A second controller needs both steps.** After pulling this change it archives its v6 runs and rebuilds its images.
- **The images grow** by 60 to 167 MB each.
- **The grader sees no difference.** On the first controller rebuilt, all 20 cases qualified again and all 16,367 named test outcomes of their controls matched the receipts saved before the change ([record](../../verification/case-images-2026-11-19/README.md)).
- **What this does not fix** is listed in the research note's section 8 and stays open: `/tmp` does not allow running files, six cases have tests that fail before the agent changes anything, `LANG` is unset on Alpine, and the bash tool refuses time limits given in milliseconds.
