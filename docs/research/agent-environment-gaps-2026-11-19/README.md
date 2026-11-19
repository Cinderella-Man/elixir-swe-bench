# What the case containers lack that agents reach for, and what it costs

Date: **2026-11-19**. Status: **analysis**. Nothing was changed and no model runs were started for it. The same day
the user decided on the missing programs:
[ADR 0024](../../adr/0024-give-case-images-the-programs-agents-reach-for.md) adds them to the case images. It follows
[Python and Perl in the case containers](../agent-tools-and-capped-reasoning-2026-11-19/README.md), which counted
failed Python calls in the 9 local-model runs. The user asked for the wider question:

1. What is the impact of the missing Python, and of similar problems nobody had noticed?
2. What else do models use on a normal desktop that the case containers do not have?

## Short answer

- **Python is the only program that is missed often, and every model misses it about equally.** Agents ran Python in
  **209 of 309 saved attempts** (235 calls), and it is in none of the 20 case images. That is 67% of the local-model
  attempts and 68% of the Claude attempts: Opus 5.5 in 40 of 64, Sonnet 5.5 in 43 of 44, Haiku 5.5 in 18 of 40. So
  the user's hunch is right that Opus reaches for Python here as it does on the desktop, and the cost is not special
  to weak models.
- **The cost that shows in the logs is small, and it is only the visible part.** Five in six failed calls were
  scripts to edit a file. The agent redid the edit another way after a median of **one** tool call (mean 1.6). In the
  local-model runs, the replies that made these calls hold 1.0% of all generated tokens. No edit to a source file was
  lost silently in any of the 309 attempts.
- **After the first failure a model stops trying, so the Python it would have used later is not in the logs.**
  [What the first failure hides](#what-the-first-failure-hides) sizes that part as far as logs allow: where Python
  exists, about a tenth of Claude's in-place edits go through it; three quarters of the scripts attempted here did
  only what the edit tool does; and edits made with `sed` or `perl` instead were not followed by syntax errors
  noticeably more often. What it does to pass rates is not known.
- **No attempt can be shown to have failed because of it.** The one candidate named earlier (Flint Q8_0,
  `plausible-pr-5939`) ended for another reason: the model noticed that Python was missing, then wrote its next tool
  call inside its reasoning text, which the harness cannot run. Its patch held no source change at that point.
- **The second most common gap is database tools.** In the cases with PostgreSQL, agents ran `pg_isready` or `psql`
  in 40 attempts to see whether the database was up. Neither is installed. All of them went on to run the tests.
- **Three problems of a different kind turned up, and they are not missing programs:**
  1. **`/tmp` does not allow running files.** Docker mounts it that way unless told otherwise. On the untouched
     `pinchflat-pr-610` image, 5 of the project's own tests fail for this reason alone and pass when execution is
     allowed. All 15 saved attempts on that case saw them fail.
  2. **Five more cases have tests that fail before the agent changes anything**, because they need the network, a
     built front end, seeded data or a secret. Agents saw them in 57 of 76 attempts on those cases.
  3. **Some local models give the bash tool's time limit in milliseconds; the tool takes seconds.** Flint Q8_0 had
     19 calls rejected for it, 17 of them in one attempt.
- **Everything else is rare**: `ss`/`netstat` in 15 attempts, `file` in 9, and `sudo`, `curl`, `wget`, `xxd`, `perl`
  (Alpine only), `ruby`, `sqlite3` and `docker` in 3 or fewer each.

None of this explains differences between models, because all models ran in the same containers. Whether fixing it
would move pass rates cannot be read from logs; [Limits](#limits) says what would settle it.

## What was measured

| Source | What it is | Size |
|---|---|---:|
| `verification/v6-archive-2026-11-19/runs/` | 9 local-model runs through Pi (DeepSeek, Qwen3.8-27B, Qwen3.8-Flash-Next, Flint) | 161 attempts, 15,057 bash calls |
| `verification/opus-validation-2026-10-26/`, `opus-validation-2026-11-17/` | Opus 5.5 through Claude Code | 64 attempts |
| `verification/sonnet-series-2026-10-28/`, `sonnet-series-2026-11-17/` | Sonnet 5.5 through Claude Code | 44 attempts |
| `verification/haiku-series-2026-11-17/` | Haiku 5.5 through Claude Code | 40 attempts, 10,670 bash calls for all three |
| The 20 case images | `probe.sh` run in each; result in [`image-inventory.json`](image-inventory.json) | 279 program names |
| Untouched case images | Tests run with `baseline.sh`, started the way the harness starts them | 6 cases |
| Claude Code sessions on the user's desktop | Program names from the Bash calls of other work, benchmark sessions left out | 859 sessions, 83,968 bash calls |

The Claude attempts of October were made on the v5 release. They are used here only for what the agents ran: the case
images come from the same recipe, and the failures are the same ones.

Both harnesses give the model the same four tools (read, bash, edit, write), and bash runs inside the case container.
In Claude Code they are the `mcp__eab_workspace__*` tools.

## 1. What the containers contain

Each case image is a `hexpm/elixir` image plus one install line (`lib/eab/fixtures.ex`, `dockerfile/4`):

```
git bash ca-certificates build-essential brotli cmake grep ripgrep coreutils findutils diffutils
```

On Alpine, `build-base` stands in for `build-essential`. The agent is user `agent` (uid 1000) without `sudo`. The
container has no network, 4 GB of memory, 2 CPUs, at most 512 processes, and a 512 MB `/tmp`.

| | 17 Ubuntu/Debian cases | 3 Alpine cases (Plausible) |
|---|---|---|
| Present | bash, git, GNU grep/sed/find, `rg`, perl 5, make, gcc, cmake, patch, diff, ps, tar, gzip, openssl | bash, git, GNU grep/find, `rg`, make, gcc, cmake, patch, diff, ps; also node, tree, file, less, xxd, bc, nc, unzip, wget, vi, which BusyBox or the base image brings |
| Missing | python3, jq, curl, wget, file, less, tree, xxd, bc, unzip, zip, column, vi/nano/ed, sudo, ruby, sqlite3, `psql`/`pg_isready`, `ss`/`netstat`, `ip`, rsync, ssh | python3, **perl**, jq, curl, column, zip, sudo, ruby, sqlite3, `psql`/`pg_isready`, `ss`, rsync, ssh; `sed` and `awk` are BusyBox's, and `LANG` is unset |

Perl is there by accident: on Debian and Ubuntu `build-essential` depends on `dpkg-dev`, which depends on `perl`
and `patch`. Alpine's `build-base` does not.
Node is in the three Plausible cases and `livebeats-pr-37` only. Every workspace has a single git commit, so
`git log` and `git blame` show no history. The task instructions say "Dependencies are prepared. The workspace is
offline." and nothing about which programs exist.

## 2. Programs agents ran that the image did not have

A call counts when the program stands where the shell runs a command and `image-inventory.json` says that case's
image lacks it. "Attempts" is the number of case attempts with at least one such call.

| Harness | Model | Attempts | Passed when graded | Attempts with Python | Python calls | Other missing programs (attempts) |
|---|---|---:|---:|---:|---:|---|
| Claude Code | Opus 5.5 | 64 | 57 | 40 | 40 | pg_isready 4, psql 2 |
| Claude Code | Sonnet 5.5 | 44 | 40 | 43 | 48 | pg_isready 9, ss 7, netstat 7, sudo 2, sqlite3 1, docker 1 |
| Claude Code | Haiku 5.5 | 40 | 38 | 18 | 21 | pg_isready 11, ss 4, netstat 4, file 1, psql 1 |
| Pi | DeepSeek-V4.1-Flash UD-IQ1_M | 20 | 17 | 16 | 20 | curl 2, wget 1 |
| Pi | DeepSeek-V4.1-Flash GSQ-RCO Coder | 20 | 15 | 17 | 18 | perl 1, locate 1 |
| Pi | Qwen3.8-27B UD-Q6_K_L | 20 | 16 | 12 | 13 | file 2, psql 1, pg_isready 1, ruby 1 |
| Pi | Qwen3.8-27B UD-Q4_K_XL | 20 | 18 | 8 | 9 | file 2, pg_isready 1, psql 1, sudo 1 |
| Pi | Qwen3.8-27B Q8_0 | 20 | 16 | 12 | 14 | file 4, pg_isready 3, psql 2, ss 2, netstat 2 |
| Pi | Qwen3.8-Flash-Next UD-IQ2_XS | 21 | 18 | 13 | 13 | pg_isready 7, psql 2, ss 1, netstat 1, perl 1 |
| Pi | Flint Q8_0 | 20 | 11 | 16 | 21 | xxd 2, pg_isready 1 |
| Pi | Flint UD-Q4_K_XL | 20 | 10 | 14 | 18 | pg_isready 2, ss 1, netstat 1 |
| | **All** | **309** | **256** | **209** | **235** | |

All missing programs, as calls / attempts: python 235 / 209, pg_isready 40 / 39, ss 16 / 15, netstat 15 / 15,
psql 12 / 9, file 9 / 9, sudo 3 / 3, curl 2 / 2, perl 2 / 2, xxd 2 / 2, wget 1 / 1, locate 1 / 1, ruby 1 / 1,
sqlite3 1 / 1, docker 1 / 1.

- **Database tools.** `pg_isready` and `psql` were run in 40 attempts, in seven of the nine cases whose database is
  a separate PostgreSQL container. In 39 of them the check came before the first test run: the agents were looking
  around, not reacting to an error. The database was reachable every time, and all 40 ran `mix test` afterwards.
- **`ss` and `netstat`** were the same kind of check, for a listening port.
- **`file`** was run to identify a file's type or encoding, and **`xxd`** to look at bytes. `od` is present and the
  local models used it 47 times.
- **`curl`, `wget`, `git ls-remote`** came from two DeepSeek UD-IQ1_M attempts. In `ash-pr-3031` it tried to fetch
  the upstream version of the file it was repairing. The network being off stopped that, as intended.
- **Network use was otherwise nearly absent**: 2 `npm` fetches and 3 web lookups from Elixir in 309 attempts. The
  instructions' "The workspace is offline" is understood.

## 3. Python: what the agents wanted it for and what the failure cost

| | Pi, local models | Claude Code |
|---|---:|---:|
| Python calls | 126 in 108 of 161 attempts | 109 in 101 of 148 attempts |
| Calls whose script wrote a file | 102 | 97 |
| Calls that showed `command not found` | 117 | 100 |
| Calls that hid the error behind `2>/dev/null` | 8 | 8 |
| Edit scripts that named their file | 99 | 89 |
| Of those, the file was changed another way later | 97 | 84 |
| Tool calls until then | median 1, mean 1.6 | median 1, mean 1.4 |
| Attempts with more than one Python call | 15 | 7 |

- **What they were.** Throwaway scripts on stdin (`python3 - <<'PY' … PY`) that read a file, replace a block and write
  it back. The rest printed part of a file, parsed JSON or inspected an HTML dump.
- **Why Python.** It is a first choice, not a fallback from the edit tool. Only 11 of the 126 calls in the Pi runs
  came within two calls of a refused edit, and none of the 109 in Claude Code did. Opus, whose 564 edit-tool calls
  all succeeded, still wrote one Python edit script in 40 of its 64 attempts.
- **Each model learns once.** Opus never called Python twice in an attempt. After the first failure the agents used
  the edit tool (about half the time), `sed -i`, `perl -i` or a rewrite with `cat > file`.
- **The files that were never changed another way** are 2 for Pi and 5 for Claude Code. Six are scratch files: five
  under `/tmp` and one throwaway probe test. The seventh is the Flint attempt below.
- **Hidden failures did no harm.** The 16 calls that sent the error to `/dev/null` were probes or stubs in front of
  the command that did the work: `python3 - <<'EOF' 2>/dev/null || sed -i …`,
  `python3 -c 1 2>/dev/null; perl -0pi …`, or an empty Python heredoc followed by the real command.
- **Tokens.** In the Pi runs the replies that made a Python call hold 111,729 generated tokens, 1.04% of the
  10.7 million generated in all 161 attempts. Those replies also hold reasoning and other calls, so the waste is
  below that. Per affected attempt the median is 0.8% of its tokens. In the 22 attempts that ran out of context, these
  replies took at most 4,586 of the 262,144 tokens. Claude Code's transcripts were measured by script length
  instead: median 925 characters.

### The one attempt that ended at a Python failure

In the Flint Q8_0 run (`20261117-232211-330ad401`), `plausible-pr-5939` ended two calls after a failed Python edit.
The earlier note read this as the agent not noticing. The log shows otherwise:

1. The agent added tests inside a nested `describe`, which does not compile.
2. Its edit to fix that was refused (old text did not match), and it tried a Python script instead.
3. After `python3: command not found` its next reply begins "No python3. I'll use the edit tool instead", and the
   reply ends with the tool call written inside the reasoning text (`…EOF</arg_value></tool_call>`). The harness
   saw a reply with no tool call and no answer, and ended the attempt (`stop_reason: agent_completed`) at 19,999
   generated tokens and a peak context of 69,633.

The submitted patch changes only the test file and has no repair, so the attempt had not solved the case yet. What
ended it was the malformed tool call. It is the only attempt of the 161 recorded as finished by the agent although
its last reply held reasoning and no answer.

### Passing and Python

Local-model attempts with a Python call passed 69% of the time (74 of 108), those without 89% (47 of 53). This is
not the effect of Python. Attempts with a Python call made a median of 134 tool calls against 74: longer, harder
attempts make more edits, so they meet more refused edits and reach for Python more often. For Opus the rates are
36 of 40 with and 21 of 24 without.

### What the first failure hides

A model that has seen `python3: command not found` does not try again, so every later use it would have made of
Python is missing from the logs, and the counts above are a lower bound. Three measurements bound that hidden part.
None of them turns it into a pass rate.

**How much would go through Python if it were there.** In 812 Claude Code sessions on the user's desktop, where
Python works, Python is 5,519 of 84,194 shell calls (6.6%). For changes to an existing file:

| How the file was changed on the desktop | Calls | Share |
|---|---:|---:|
| Edit tool | 14,153 | 64% |
| `perl -i` | 4,123 | 19% |
| Python script | 2,099 | 10% |
| `sed -i` | 1,673 | 8% |

A quarter of the sessions (203) have at least one Python edit. The other 3,400 Python calls read JSON, compute,
print or write new files. In the benchmark all of that is rerouted or dropped after the first call.

**What the attempted scripts were doing.** Of the 199 edit scripts in the 309 attempts:

| The script | Scripts | Share |
|---|---:|---:|
| only replaces exact text, once (77) or several times (74) | 151 | 76% |
| works by line number or position, for example "replace lines 568 to 764 with this block" | 30 | 15% |
| changes several files | 15 | 8% |
| has a loop | 11 | 6% |
| uses a regular expression | 5 | 3% |

The last four overlap; 48 scripts (24%) use at least one. For the first row the model loses nothing but the call:
the edit tool does the same exact replacement, several per call. The other quarter is the real loss. Replacing a
long block by its line numbers needs no copy of the old text; the edit tool needs the old text retyped exactly, and
`sed` needs a delete and an insert.

**Whether the substitutes break files more often.** For each change to a file, the next `mix compile`, `mix test`,
`mix format` or `elixir` call was checked for a syntax error (`SyntaxError`, `TokenMissingError`,
`MismatchedDelimiterError`, a missing terminator):

| How the file was changed | Local models: checked | syntax error | Claude: checked | syntax error |
|---|---:|---:|---:|---:|
| Edit tool | 1,135 | 5.1% | 758 | 2.8% |
| `sed -i` | 238 | 5.9% | 151 | 4.6% |
| `perl -i` | 107 | 8.4% | 19 | 0% |

The shell routes are a little worse, by less than these counts can establish. This catches a file left syntactically
broken. It does not catch an edit that changed the wrong thing, or the tokens spent retyping a block.

So the hidden part is real and is not large by these measures: roughly a tenth of edits take a clumsier route, and
quick inspections are done with `grep`, `sed -n` or Elixir instead. Whether a model reasons differently about the
task without its usual scripting language is not something logs can show. The with-and-without runs in
[Limits](#limits) would.

## 4. Problems that are not missing programs

### 4.1 `/tmp` does not allow running files

The sandbox starts each container with `--tmpfs=/tmp:rw,nosuid,size=512m` (`lib/eab/sandbox.ex`). Docker adds
`noexec` to a tmpfs mount unless `exec` is given, and the mount inside the container reads
`rw,nosuid,nodev,noexec`. A file in `/tmp` can be read by an interpreter (`bash /tmp/x.sh`, `elixir /tmp/x.exs`) and
cannot be run by its path.

- **Pinchflat's own tests.** `Pinchflat.Lifecycle.UserScripts.CommandRunnerTest` writes a script under `/tmp` and
  runs it. On the untouched `pinchflat-pr-610` image:

  | `/tmp` mounted with | `mix test test/pinchflat/lifecycle/user_scripts` |
  |---|---|
  | `rw,nosuid,size=512m` (the harness) | 9 tests, **5 failures**, `cannot execute: Permission denied` |
  | `rw,exec,nosuid,size=512m` | 9 tests, 0 failures |

  All 15 saved attempts on this case ran the whole suite and saw the five failures, and 12 of them spent calls on
  them afterwards (29 calls in all, up to 6 in one attempt). The grader's test lists do not include these tests.
- **Agents' own scripts.** 5 calls ran a script in `/tmp` by its path and got `Permission denied`: 1 in the Pi runs
  and 4 by Sonnet.

### 4.2 Tests that fail before the agent changes anything

Found by listing tests that failed for five or more different models in the same case, then running them on the
untouched image with `baseline.sh`. "Saw" is the number of saved attempts whose test output contains them; "calls
after" counts later tool calls that name those tests or their cause.

| Case | Failing at the start | Cause | Saw | Calls after |
|---|---|---|---:|---:|
| `pinchflat-pr-610` | 5 tests in `CommandRunnerTest` | `/tmp` is `noexec` (4.1) | 15 of 15 | 29 |
| `accent-pr-183` | 2 in `WebappController`, 3 in `GraphQL.Resolvers.Language` | no built `priv/static/webapp/index.html`; the language list is not seeded | 14 of 15 | 16 |
| `operately-pr-1069` | 1 in `CreateBlobTest` | request answers 500: `:base64.decode/1` on a missing setting | 12 of 15 | 17 |
| `operately-pr-1205` | the same `CreateBlobTest` (not rerun here) | the same | 9 of 15 | 13 |
| `beacon-pr-687` | `ComponentsTest`: "embed displays youtube video" | needs the network (`oEmbed url not found`) | 12 of 16 | 8 |
| `livebook-pr-3076` | `SessionLiveTest`: "python code evaluation end-to-end" | needs the network to install `pythonx`; waits 40 s | 10 of 15 | 8 |

These tests are outside each case's graded lists, so they do not fail a submission. Their cost is in the attempt:
an agent that runs the whole suite to check for regressions sees failures it did not cause and cannot fix, and has
to work out that they are not its own. Most did so with one or two calls, usually `git stash` and a rerun. The
instructions name one test command, and do not say that other tests may fail in the container.

### 4.3 The bash tool's time limit is in seconds

Pi's bash tool takes `timeout` in seconds, and its description says so ("Timeout in seconds (optional, no default
timeout)"). Three local models sometimes gave milliseconds anyway:

| Model | Calls with a value of 100,000 or more | Rejected |
|---|---:|---:|
| Flint Q8_0 | 80 | 19 |
| DeepSeek GSQ-RCO Coder | 56 | 0 |
| Flint UD-Q4_K_XL | 25 | 0 |

A value such as `120000` is accepted as 33 hours and does no harm, because the harness's own 1,200-second hang guard
still applies. Values above 2,147,483 are refused with `Invalid timeout: maximum is 2147483.647 seconds`. Flint Q8_0
sent `3060000` and `3000000` seventeen times in `livebook-pr-2822` before lowering it, and passed the case. Claude
Code's own Bash tool takes milliseconds, which may be where the habit comes from; the Claude models did not make the
mistake with the benchmark's tool.

### 4.4 Two things only the Claude Code harness has

- **A scratch folder that is not in the container.** Claude Code tells the solver about a scratchpad folder under
  `/tmp/claude-<uid>/…` on the host. The solver uses that path in the container, where it does not exist until it
  creates it: 34 calls in 27 attempts failed with `No such file or directory` first.
- **Calls to tools that were never offered.** Sonnet 5.5 called `bash_placeholder`, `str_replace_placeholder`,
  `bash_not_available` or `str_replace_based_edit_tool` 15 times in 9 attempts. Each was refused and it went on.

### 4.5 For scale: edits the edit tool refused

This is not an environment gap. It is here because it is the larger cost of the same kind, a tool call that does
nothing. The edit tool replaces text that matches exactly, and refuses otherwise.

| Model | Edit calls | Refused | Share |
|---|---:|---:|---:|
| Flint Q8_0 | 334 | 66 | 20% |
| Flint UD-Q4_K_XL | 343 | 61 | 18% |
| Qwen3.8-27B UD-Q6_K_L | 340 | 43 | 13% |
| Qwen3.8-27B Q8_0 | 352 | 33 | 9% |
| Qwen3.8-27B UD-Q4_K_XL | 257 | 20 | 8% |
| DeepSeek-V4.1-Flash UD-IQ1_M | 199 | 15 | 8% |
| DeepSeek-V4.1-Flash GSQ-RCO Coder | 189 | 11 | 6% |
| Qwen3.8-Flash-Next UD-IQ2_XS | 350 | 21 | 6% |
| Haiku 5.5 | 550 | 29 | 5% |
| Sonnet 5.5 | 588 | 25 | 4% |
| Opus 5.5 | 564 | 0 | 0% |

Flint Q8_0 lost 66 calls to refused edits and 21 to Python. Unlike Python, this one separates the models: it is part
of what the benchmark measures, since every model gets the same tool.

## 5. What Claude uses on the desktop that the containers lack

From the Bash calls of 859 Claude Code sessions on the user's machine (other work, mostly Opus), counting each
program once per call. Only program names were read.

| Program | Calls | Sessions using it | In the case images |
|---|---:|---:|---|
| python3 / python | 4,655 | 459 of 859 | none |
| perl | 4,406 | 398 | the 17 Ubuntu/Debian images |
| column | 205 | 97 | none |
| jq | 149 | 31 | none |
| ss | 99 | 63 | none |
| file | 48 | 21 | the 3 Alpine images |
| bc | 16 | 5 | the 3 Alpine images |
| nc | 13 | 5 | the 3 Alpine images |
| xxd | 9 | 7 | the 3 Alpine images |
| tree | 8 | 6 | the 3 Alpine images |

Python is the twelfth most used program there, in more than half of all sessions. About 45% of its calls write a
file and about a quarter read JSON. Everything above it in the list (grep, head, sed, git, cut, cat, tail, ls,
timeout, wc) is in every case image, as are awk, sort, diff, find, tar and the rest of coreutils. `ssh`, `scp`,
`rsync`, `gh`, `curl` and `docker` are also used heavily on the desktop and are absent, which is intended for an
offline workspace.

## 6. What other harnesses and their usual environments provide

Two background agents read the primary sources on 2026-11-19: the Dockerfiles, prompt files, papers and official
docs at that day's commits. Their full notes, with a link for every claim and a list of what they could not verify,
are in [`sources-agent-harnesses.md`](sources-agent-harnesses.md) and
[`sources-benchmark-environments.md`](sources-benchmark-environments.md). Three of their claims were fetched again
for this report and matched: the Longtail-SWE Elixir Dockerfile, Anthropic's infrastructure-noise figures and the
Terminal-Bench paper's task count. The points that bear on this benchmark:

### 6.1 Python is in nearly every image these models are run or evaluated in

| Environment | Python | ripgrep | jq | Elixir | Source |
|---|---|---|---|---|---|
| **This benchmark's case images** | no | yes | no | yes | section 1 |
| Pi's own example container: `node:24-bookworm-slim` plus `bash ca-certificates git ripgrep` | no | yes | no | no | [pi `docs/containerization.md`](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/docs/containerization.md#L38-L49) |
| `openai/codex-universal`, the reference for Codex's cloud image | 3.10 to 3.14 | yes | yes | **1.18.3 on Erlang 27.1.2** | [Dockerfile](https://github.com/openai/codex-universal/blob/47f4f0eb5337083e2f610db0d15558932cb4901d/Dockerfile) |
| Claude Code cloud sessions | 3.x with pip, uv, pytest | yes | yes | no | [docs: installed tools](https://code.claude.com/docs/en/cloud-environments#installed-tools) |
| Claude Code reference devcontainer: `node:20` plus `less git procps sudo fzf zsh man-db unzip gnupg2 gh iptables ipset iproute2 dnsutils aggregate jq nano vim` | not listed | not listed | yes | no | [Dockerfile](https://github.com/anthropics/claude-code/blob/5b0e5f0b2a1ab83e6eed885433680361c621839d/.devcontainer/Dockerfile) |
| Gemini CLI sandbox: `node:20-slim` plus `python3 make g++ man-db curl dnsutils less jq bc gh git unzip rsync ripgrep procps psmisc lsof socat ca-certificates` | yes | yes | yes | no | [Dockerfile](https://github.com/google-gemini/gemini-cli/blob/acfb42d0dfc111fd1d5c5d45535daf6aa7d8696b/Dockerfile#L49-L68) |
| Qwen Code sandbox: `node:22-slim` plus the same list | yes | yes | yes | no | [Dockerfile](https://github.com/QwenLM/qwen-code/blob/d79bb9b712119392a3df0174054120e6ab54cb97/Dockerfile#L68-L87) |
| SWE-bench Python images: `ubuntu` plus `wget git build-essential libffi-dev libtiff-dev python3 python3-pip python-is-python3 jq curl locales locales-all tzdata` | yes | no | yes | no | [templates, v4.1.0](https://github.com/SWE-bench/SWE-bench/tree/726c5461e2ef52d83cf1ea2107870a8bb3328d57/swebench/harness/dockerfiles) |
| Aider's benchmark image: `buildpack-deps:jammy` plus Python 3.11, Java, Go, Rust, Node | yes | no | not listed | no | [Dockerfile](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/benchmark/Dockerfile) |

- **The case images match Pi's own example container and almost nothing else.** Pi's authors ship the same lean
  set, and the benchmark already adds a compiler and GNU tools on top.
- **The one vendor image that has Elixir has Python beside it**, with `ripgrep`, `fd`, `jq`, `sqlite3`, `curl`,
  `unzip` and `zip`.
- **Scaffolds that need Python in the task container bring their own.** SWE-agent's edit tools are Python scripts, and
  it builds a standalone Python 3.11 into the task image. For repositories in other languages it links `python` onto
  the path when the image has none
  ([`multilingual_setup/install.sh`](https://github.com/SWE-agent/SWE-agent/blob/3ea751c087f32b16e039a2233dd6eefecef325d5/tools/multilingual_setup/install.sh)),
  so a model evaluated on Go or Java tasks through SWE-agent could still call `python`. OpenHands copies a private
  Python for its own server. mini-swe-agent needs only bash and installs nothing.

### 6.2 What models are told and trained to edit with

- **Pi tells the model nothing about Python or about missing programs.** Its default prompt carries the rule "Use
  bash for file operations like ls, rg, find"
  ([`system-prompt.ts`](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/system-prompt.ts#L114)).
  Its edit tool matches exactly, then retries after normalising trailing whitespace, quotes and dashes. It does not
  forgive a difference in indentation, and its refusal does not say what differed
  ([`edit-diff.ts`](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/tools/edit-diff.ts)).
  The links are to Pi 1.5.2; the benchmark pins 1.2.0, whose build has the same matching code and the same bash
  description, "Timeout in seconds (optional, no default timeout)".
- **OpenAI had to tell its models not to do this.** The prompt shipped with Codex for its current models says "Do not
  use Python to read or write files when a simple shell command or `apply_patch` is enough"
  ([`models.json`](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/models-manager/models.json)).
  A vendor writes that line when the habit is common.
- **Claude's published SWE-bench scaffold** is a bash tool and an exact string-replace edit tool, run on images that
  have Python ([Anthropic, SWE-bench Sonnet](https://www.anthropic.com/engineering/swe-bench-sonnet)).
- **Qwen3-Coder-Next's training trajectories** came from SWE-agent, mini-SWE-agent, OpenHands, Claude Code, Qwen Code
  and Terminus ([technical report](https://arxiv.org/html/2603.00729v1)). Several of those give the model bash and
  little else, on images where Python exists. mini-swe-agent's own prompt teaches `sed -i` and heredocs
  ([`default.yaml`](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/config/default.yaml#L63-L96)).
- **No vendor says outright** that its model edits with Python when no familiar edit tool fits. That reading is an
  inference from the three points above and from the logs here.

### 6.3 Comparable benchmarks put Python in the task image, or leave the network on

| Benchmark | Python in task images for other languages | Network for the agent | Source |
|---|---|---|---|
| **This benchmark** | no | off | section 1 |
| Longtail-SWE (Nebius, November 2026; 13 languages, Elixir and Erlang among them) | **yes**: the Elixir base is `elixir:1.18.4-otp-27` plus `git curl wget unzip zip ca-certificates build-essential pkg-config cmake gnupg inotify-tools nodejs npm python3 python3-pip python3-venv rustc cargo` and four `-dev` libraries | not stated | [`Dockerfile_elixir`](https://github.com/SWE-rebench/Longtail-SWE/blob/87afdd67cb8187b36d7a0c045f8c917847029a82/base_dockerfiles/Dockerfile_elixir) |
| SWE-bench Pro (Scale AI) | **yes, by a rule in the template**; in all 7 sampled Go and JS/TS images, one of them Alpine | not stated | [sample Dockerfile](https://github.com/scaleapi/SWE-bench_Pro-os/blob/66f92766bba642462d4bbe5479e83f91f9211862/dockerfiles/base_dockerfile/instance_flipt-io__flipt-02e21636c58e86c51119b63e0fb5ca7b813b07b1/Dockerfile) |
| SWE-PolyBench (Amazon) | JS and TS yes; Java not listed | not stated | [`constants.py`](https://github.com/amazon-science/SWE-PolyBench/blob/9c836c5d7f3cb991934132b77d29e6941d912a07/src/poly_bench_evaluation/constants.py) |
| SWE-bench Multilingual | C and C++ yes; Go, Java and PHP no | not stated | [templates, v4.1.0](https://github.com/SWE-bench/SWE-bench/tree/726c5461e2ef52d83cf1ea2107870a8bb3328d57/swebench/harness/dockerfiles) |
| SWE-Lancer (OpenAI) | yes, Python 3.12 beside the JS app | **off**; "All the libraries the agent can access … are installed in the container" | [Dockerfile](https://github.com/openai/frontier-evals/blob/5305e936ba7824654151bffab4027afb593d7cd8/project/swelancer/Dockerfile_x86_base) |
| Terminal-Bench 2.0 | 56 of 89 tasks; 33 have none (counted from the task Dockerfiles by the background agent) | **on** in 89 of 89 tasks, so agents install what is missing | [paper](https://arxiv.org/abs/2601.11868), [tasks](https://github.com/harbor-framework/terminal-bench-2/tree/2fd12b88aafdd04a52c298e3940bcb189f9766d6) |

- **A bare image with the network off is the unusual combination.** Benchmarks that keep images bare let the agent
  install things; the one that turns the network off, SWE-Lancer, installs everything first.
- **The other benchmark with Elixir tasks ships Python in its Elixir image.** It builds on the Docker Official
  `elixir` image, which carries `git`, `curl`, `make`, `gcc` and `patch` already. `hexpm/elixir` is the tier below:
  its final stage adds only runtime libraries to a bare Ubuntu, Debian or Alpine
  ([`hexpm/bob`](https://github.com/hexpm/bob/blob/908051c727fff18d83be0fb6af1bc1c6ae5c0eff/priv/scripts/docker/elixir-ubuntu.dockerfile)).
- **`LANG`.** The official image sets `LANG=C.UTF-8` on every variant with the comment "elixir expects utf8".
  `hexpm/elixir` sets it on Ubuntu and Debian and not on Alpine, which is why the three Plausible cases run without
  it.

### 6.4 What has been published about environments moving scores

- **Missing programs are the commonest failed command elsewhere too.** In the Terminal-Bench 2.0 paper's sample of
  3,800 failed commands, calls to executables "not installed or not in PATH" are the largest class at 24.1%, with
  the network on ([arXiv 2601.11868](https://arxiv.org/abs/2601.11868), section 4.5). The paper does not say what
  that does to task success.
- **Resource limits moved Terminal-Bench 2.0 by 6 points** between the strictest and the uncapped setup, and
  SWE-bench by 1.54 points. Anthropic's advice from that: "leaderboard differences below 3 percentage points deserve
  skepticism" until the setup is documented and matched
  ([Anthropic, 2026-02-05](https://www.anthropic.com/engineering/infrastructure-noise)).
- **Tasks that cannot run on a vendor's machines cost 2 to 2.5 points**: 23 of 500 SWE-bench Verified problems for
  OpenAI ([GPT-4.1 post](https://openai.com/index/gpt-4-1/)), 11 of 500 for Anthropic
  ([Claude 3.7 Sonnet post](https://www.anthropic.com/news/claude-3-7-sonnet)).
- **What the sources recommend** matches section 8. Tell the model what the environment is: Anthropic's SWE-bench
  bash tool says "You don't have access to the internet via this tool" and that a package mirror exists
  ([post](https://www.anthropic.com/engineering/swe-bench-sonnet)). Label environment failures apart from model
  failures, as SWE-bench's harness does since 5.0
  ([`infra_failure.py`](https://github.com/SWE-bench/SWE-bench/blob/02e7a74ffd0b707aab73d203fe87bdc7c76afc8e/swebench/harness/infra_failure.py)).
  Read the transcripts of failed attempts to confirm the cause was within the agent's control, as METR does for
  HCAST ([arXiv 2503.17354](https://arxiv.org/abs/2503.17354)).
- **Nobody has published the comparison this question needs.** No source was found that holds a benchmark fixed and
  compares scores with and without Python, or with and without general tools, in the image.

## 7. Checked and found not to be a problem

- **ripgrep.** Pi's system prompt tells the model to "Use bash for file operations like ls, rg, find". `rg` is in
  every image and never failed.
- **BusyBox `sed` and `awk` on Alpine.** 730 `sed` calls on the Plausible cases, none with an option error. `grep`
  and `find` there are the GNU ones.
- **Memory, processes and disk.** In both sets of logs no command was killed for memory, none hit the process
  limit and none filled `/tmp`.
- **The database.** No sign in any output that the database could not be reached.
- **Locale.** `LANG` is unset on Alpine, and no encoding warning or error appears in any output.
- **Git.** No identity or ownership errors. The single-commit history did not produce a failed command.
- **Hung commands.** 13 calls in the Pi runs ran into a time limit, the agent's own or the 1,200-second hang guard:
  four were `grep -r … /` over the whole filesystem, five were Livebook test runs, two were `erl` scripts without
  `halt` and two were Elixir scripts. All are the agents' own doing and would hang on a desktop too. A suspicion
  that Elixir hangs when its output is piped into `head` was tested in a case image and is false.
- **`mix` tasks.** A task the project does not have, `credo` mostly, was run 9 times in 309 attempts.

## 8. What could be done in a later release

Each of these changes what every model is given, so none belongs in v6. The image changes alter the preparation of
all 20 cases, which the [case curation workflow](../../case-curation-loop.md) treats as a change to each case.

1. **Mount `/tmp` with `exec`.** One word in `lib/eab/sandbox.ex`. It removes five false failures in Pinchflat and
   lets scripts run by path. The grader uses the same sandbox, so the cases need re-qualifying with it.
2. **Add Python and a few small tools to the image line**: `python3`, `perl` (for Alpine), `jq`, `file`, `less`,
   `xxd`, `bc`, `tree`, and `postgresql-client` for the cases with a database. Python is the one that is used; the
   others cost little and make the 20 images alike. Section 6 is the case for it: Python is in nearly every image
   these models are otherwise run in, including the one vendor image that has Elixir.
3. **Say what is there.** One sentence in the task instructions, for example: "The container has bash, git, ripgrep,
   GNU grep, sed, perl, python3, make and gcc; there is no network and no sudo." If the images stay as they are, the
   same sentence saying "no Python" would save the failed call.
4. **Name the tests that fail in the container before any change**, per case, in the task details, or make them
   pass: build Accent's `index.html` and seed its languages, set Operately's missing setting.
5. **The time limit.** The tool's description already says seconds, so the remedy is in the harness: treat a value
   above the hang guard as the hang guard instead of letting Pi refuse it.
6. **Set `LANG=C.UTF-8` in the Alpine cases**, as the other 17 have it. No error was traced to its absence.
7. **Claude Code only:** create the scratchpad folder in the container before the attempt starts.

## Limits

- **No controlled comparison was run.** The logs show what each failure cost at the point it happened. They cannot
  show what an agent with Python would have done differently later in the same attempt. Only repeated runs of the
  same model on images with and without Python would measure the effect on pass rates, and with 20 cases an effect
  of a few points needs several runs per side to see. No published comparison of that kind was found either (6.4).
- **The parser is rough.** `shparse.py` finds programs by position, not by parsing bash. It was checked against the
  `command not found` messages in the outputs: 117 of the 126 Python calls in the Pi runs show the message, 8 hid
  it, and 1 only asked whether Python exists.
- **The image inventory** is from the images on this machine for run `20261118-211234-9347bf7b`. The runs made on
  the second controller built their images from the same recipe; they were not probed.
- **v5 local-model runs** have no saved logs and are not covered.
- **The desktop counts** come from one person's sessions, and say what Claude does there, not what other models do.

## How to repeat

From the repository root:

```bash
python3 docs/research/agent-environment-gaps-2026-11-19/measure.py verification counts.json
```

It prints the tables of sections 2, 3 and 4 and writes every Python call to `counts.json`. The script's header
states the rules. It reads `image-inventory.json`, which was written from the output of `probe.sh`, run in each
case's agent image like this:

```bash
docker run --rm --network=none --cap-drop=ALL -i <agent image> sh -s < probe.sh
```

`baseline.sh <agent image> <postgres snapshot image or -> <mix test arguments>` runs tests on an untouched image
with the sandbox's limits. The two Pinchflat rows of 4.1 came from the same `docker run` with the `/tmp` options
shown there. Section 5 was counted from session files that are not in this repository and cannot be repeated from
it.
