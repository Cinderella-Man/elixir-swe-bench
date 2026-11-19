# What coding-agent harnesses expect on the command line, and what their usual environments provide

Primary-source notes. Everything below was fetched on **2026-11-19**. Repository files are cited at the commit that was `HEAD` that day (commit date in brackets). Docs pages have no version, so the fetch date is the version.

Confidence legend: **High** = read directly in the cited file/page. **Medium** = read directly, but the source is a reference/example rather than the thing actually shipped, or the page may lag the product. **Inferred** = my reasoning from a primary source, not stated by it.

Quotes are kept short. Package lists are verbatim.

---

## 1. Claude Code

### 1a. What it bundles or requires on the machine

| Claim | Source | Confidence |
|---|---|---|
| Supported OS list includes Ubuntu 20.04+, Debian 10+, **Alpine Linux 3.19+**. Shell requirement: "Bash, Zsh, PowerShell, or CMD". | https://code.claude.com/docs/en/setup (System requirements) | High |
| **ripgrep**: "usually included with Claude Code". **Git**: "optional" (only version-gated features need 2.31+). | same page, "Additional dependencies" | High |
| **Alpine/musl, current text**: the install command needs `bash` and `curl`; "Claude Code itself requires `bash` or `zsh`"; Alpine has neither by default. Example: `apk add bash curl`. | https://code.claude.com/docs/en/setup#alpine-linux-and-musl-based-distributions | High |
| **Alpine/musl, earlier text (archived 2026-05-01)**: the native installer on musl/uClibc distributions "requires `libgcc`, `libstdc++`, and `ripgrep`"; example `apk add libgcc libstdc++ ripgrep`; then set `USE_BUILTIN_RIPGREP` to `0`. This wording is **gone from the live page** as of 2026-11-19. | http://web.archive.org/web/20260501052305/https://code.claude.com/docs/en/setup.md | High (for that date) |
| If search fails, the bundled `ripgrep` "may not run on your system": install the distro package (`apk add ripgrep` on Alpine, community repo) and set `USE_BUILTIN_RIPGREP=0`. `claude doctor` then shows the system path instead of `OK (bundled)`. | https://code.claude.com/docs/en/troubleshooting#search-and-discovery-issues | High |
| `USE_BUILTIN_RIPGREP`: "Set to `0` to use system-installed `rg` instead of `rg` included with Claude Code". | https://code.claude.com/docs/en/env-vars | High |
| `CLAUDE_CODE_SHELL` accepts only a `bash` or `zsh` path; other shells "are not supported". Auto-detection: `$SHELL` if bash/zsh, else first working `zsh` then `bash`. | https://code.claude.com/docs/en/env-vars | High |
| Prebuilt binaries exist for `linux-x64-musl` and `linux-arm64-musl` (plus glibc, darwin, win32). npm install needs Node.js 18+ (archived May 2026 page). | https://code.claude.com/docs/en/setup ; archive link above | High |
| Python is **not** a requirement anywhere on the setup page. | same | High (absence) |

### 1b. Reference devcontainer Dockerfile (`anthropics/claude-code`)

Source: https://github.com/anthropics/claude-code/blob/5b0e5f0b2a1ab83e6eed885433680361c621839d/.devcontainer/Dockerfile (HEAD 2026-11-19). Confidence: High.

- Base: `FROM node:20`
- apt packages, verbatim: `less git procps sudo fzf zsh man-db unzip gnupg2 gh iptables ipset iproute2 dnsutils aggregate jq nano vim`
- Extra: `git-delta` 0.18.2 (.deb via `wget`), `zsh-in-docker` 1.2.0, `npm install -g @anthropic-ai/claude-code`, `ENV SHELL=/bin/zsh`, `EDITOR=nano`.
- **Not listed**: `python3`, `ripgrep`, `curl`, `build-essential`.
- Inferred: Python 3 is very likely present anyway. `node:<major>` full images are `FROM buildpack-deps:bookworm` (checked for 22 and 24: https://github.com/nodejs/docker-node/blob/3d4f27f44ca5014b057dcf54e36b6cb1dda78bb6/22/bookworm/Dockerfile ; the `20/` directory is no longer on `main`), and `buildpack-deps:bookworm-scm` installs `git mercurial openssh-client subversion procps` (https://github.com/docker-library/buildpack-deps/blob/fb12875aa41571f6288d524576174843fe738995/debian/bookworm/scm/Dockerfile). Mercurial is a Python program, so it pulls Python 3 in. **Not verified by running the image.**
- The docs call this devcontainer "a working example rather than a maintained base" (https://code.claude.com/docs/en/devcontainer).

Related, and more telling than the devcontainer: **Claude Code cloud sessions** ship this pre-installed set (https://code.claude.com/docs/en/cloud-environments#installed-tools, High):

| Category | Included |
|---|---|
| Python | Python 3.x with pip, poetry, uv, black, mypy, pytest, ruff |
| Node.js | 20, 21, 22 with npm, yarn, pnpm, bun, eslint, prettier, chromedriver |
| Ruby | 3.1, 3.2, 3.3 with gem, bundler, rbenv |
| PHP | 8.3 with Composer |
| Java | OpenJDK 21 with Maven and Gradle |
| Go / Rust / C/C++ | Go; rustc, cargo; GCC, Clang, cmake, ninja, conan |
| Docker / DBs / Browser | docker, compose; PostgreSQL 16, Redis 7.0; Chrome for Testing |
| Utilities | git, gh, jq, yq, ripgrep, tmux, vim, nano |

No Elixir/Erlang in that list.

### 1c. Which shell tools Claude is steered toward or away from

| Claim | Source | Confidence |
|---|---|---|
| On macOS, Linux and WSL the `Glob` and `Grep` tools are **absent by default**; Claude "searches with `find` and `grep` through the Bash tool", and in Claude's shell those two commands run **embedded `bfs` and `ugrep`**. They return when `Bash` is removed or when named in `--tools`/`--allowedTools`. | https://code.claude.com/docs/en/tools-reference#glob-tool-behavior | High |
| Changelog 2.1.117: native builds on macOS and Linux replaced `Glob`/`Grep` with embedded `bfs` and `ugrep` reached through Bash; Windows and npm-installed builds unchanged. | https://github.com/anthropics/claude-code/blob/5b0e5f0b2a1ab83e6eed885433680361c621839d/CHANGELOG.md | High |
| The `Grep` tool, when present, "is built on ripgrep" and uses ripgrep regex syntax. | https://code.claude.com/docs/en/tools-reference#grep-tool-behavior | High |
| `Edit` "performs exact string replacement"; no regex or fuzzy matching; `old_string` must match exactly and be unique unless `replace_all`. Read-before-edit is enforced. | https://code.claude.com/docs/en/tools-reference#edit-tool-behavior | High |
| Bash commands that count as "viewing" a file for the read-before-edit check: `cat`, `nl`, `bat`, `batcat`, `head`, `tail`, `sed -n 'X,Yp'`, `grep`, `egrep`, `fgrep`, `rg`. This is the set of file-viewing commands the harness anticipates. | same section | High |
| Bash tool: each command runs in a separate process; env vars do not persist; a non-interactive bash/zsh sources `~/.bashrc`/`~/.zshrc`. | https://code.claude.com/docs/en/tools-reference#bash-tool-behavior | High |
| Observed, no public URL: the Bash tool description delivered to the model in a live Claude Code / Agent SDK session (2026-11-19) tells it to avoid `cat`, `head`, `tail`, `sed`, `awk`, `echo` in favour of the dedicated tools. Anthropic does not publish the Claude Code system prompt, so this cannot be linked. | live session observation | Medium (not citable) |

Not found: any official Claude Code text that mentions Python as an editing fallback, for or against.

---

## 2. OpenAI Codex CLI

Repo: `openai/codex` at `dabe0643a4876ed94adbea3101d40228c96264a9` (2026-11-19).

### 2a. What the model prompt files say about tools

| Claim | Source | Confidence |
|---|---|---|
| Base instructions: "Use the `apply_patch` tool to edit files". | [`codex-rs/protocol/src/prompts/base_instructions/default.md` L132](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/protocol/src/prompts/base_instructions/default.md#L132) | High |
| Base instructions, "Shell commands": prefer `rg` / `rg --files` over `grep`; "(If the `rg` command is not found, then use alternatives.)" Next line: "Do not use python scripts to attempt to output larger chunks of a file." | [same file L264-L265](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/protocol/src/prompts/base_instructions/default.md#L264-L265) | High |
| GPT-5.2 prompt adds: parallelise reads "such as `cat`, `rg`, `sed`, `ls`, `git show`, `nl`, `wc`". This is the read-side command vocabulary the prompt assumes. | [`codex-rs/core/gpt_5_2_prompt.md` L250-L252](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/core/gpt_5_2_prompt.md#L250-L252) | High |
| Codex-tuned prompts (`gpt_5_codex`, `gpt-5.1-codex-max`, `gpt-5.2-codex`): try `apply_patch` for single-file edits but "it is fine to explore other options"; do not use it "when scripting is more efficient (such as search and replacing a string across a codebase)". So scripted edits are explicitly sanctioned. | [`codex-rs/core/gpt-5.2-codex_prompt.md` L5, L11](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/core/gpt-5.2-codex_prompt.md#L5-L11) | High |
| Current model catalogue (`gpt-5.5`, `gpt-5.6-*`): "Use `apply_patch` for manual code edits. Do not create or edit files with `cat` or other shell write tricks." and "**Do not use Python to read or write files when a simple shell command or `apply_patch` is enough.**" | [`codex-rs/models-manager/models.json`](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/models-manager/models.json), field `model_messages.instructions_template` per slug | High |
| `gpt-6*` entries run in `tool_mode: code_mode_only`; their template keeps the `rg` line but has no `apply_patch`/Python line (tools are called from a JS `functions.exec` wrapper). | same file | High |
| All catalogue entries: `apply_patch_tool_type: freeform`, `shell_type: shell_command`. | same file | High |

OpenAI felt the need to write "do not use Python to read or write files" into the shipped prompt. That is primary evidence that GPT-5.x models reach for Python file I/O by default.

### 2b. What Codex itself bundles

| Claim | Source | Confidence |
|---|---|---|
| The package builder vendors ripgrep: "ripgrep is required for all package targets"; manifest pins ripgrep 15.2.0. | [`scripts/codex_package/ripgrep.py`](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/scripts/codex_package/ripgrep.py), [`scripts/codex_package/rg`](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/scripts/codex_package/rg) | High |
| `apply_patch` is built in (Rust crate `codex-rs/apply-patch`), exposed as a freeform tool with a Lark grammar. Nothing has to be installed in the workspace. | [`codex-rs/core/src/tools/handlers/apply_patch_spec.rs` L20](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/core/src/tools/handlers/apply_patch_spec.rs#L20) | High |
| Codex also recognises `apply_patch` invoked through `bash`/`zsh`/`sh` with `-lc`/`-c` and a heredoc. | [`codex-rs/apply-patch/src/invocation.rs` L62-L65](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-rs/apply-patch/src/invocation.rs#L62-L65) | High |
| Linux binaries are musl targets (`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`). | [`codex-cli/bin/codex.js`](https://github.com/openai/codex/blob/dabe0643a4876ed94adbea3101d40228c96264a9/codex-cli/bin/codex.js) | High |

### 2c. `openai/codex-universal` image

Repo at `47f4f0eb5337083e2f610db0d15558932cb4901d` (2026-05-02). README: "reference implementation of the base Docker image available in OpenAI Codex"; "not an identical environment". Confidence: High for the file, Medium as a description of the real Codex cloud image.

- Dockerfile: https://github.com/openai/codex-universal/blob/47f4f0eb5337083e2f610db0d15558932cb4901d/Dockerfile
- README: https://github.com/openai/codex-universal/blob/47f4f0eb5337083e2f610db0d15558932cb4901d/README.md

Base `ubuntu:24.04`. First apt layer, verbatim package names (version pins dropped):

`binutils sudo build-essential bzr curl default-libmysqlclient-dev dnsutils fd-find gettext git git-lfs gnupg inotify-tools iputils-ping jq libbz2-dev libc6 libc6-dev libcurl4-openssl-dev libdb-dev libedit2 libffi-dev libgcc-13-dev libgdbm-compat-dev libgdbm-dev libgdiplus libgssapi-krb5-2 liblzma-dev libncurses-dev libnss3-dev libpq-dev libpsl-dev libpython3-dev libreadline-dev libsqlite3-dev libssl-dev libstdc++-13-dev libunwind8 libuuid1 libxml2-dev libz3-dev make moreutils netcat-openbsd openssh-client pkg-config protobuf-compiler ripgrep rsync software-properties-common sqlite3 swig3.0 tk-dev tzdata universal-ctags unixodbc-dev unzip uuid-dev wget xz-utils zip zlib1g zlib1g-dev`

Then: `mise`; LLVM plus `cmake ccache ninja-build nasm yasm gawk lsb-release`; language runtimes:

| Runtime | Versions | Extras |
|---|---|---|
| **Python** (pyenv) | 3.14 3.13 3.12 3.11 3.10 | pipx, poetry, uv, ruff, black, mypy, pyright, isort, pytest |
| Node (nvm) | 18 20 22 24, default 22 | npm, pnpm, yarn, prettier, eslint, typescript |
| Bun | 1.2.14 | |
| Java (mise) | 25 24 23 22 21 17 (11 on amd64) | gradle 8.14, maven 3.9.10 |
| Swift | 6.2 6.1 5.10 | |
| Rust | 1.83.0 to 1.95.0 | rustfmt, clippy |
| Ruby | 3.4.4 3.3.8 3.2.3 | |
| Go | 1.25.1 1.24.3 1.23.8 1.22.12 | golangci-lint |
| PHP | 8.5 8.4 8.3 8.2 | composer |
| **Erlang / Elixir** (mise) | **Erlang 27.1.2, Elixir 1.18.3-otp-27** | none |
| Bazel | bazelisk 1.26.0 | |

Answers: **Python is there** (five versions). **Elixir and Erlang are there** (Dockerfile L312-L313 and README "What's included"), installed beside Python, `ripgrep`, `fd-find`, `jq`, `git`. So the Elixir environment a Codex model normally sees has Python and `rg`.

Also OpenAI's **hosted shell** container: "based on `Debian 12`"; preinstalled Python 3.11, Node.js 22.16, Java 17.0, PHP 8.2, Ruby 3.1, Go 1.23 (https://developers.openai.com/api/docs/guides/tools-shell, "Hosted runtime details", High).

---

## 3. Pi coding agent

Repo: `github.com/badlogic/pi-mono` now redirects to **`github.com/earendil-works/pi`** (same HEAD `653f332b6fe22e2e927dd3d553d20234a3de27f0`, 2026-11-19). npm package is now **`@earendil-works/pi-coding-agent`**, version `1.5.2` (`packages/coding-agent/package.json`). I did not check whether `@mariozechner/pi-coding-agent` is still published or what version it carries. All line numbers below are for this commit; an older or forked build may differ.

Base URL for links: `https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/`

| Claim | Source | Confidence |
|---|---|---|
| **Default tools**: `read`, `bash`, `edit`, `write` (unless `defaultTools` changes them). | [`docs/cli.md` L130](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/docs/cli.md#L130); `createCodingTools` in [`src/core/tools/index.ts`](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/tools/index.ts) | High |
| **All built-ins**: `read`, `bash`, `powershell`, `edit`, `write`, `grep`, `find`, `ls`. `grep`/`find`/`ls` are opt-in via `--tools` (for example `--tools read,grep,find,ls`, or `+grep`). | `docs/cli.md` L116-L151; `allToolNames` in `tools/index.ts` | High |
| **System prompt** preamble: "You are a coding assistant running inside pi, a coding agent harness." Tools are listed one line each. | [`src/core/system-prompt.ts` L156](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/system-prompt.ts#L156) | High |
| When bash is on and none of grep/find/ls are, the prompt adds the rule: **"Use bash for file operations like ls, rg, find"**. The default prompt therefore names `rg` as if it exists. | [`system-prompt.ts` L114](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/system-prompt.ts#L114) | High |
| Per-tool prompt lines: bash "Execute bash commands (ls, grep, find, etc.)"; read "Use read to examine files instead of cat or sed."; write "Use write only for new files or complete rewrites."; edit "Use edit for targeted changes. Batch changes to one file in a single call." | `src/core/tools/bash.ts` L45, `read.ts` L22, `write.ts` L17, `edit.ts` (`editToolSystemPromptContribution`) | High |
| The prompt says nothing about Python, `sed`-for-editing, or what to do if a tool is missing. | `system-prompt.ts` whole file | High (absence) |
| **`grep` depends on `rg`**, **`find` depends on `fd`**; `ls` is pure Node (`fs.readdir`). | `tools/grep.ts` L131-L133, `tools/find.ts` L177-L183, `tools/ls.ts` | High |
| `rg`/`fd` resolution order: pi's own bin dir (`~/.pi/agent/bin`), then system `PATH` (`fd` or `fdfind`; `rg`), else **download the latest GitHub release** (`sharkdp/fd`, `BurntSushi/ripgrep`; Linux assets are `*-unknown-linux-musl.tar.gz`, x64 and arm64 only). | [`src/utils/tools-manager.ts` L33-L59, L72-L90, L337-L398](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/utils/tools-manager.ts) | High |
| Interactive mode fetches both at startup: "fd for autocomplete, rg for grep tool and bash commands". The managed bin dir is prepended to `PATH` for the bash tool, so a downloaded `rg` is reachable from bash commands on the machine where pi runs. | [`src/modes/interactive/interactive-mode.ts` L1127-L1133](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L1127-L1133); `src/utils/shell.ts` L172-L177 | High |
| Inferred: I only saw the startup download in interactive mode. In print/JSON/RPC mode the download would happen lazily on the first `grep`/`find` call. Not traced end to end. | same files | Inferred |
| **`--offline` / `PI_OFFLINE`** (`1`/`true`/`yes`): docs say it "Disables automatic network activity, including model catalog refreshes". In code it also sets `PI_SKIP_VERSION_CHECK=1`, skips package-update checks and install telemetry, and **skips the `rg`/`fd` download**: status "`<tool>` not found. Offline mode enabled, skipping download." | `docs/cli.md` L243-L244; `src/main.ts` L610-L613; `tools-manager.ts` L15-L19, L349-L352; `interactive-mode.ts` L1191, L1298, L1466 | High |
| Offline with no system binary: the `grep` tool fails with **"ripgrep (rg) is not available and could not be downloaded"**; `find` fails with **"fd is not available and could not be downloaded"**. A bash `rg ...` just gets the shell's command-not-found. | `tools/grep.ts` L133; `tools/find.ts` L183 | High (bash part Inferred) |
| **bash tool shell**: `/bin/bash`, else `bash` on `PATH`, else falls back to **`sh -c`**. | [`src/utils/shell.ts` L128-L138](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/utils/shell.ts#L128-L138) | High |
| Pi's own example container: `FROM node:24-bookworm-slim` plus `bash ca-certificates git ripgrep`. No Python. | [`docs/containerization.md` L38-L49](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/docs/containerization.md#L38-L49) | High |
| Pi needs Node.js 22.19+ on the machine where it runs. | `packages/coding-agent/README.md` | High |

### `edit` tool matching

Sources: [`src/core/tools/edit.ts`](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/tools/edit.ts), [`src/core/tools/edit-diff.ts`](https://github.com/earendil-works/pi/blob/653f332b6fe22e2e927dd3d553d20234a3de27f0/packages/coding-agent/src/core/tools/edit-diff.ts). Confidence: High.

- Schema: `{ path, edits: [{ oldText, newText }, ...] }`. Every `oldText` is matched against the **original** file, not incrementally. Legacy top-level `oldText`/`newText` is still accepted, as is `edits` sent as a JSON string or a single object (code comment names "Opus 4.6, GLM-5.1").
- Matching is **exact first, then a narrow fuzzy fallback** (`fuzzyFindText`, L250-L288). The fallback (`normalizeForFuzzyMatch`, L77-L98) applies Unicode NFKC, strips **trailing** whitespace per line, and maps smart quotes, Unicode dashes and special spaces to ASCII. CRLF is normalised to LF and a BOM is stripped before matching.
- It does **not** tolerate leading-whitespace/indentation differences, missing lines, or approximate text. No edit distance, no regex.
- Errors (exact strings):
  - no match, one edit: `Could not find the exact text in <path>. The old text must match exactly including all whitespace and newlines.`
  - no match, several edits: `Could not find edits[<i>] in <path>. The oldText must match exactly including all whitespace and newlines.`
  - duplicate: `Found <n> occurrences of the text in <path>. The text must be unique. Please provide more context to make it unique.`
  - overlap: `edits[<a>] and edits[<b>] overlap in <path>. Merge them into one edit or target disjoint regions.`
  - identical result: `No changes made to <path>. The replacement produced identical content. ...`
  - empty: `oldText must not be empty in <path>.`
  - file missing/unwritable: `Could not edit file: <path>. Error code: <code>.`
- Success: `Successfully replaced <n> block(s) in <path>.`
- The no-match error does not show the nearest candidate or the file's actual text, so the model gets no hint about what differed.

---

## 4. Other agent scaffolds

### SWE-agent (with SWE-ReX)

`SWE-agent/SWE-agent` at `3ea751c087f32b16e039a2233dd6eefecef325d5` (2026-07-16); `SWE-agent/SWE-ReX` at `5c995c365dfb1fd5bc56fda688be5d8538f9931f` (2026-03-02). The README now recommends mini-SWE-agent instead.

| Claim | Source | Confidence |
|---|---|---|
| Default config bundles: `tools/registry`, `tools/edit_anthropic`, `tools/review_on_submit_m`, plus the bash tool. Header comment: "heavily inspired by anthropic's computer use demo". | [`config/default.yaml`](https://github.com/SWE-agent/SWE-agent/blob/3ea751c087f32b16e039a2233dd6eefecef325d5/config/default.yaml) | High |
| **The edit tools are Python scripts run inside the task container.** `tools/edit_anthropic/bin/str_replace_editor` starts `#!/usr/bin/env python3`; so do `windowed/bin/open`, `windowed_edit_replace/bin/edit`, `review_on_submit_m/bin/submit`, `diff_state/bin/_state_diff_state`. `registry/bin/_read_env` and `_write_env` use `#!/usr/bin/env python`. `filemap` hardcodes `#!/root/miniconda3/bin/python`. Of the scripts I opened, only `search/find_file`, `search/search_dir` and `submit/submit` are shell. | [`tools/`](https://github.com/SWE-agent/SWE-agent/tree/3ea751c087f32b16e039a2233dd6eefecef325d5/tools) | High |
| `edit_anthropic/install.sh` runs `pip install 'tree-sitter==0.21.3'` and `tree-sitter-languages` (failures ignored). | [`tools/edit_anthropic/install.sh`](https://github.com/SWE-agent/SWE-agent/blob/3ea751c087f32b16e039a2233dd6eefecef325d5/tools/edit_anthropic/install.sh) | High |
| **It installs Python itself.** Default deployment is `DockerDeploymentConfig(image="python:3.11", python_standalone_dir="/root")`. With `python_standalone_dir` set, SWE-ReX builds a derived image: compiles Python 3.11.8 in a `python:3.11.9-slim-bookworm` builder stage, copies it to `/root/python3.11`, `pip3 install swe-rex`, symlinks `swerex-remote`. Comment: "will only work with glibc-based systems". The production stage also runs `apt-get`, so Debian/Ubuntu only. | [`sweagent/environment/swe_env.py` L28](https://github.com/SWE-agent/SWE-agent/blob/3ea751c087f32b16e039a2233dd6eefecef325d5/sweagent/environment/swe_env.py#L28); [`swerex/deployment/docker.py` L120-L193](https://github.com/SWE-agent/SWE-ReX/blob/5c995c365dfb1fd5bc56fda688be5d8538f9931f/src/swerex/deployment/docker.py#L120-L193) | High |
| Without a standalone dir, the start command is `swerex-remote ... \|\| (python3 -m pip install pipx && python3 -m pipx ensurepath && pipx run swe-rex ...)`. That needs `python3` and network. | same file L120-L126 | High |
| For non-Python repos, the `multilingual_setup` bundle adds `/root/python3.11/bin` to `PATH` and symlinks `python`/`pip` **only if no `python` exists**. So in SWE-agent multilingual runs the model can call `python`. | [`tools/multilingual_setup/install.sh`](https://github.com/SWE-agent/SWE-agent/blob/3ea751c087f32b16e039a2233dd6eefecef325d5/tools/multilingual_setup/install.sh); [`config/benchmarks/anthropic_filemap_multilingual.yaml`](https://github.com/SWE-agent/SWE-agent/blob/3ea751c087f32b16e039a2233dd6eefecef325d5/config/benchmarks/anthropic_filemap_multilingual.yaml) | High |
| Default prompt tells the model to "Create a script to reproduce the error and execute it with `python <filename.py>`". | `config/default.yaml` | High |

Needs Python in the container: **yes**. Installs it: **yes** (standalone build, glibc + apt only).

### mini-swe-agent

`SWE-agent/mini-swe-agent` at `04d809ceab9df28f9adaed044884180159172930` (2026-09-03).

| Claim | Source | Confidence |
|---|---|---|
| "Does not have any tools other than bash"; in sandboxes "all it needs is bash". | [`README.md` L42-L44](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/README.md#L42-L44); `docs/faq.md` L34 | High |
| Docker environment runs each action as `docker exec ... bash -lc <command>` (`interpreter: ["bash", "-lc"]`, configurable). Nothing is installed in the container. | [`src/minisweagent/environments/docker.py` L38, L107-L113](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/environments/docker.py#L38) | High |
| Default prompts teach shell editing: create files with `cat <<'EOF' > file`, "Edit files with sed" (`sed -i 's/old/new/g'`), view with `nl -ba file \| sed -n '10,20p'`. | [`config/default.yaml` L63-L96](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/config/default.yaml#L63-L96); `config/mini.yaml` | High |
| The SWE-bench config drops those examples: any bash command or available tool, "you can also install it" if missing, no `vi`/`nano`. | [`config/benchmarks/swebench.yaml` L70-L73](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/config/benchmarks/swebench.yaml#L70-L73) | High |

Needs Python in the container: **no**. Installs anything: **no**. The model has no edit tool, so every edit is `sed`, a heredoc, or a script in whatever interpreter the image has. On SWE-bench images that interpreter is Python.

### OpenHands

Current architecture (V1): `OpenHands/software-agent-sdk` at `45cf668c5e2af38c6cc8c2eb6ae4f0d6f828e4c3` (2026-11-19); `OpenHands/benchmarks` at `60b3548cea8b41276ac0d44ea36a01b82936bbe4` (2026-11-09); `OpenHands/docs` at `4959c30a96773e3a0bcf26d9e22cd194a4494450`. `OpenHands/OpenHands` is now the UI repo.

| Claim | Source | Confidence |
|---|---|---|
| The sandbox **is** the agent-server, layered onto `BASE_IMAGE`. Minimal layer installs, on apt: `bash ca-certificates git tini tmux`; on apk: `bash ca-certificates git shadow tini tmux`; equivalents for dnf/yum/zypper. | [`openhands-agent-server/openhands/agent_server/docker/Dockerfile` L343-L384](https://github.com/OpenHands/software-agent-sdk/blob/45cf668c5e2af38c6cc8c2eb6ae4f0d6f828e4c3/openhands-agent-server/openhands/agent_server/docker/Dockerfile#L343-L384) | High |
| Full image adds, on apt: `apt-transport-https apt-utils build-essential coreutils curl findutils gnupg grep jq lsb-release procps sed sudo tar util-linux wget xz-utils`, plus optional VS Code, Docker, Chromium. | same file L464-L508 | High |
| **It ships its own Python and does not rely on the image's.** `source*` targets copy `/agent-server` holding a uv-managed Python 3.13 and venv ("self-contained /agent-server contract"); `binary*` targets copy a PyInstaller binary. | same file L186-L232, L703-L735 | High |
| Benchmarks default to target `source-minimal` on top of `docker.io/swebench/` images. | [`benchmarks/swebenchmultilingual/constants.py`](https://github.com/OpenHands/benchmarks/blob/60b3548cea8b41276ac0d44ea36a01b82936bbe4/benchmarks/swebenchmultilingual/constants.py) | High |
| Inferred: that private Python sits at `/agent-server/.venv/bin/python` and is not put on the agent's `PATH` by this Dockerfile, so a `python3` typed by the model resolves only if the base image has one. Not tested. | Dockerfile (no `ENV PATH` for the venv seen) | Inferred |
| Default tools: `TerminalTool`, `FileEditorTool`, `TaskTrackerTool` (+ browser). File editor commands: `view`, `create`, `str_replace`, `insert`, `undo_edit` (the Anthropic `str_replace_editor` shape). | [`openhands-tools/openhands/tools/preset/default.py` L56-L58](https://github.com/OpenHands/software-agent-sdk/blob/45cf668c5e2af38c6cc8c2eb6ae4f0d6f828e4c3/openhands-tools/openhands/tools/preset/default.py#L56-L58); [`file_editor/definition.py` L26](https://github.com/OpenHands/software-agent-sdk/blob/45cf668c5e2af38c6cc8c2eb6ae4f0d6f828e4c3/openhands-tools/openhands/tools/file_editor/definition.py#L26) | High |
| **Per-model-family edit tools**: GPT-5 preset swaps in `ApplyPatchTool` "instead of the default claude-style FileEditorTool"; Gemini preset uses `read_file`/`write_file`/`edit`/`list_directory`. | [`preset/gpt5.py`](https://github.com/OpenHands/software-agent-sdk/blob/45cf668c5e2af38c6cc8c2eb6ae4f0d6f828e4c3/openhands-tools/openhands/tools/preset/gpt5.py); [`preset/gemini.py`](https://github.com/OpenHands/software-agent-sdk/blob/45cf668c5e2af38c6cc8c2eb6ae4f0d6f828e4c3/openhands-tools/openhands/tools/preset/gemini.py) | High |
| Terminal tool auto-detects tmux, with a subprocess fallback. | `openhands-tools/openhands/tools/terminal/terminal/factory.py` | High |
| Legacy V0: OpenHands built an "OH runtime image" from the user image and installed its Python action-execution server there; default base `nikolaik/python-nodejs:python3.12-nodejs22`; custom images "must be Debian based". | [`openhands/usage/architecture/runtime.mdx`](https://github.com/OpenHands/docs/blob/4959c30a96773e3a0bcf26d9e22cd194a4494450/openhands/usage/architecture/runtime.mdx); [`V0_custom-sandbox-guide.mdx`](https://github.com/OpenHands/docs/blob/4959c30a96773e3a0bcf26d9e22cd194a4494450/openhands/usage/v0/advanced/V0_custom-sandbox-guide.mdx) | High |

Needs Python in the container: **yes** (its server and tools are Python). Installs it: **yes**, privately. Also installs `bash`, `git`, `tmux`, `tini`. The Dockerfile has an `apk` branch for Alpine bases; whether the copied Python or binary actually runs on musl was not checked.

### Aider

`Aider-AI/aider` at `5dc9490bb35f9729ef2c95d00a19ccd30c26339c` (2026-05-22).

- [`benchmark/Dockerfile`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/benchmark/Dockerfile): `FROM buildpack-deps:jammy`; apt `software-properties-common cmake libboost-all-dev`, then `python3.11 python3.11-venv python3.11-dev python3-pip ca-certificates-java openjdk-21-jdk libtbb-dev`; Go 1.21.5; Rust via rustup; Node.js 20 plus jest/babel/eslint packages; `pip3 install uv`; `uv pip install -e /aider[dev]`. Confidence: High.
- The benchmark "is intended to be run *inside a docker container*" ([`benchmark/README.md` L22](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/benchmark/README.md#L22)). Aider is a Python program and runs in the same container as the exercises.
- Aider gives the model **no shell and no edit tool**. Edits are parsed from the reply text: `whole`, `diff` (search/replace blocks), `diff-fenced` ("primarily used with the Gemini family"), `udiff` ("mainly used to the GPT-4 Turbo family") ([`aider/website/docs/more/edit-formats.md`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/website/docs/more/edit-formats.md)). So "falls back to Python for edits" cannot occur there.

Needs Python in the container: **yes** (Aider itself). Installs it: **yes**.

### Extra: Terminus 2 (Terminal-Bench default harness, cited by Anthropic and Google)

`laude-institute/harbor` at `a215bfa03ccc026d22a0f11d5d6c51a8a46f0510` (2026-11-18). The model sends raw `keystrokes` to a tmux session; no edit tool ([`templates/terminus-json-plain.txt`](https://github.com/laude-institute/harbor/blob/a215bfa03ccc026d22a0f11d5d6c51a8a46f0510/src/harbor/agents/terminus_2/templates/terminus-json-plain.txt)). The harness installs **tmux and asciinema** into the task container via apt/apk/dnf, or builds tmux from source ([`tmux_session.py` L101-L351](https://github.com/laude-institute/harbor/blob/a215bfa03ccc026d22a0f11d5d6c51a8a46f0510/src/harbor/agents/terminus_2/tmux_session.py#L101)). Confidence: High for the file; I did not read the rest of Harbor.

### Extra: what the standard evaluation images contain (SWE-bench)

`SWE-bench/SWE-bench` tag `v4.1.0` (`726c5461e2ef52d83cf1ea2107870a8bb3328d57`). On `main` (2026-09-02) these templates have moved and I did not locate the replacement. Files: https://github.com/SWE-bench/SWE-bench/tree/726c5461e2ef52d83cf1ea2107870a8bb3328d57/swebench/harness/dockerfiles . Confidence: High for v4.1.0.

| Template | Base | apt packages | Python? |
|---|---|---|---|
| Python (SWE-bench, Verified) | `ubuntu:{version}` | `wget git build-essential libffi-dev libtiff-dev python3 python3-pip python-is-python3 jq curl locales locales-all tzdata` + Miniconda | **yes** |
| C | `ubuntu:22.04` | `wget git build-essential libtool automake autoconf tcl bison flex cmake python3 python3-pip python3-venv python-is-python3` | **yes** |
| JavaScript | `ubuntu:{version}` | `build-essential curl git libssl-dev software-properties-common wget gnupg jq ca-certificates ...` + Chrome | not listed |
| Go | `ubuntu:{version}` | `wget git build-essential` | not listed |
| Rust | `rust:{version}` | `wget git build-essential` | not listed (Inferred present: official `rust` image is buildpack-deps based) |
| Ruby | `ruby:{version}` | `wget git build-essential jq` | not listed (Inferred present, same reason) |
| Java | `maven:3.9-eclipse-temurin-{v}` | `wget git build-essential ant unzip` | not listed |
| PHP | `php:{version}` | `wget git build-essential libgd-dev libzip-dev ...` | not listed |

None installs `ripgrep`. The Go template comment says old golang images "can cause problems with agent installations", for example old glibc.

---

## 5. Published vendor guidance on the tool environment

### Anthropic: bash tool plus string-replace edit tool

| Claim | Source | Confidence |
|---|---|---|
| SWE-bench scaffold for Claude 3.5 Sonnet: "a prompt, a Bash Tool ... and an Edit Tool". Edit tool is `str_replace_editor` with `view`, `create`, `str_replace`, `insert`, `undo_edit`; absolute paths required; replacement happens only "if there is exactly one match of `old_str`", otherwise an error for retry. They tried several edit strategies and string replacement was the most reliable. | https://www.anthropic.com/engineering/swe-bench-sonnet (page dated Jan 6, 2025; redirects to `/research/swe-bench-sonnet`) | High |
| The same post's task prompt: "I've uploaded a python code repository"; the environment is a "set up Python environment". | same | High |
| Claude 3.7 Sonnet: same two tools, plus a "planning tool". | https://www.anthropic.com/news/claude-3-7-sonnet (appendix) | High |
| Claude 4: the same scaffold with only two tools, bash and a file editor "that operates via string replacements"; planning tool dropped. | https://www.anthropic.com/news/claude-4 (appendix) | High |
| Claude Sonnet 4.5: "a simple scaffold with two tools—bash and file editing via string replacements". Terminal-Bench used Terminus 2. | https://www.anthropic.com/news/claude-sonnet-4-5 (Methodology) | High |
| API bash tool `bash_20250124` and text editor tool `text_editor_20250728` (`str_replace_based_edit_tool`) are "schema-less": the schema "is built into Claude's model and can't be modified". `str_replace`'s `old_str` "must match exactly, including whitespace and indentation". | https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool ; https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool | High |
| Not checked: methodology notes for Claude models released after Sonnet 4.5 (the Opus 4.5 post has no such scaffold sentence in its main text; I did not open the system cards). | n/a | Not verified |

Editing mechanism Claude is used to: **exact, unique string replacement through a dedicated tool**, with bash alongside, in Python-equipped images.

### OpenAI: `apply_patch` (V4A diff) plus a terminal

| Claim | Source | Confidence |
|---|---|---|
| GPT-4.1 guide publishes "a reference implementation of the apply_patch tool that we used as part of model training", to be made "available as `apply_patch` from the shell". | https://github.com/openai/openai-cookbook/blob/dfd760b4de0bd175b51ad05b9b5260c36dfea09c/examples/gpt4-1_prompting_guide.ipynb | High |
| **The GPT-4.1 SWE-bench sample harness is a single `python` tool**: it executes "Python code or terminal commands in a stateful Jupyter notebook environment"; shell commands are prefixed with `!`; `apply_patch` goes through the same tool. | same notebook (`PYTHON_TOOL_DESCRIPTION`) | High |
| GPT-5 guide: use `apply_patch` for file edits "to match the training distribution". | https://github.com/openai/openai-cookbook/blob/dfd760b4de0bd175b51ad05b9b5260c36dfea09c/examples/gpt-5/gpt-5_prompting_guide.ipynb | High |
| The reference `apply_patch` implementation is itself a **Python script**. | https://github.com/openai/openai-cookbook/blob/dfd760b4de0bd175b51ad05b9b5260c36dfea09c/examples/gpt-5/apply_patch.py | High |
| GPT-5.1 guide: the model "has been post-trained on specific tools": a predefined `apply_patch` tool and a `shell` tool. | https://github.com/openai/openai-cookbook/blob/dfd760b4de0bd175b51ad05b9b5260c36dfea09c/examples/gpt-5/gpt-5-1_prompting_guide.ipynb | High |
| Codex guide (names `gpt-5.3-codex`): use "our exact `apply_patch` implementation as the model has been trained to excel at this diff format"; the model "was primarily trained using a dedicated terminal tool"; wrapper tools work best when they mirror the underlying command. | https://github.com/openai/openai-cookbook/blob/dfd760b4de0bd175b51ad05b9b5260c36dfea09c/examples/gpt-5/codex_prompting_guide.ipynb | High |
| API `apply_patch` tool: operations `create_file`, `update_file`, `delete_file` carrying V4A diffs; your harness applies them. | https://developers.openai.com/api/docs/guides/tools-apply-patch | High |

Editing mechanism GPT models are used to: **`apply_patch` with the V4A format**, in a shell that has Python (the 4.1-era harness was literally a Python/Jupyter tool). Without `apply_patch`, the documented default it must be told not to use is Python file I/O (section 2a).

### Google: bash plus file-operation tools; Gemini CLI `replace`

| Claim | Source | Confidence |
|---|---|---|
| Gemini 3.1 Pro SWE-bench scaffolding: single attempt, made of three things: a bash tool for shell commands, "file operation tools" for editing and undoing, and a submit tool. Terminal-Bench 2.0 on Terminus 2. | https://storage.googleapis.com/deepmind-media/gemini/gemini_3-1_pro_model_evaluation.pdf (Published February 2026), linked from https://deepmind.google/models/model-cards/gemini-3-1-pro/ | High |
| Gemini CLI file tools: `glob`, `grep_search`, `list_directory`, `read_file`, `read_many_files`, `replace` (`file_path`, `old_string`, `new_string`, `instruction`, `allow_multiple`), `write_file`; shell is `run_shell_command`. `replace` needs exact literal text and exactly one occurrence unless `allow_multiple`. | [`docs/reference/tools.md`](https://github.com/google-gemini/gemini-cli/blob/acfb42d0dfc111fd1d5c5d45535daf6aa7d8696b/docs/reference/tools.md); [`docs/tools/file-system.md`](https://github.com/google-gemini/gemini-cli/blob/acfb42d0dfc111fd1d5c5d45535daf6aa7d8696b/docs/tools/file-system.md) | High |
| Gemini CLI sandbox image: `node:20-slim` plus `python3 make g++ man-db curl dnsutils less jq bc gh git unzip rsync ripgrep procps psmisc lsof socat ca-certificates`. **Python and ripgrep are included.** | [`Dockerfile` L49-L68](https://github.com/google-gemini/gemini-cli/blob/acfb42d0dfc111fd1d5c5d45535daf6aa7d8696b/Dockerfile#L49-L68) | High |
| Gemini CLI vendors ripgrep binaries (`packages/core/vendor/ripgrep/rg-linux-x64`, etc.). | repo tree at the same commit | High |
| Which file tools the internal SWE-bench scaffold exposes by name: not published. | n/a | Not found |

### Qwen / Alibaba

| Claim | Source | Confidence |
|---|---|---|
| Qwen3-Coder: trained with long-horizon agent RL in "20,000 independent environments in parallel"; Qwen Code is "forked from Gemini Code" with adapted prompts and function-calling protocols; also promoted for use with Claude Code. Tool set of the RL environments: not described. | https://qwenlm.github.io/blog/qwen3-coder/ | High |
| **Qwen3-Coder-Next technical report (Qwen Team, arXiv 2603.00729v1)**: agentic training trajectories were generated with six agent frameworks: SWE-agent, Mini-SWE-agent, OpenHands, Claude-Code, Qwen-Code and Terminus; "cross-scaffold transfer remains limited"; trained on 21 tool chat templates; reports SWE-bench Verified under SWE-Agent, MiniSWE-Agent and OpenHands scaffolds. | https://arxiv.org/html/2603.00729v1 | High |
| Qwen Code tool names: `edit` (`old_string`, `new_string`, `replace_all`), `write_file`, `read_file`, `grep_search`, `glob`, `list_directory`, `run_shell_command`, `todo_write`, ... `grep_search` uses ripgrep "when available", else a JS fallback. | [`packages/core/src/tools/tool-names.ts`](https://github.com/QwenLM/qwen-code/blob/d79bb9b712119392a3df0174054120e6ab54cb97/packages/core/src/tools/tool-names.ts); [`docs/developers/tools/file-system.md`](https://github.com/QwenLM/qwen-code/blob/d79bb9b712119392a3df0174054120e6ab54cb97/docs/developers/tools/file-system.md) | High |
| Qwen Code `edit`: exact literal `old_string`; if not found, a "multi-stage edit correction" can ask the model to refine it before failing. | same docs file, section 7 | High |
| Qwen Code sandbox image: `node:22-slim` plus `python3 man-db curl dnsutils less jq bc gh git unzip rsync ripgrep procps psmisc lsof socat ca-certificates fonts-dejavu-core`. | [`Dockerfile` L68-L87](https://github.com/QwenLM/qwen-code/blob/d79bb9b712119392a3df0174054120e6ab54cb97/Dockerfile#L68-L87) | High |
| For the general (non-Coder) Qwen3.x chat models: no vendor text on a coding-tool environment found. | n/a | Not found |

Editing mechanism: mixed by design. Half the named training scaffolds are bash-only or bash-first (mini-SWE-agent, Terminus, SWE-agent's Python-backed tools), run on SWE-style images where Python exists. This is the family with the strongest documented reason to edit via shell or Python.

### DeepSeek

- Official docs only describe API compatibility and list agent integrations (Claude Code via the Anthropic-format endpoint, Codex, OpenCode, others) and a "DeepSeek Harness" developer preview: https://api-docs.deepseek.com/ (Your First API Call), https://api-docs.deepseek.com/guides/anthropic_api , https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code . Confidence: High.
- A statement of which tools or scaffold DeepSeek models were trained or evaluated with: **not found**.

### Mistral

| Claim | Source | Confidence |
|---|---|---|
| Devstral Small (2505): built with All Hands AI; SWE-bench result under "OpenHands Scaffold"; shipped system prompt opens "You are Devstral ... using the OpenHands scaffold" and advises combining bash commands, "using sed and grep to edit/view multiple files at once". | https://huggingface.co/mistralai/Devstral-Small-2505 (README.md, SYSTEM_PROMPT.txt) | High |
| Devstral 2 (2512): recommended scaffold is Mistral Vibe; also lists Cline, Kilo Code, Claude Code, OpenHands. | https://huggingface.co/mistralai/Devstral-2-123B-Instruct-2512 | High |
| Mistral Vibe built-in tools: `bash`, `edit`, `grep`, `read_file`, `write_file`, `todo`, `task`, `skill`, `web_fetch`, `web_search`, `ask_user_question`. `edit` is "Exact string replacement in a file" with `replace_all`. The bash prompt says to prefer the dedicated tools over `cat`/`head`/`tail`, `grep`/`sed`/`awk`, and `sed`/`echo` redirects. | [`vibe/core/tools/builtins/prompts/`](https://github.com/mistralai/mistral-vibe/tree/63dab302305c80131ea1e5b1c3cb18c2a4fd96d3/vibe/core/tools/builtins/prompts) (`bash.md`, `edit.md`) | High |

Editing mechanism: `str_replace_editor` (OpenHands) for Devstral 1, exact string-replace `edit` (Vibe) for Devstral 2.

---

## 6. Program → which harnesses and images provide or expect it

"Expects" = the harness prompt or code assumes it. "Provides" = installed or bundled. Blank = not mentioned in the sources read.

| Program | Expected by | Provided by | Notably absent from |
|---|---|---|---|
| `bash` | Claude Code (bash or zsh required); Codex (`bash -lc`); mini-swe-agent (`bash -lc`, "all it needs"); SWE-agent; OpenHands; pi (prefers `/bin/bash`, **falls back to `sh`**) | OpenHands minimal layer installs it, including on Alpine; all Debian/Ubuntu images | Alpine by default (Claude docs: `apk add bash`) |
| `python3` | SWE-agent tools (hard requirement); OpenAI reference `apply_patch.py`; GPT-4.1 SWE-bench harness (Python/Jupyter tool); SWE-agent and Anthropic task prompts ("execute it with `python`") | codex-universal (3.10 to 3.14); Claude Code cloud sessions; OpenAI hosted shell (3.11); Gemini CLI sandbox; Qwen Code sandbox; Aider benchmark (3.11); SWE-bench Python and C images; SWE-ReX standalone 3.11 (SWE-agent, incl. multilingual); OpenHands (private copy for its own server) | pi's example image; Claude devcontainer Dockerfile (not listed, likely inherited); SWE-bench Go/Java/PHP/JS templates (not listed) |
| `rg` (ripgrep) | Codex prompts ("prefer `rg`", with fallback clause); **pi default system prompt ("ls, rg, find")**; pi `grep` tool; Claude Code `Grep` tool; Gemini/Qwen `grep_search` | Claude Code (bundled); Codex package (bundled 15.2.0); Gemini CLI (vendored); codex-universal; Claude cloud sessions; Gemini and Qwen sandbox images; pi (runtime download, **skipped offline**); pi example image | SWE-bench images; OpenHands layers; Claude devcontainer apt list; Aider benchmark |
| `fd` / `fdfind` | pi `find` tool and autocomplete | codex-universal (`fd-find`); pi (runtime download, skipped offline) | everything else |
| `grep`, `find` | Claude Code on Linux/macOS (embedded `ugrep`/`bfs` behind those names); pi bash snippet; Devstral/OpenHands prompt | OpenHands full image (`grep findutils`); any base distro | none |
| `sed`, `cat`, `head`, `tail`, `nl`, `wc`, `ls` | Codex prompts (read commands); mini-swe-agent default prompt (`sed -i` edits, heredocs, `nl \| sed -n`); Claude Code (viewer list); Devstral prompt | base distro; OpenHands full image (`coreutils sed`) | none (BusyBox variants differ on Alpine; not covered by any source here) |
| `git` | Codex prompts (`git log`, `git blame`, `git show`); SWE-agent submit/review; OpenHands | all images listed; OpenHands minimal layer installs it | Claude Code: optional |
| `apply_patch` | GPT-4.1/5.x models (trained format) | Codex (built in, Rust); OpenHands GPT-5 preset; OpenAI Agents SDK | any harness that offers only string-replace or bash |
| `jq` | none explicitly | Claude devcontainer; Claude cloud; codex-universal; Gemini/Qwen sandboxes; SWE-bench Python/JS/Ruby bases; OpenHands full | |
| `tmux` | OpenHands terminal tool (subprocess fallback); Terminus 2 | OpenHands minimal layer; Terminus 2 installs it; Claude cloud sessions | |
| `curl` / `wget` | Claude Code installer (`curl`); SWE-ReX pipx path (network) | codex-universal; Gemini/Qwen sandboxes; SWE-bench bases (`wget`, some `curl`) | Alpine by default (`curl`) |
| `gh` | Mistral Vibe bash prompt | Claude devcontainer; Claude cloud; Gemini/Qwen sandboxes | codex-universal |
| `node` | Claude Code npm install (18+); pi (22.19+); Gemini CLI / Qwen Code | their own images | task images generally |
| build tools (`make`, `gcc`) | none explicitly | codex-universal; SWE-bench bases (`build-essential`); OpenHands full; Gemini sandbox (`make g++`) | pi example image |
| `erlang` / `elixir` | none | **codex-universal only** (27.1.2 / 1.18.3) | Claude cloud sessions; OpenAI hosted shell; every other image here |

---

## 7. Not verified / not found

- **Claude Code system prompt and tool descriptions**: not published. The only steering evidence with a URL is the tools reference; the Bash-description line is a live-session observation.
- **Reference devcontainer and Python**: Python 3 presence is inferred from the `node` → `buildpack-deps` → `mercurial` chain, not confirmed by running the image. I could not fetch `node:20`'s own Dockerfile (directory gone from `docker-node` `main`).
- **Why the Alpine `libgcc`/`libstdc++`/`ripgrep` text was removed** from the Claude Code setup page between May and November 2026, and whether the bundled `rg` now works on musl: not found.
- **Real Codex cloud image** versus `codex-universal`: the README says they are not identical; the difference is not documented.
- **Pi**: status of the old `@mariozechner/pi-coding-agent` npm name; behaviour of versions older than 1.5.2 or of any fork; whether non-interactive modes pre-download `rg`/`fd`.
- **OpenHands**: whether its private Python is reachable from the agent's shell (inferred not).
- **SWE-bench**: current location of the image templates on `main`; whether `ruby:`/`rust:` based instance images really contain `python3` (inferred yes).
- **Anthropic** scaffold notes for models after Claude Sonnet 4.5: not opened.
- **Google**: names and matching rules of the "file operation tools" in the internal SWE-bench scaffold: not published.
- **Qwen**: tool set of the Qwen3-Coder RL environments; anything for non-Coder Qwen3.x models.
- **DeepSeek**: no primary statement about training or evaluation tooling.
- **No vendor states outright** "our model edits files with Python when no edit tool matches". The closest primary evidence is OpenAI's prompt line forbidding it, the Python/Jupyter tool in the GPT-4.1 harness, and Qwen's list of bash-first training scaffolds. The causal link to the `python3 - <<'PY'` habit is my inference.
