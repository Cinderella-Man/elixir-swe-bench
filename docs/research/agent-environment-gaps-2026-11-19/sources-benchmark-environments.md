# Benchmark task environments: what is installed, and what environment gaps do to scores

Research notes, primary sources only. Every source below was fetched on 2026-11-19 in this session.
Raw files were read with `curl` from `raw.githubusercontent.com` at the commit shown; papers were read from the arXiv HTML version; two OpenAI pages were read in a browser because they refuse non-browser clients.

Confidence labels:

- **High** — I read the exact text in the primary source.
- **Medium** — read in a primary source, but it describes a neighbouring artefact (for example a rootfs manifest published next to the image, not the image itself), or it is my own tally over primary files.
- **Inferred** — follows from a package dependency or from the absence of a line; not stated by the source.

---

## 1. `hexpm/elixir` and `hexpm/erlang` images (built by `hexpm/bob`)

Source repo: `hexpm/bob`, commit `908051c727fff18d83be0fb6af1bc1c6ae5c0eff` (2026-11-16).

- Elixir Dockerfiles: <https://github.com/hexpm/bob/blob/908051c727fff18d83be0fb6af1bc1c6ae5c0eff/priv/scripts/docker/elixir-ubuntu.dockerfile>, `elixir-debian.dockerfile`, `elixir-alpine.dockerfile` (same directory)
- Erlang Dockerfiles: `erlang-ubuntu-jammy.dockerfile`, `erlang-ubuntu-noble.dockerfile`, `erlang-debian-bookworm.dockerfile`, `erlang-alpine.dockerfile` (same directory)
- Build matrix: <https://github.com/hexpm/bob/blob/908051c727fff18d83be0fb6af1bc1c6ae5c0eff/lib/bob/job/docker_checker.ex> — Alpine `3.21`–`3.24`, Ubuntu `jammy`/`noble`/`resolute`, Debian `bookworm`/`trixie`, each Debian suite both plain and `-slim`.

### 1.1 What the final image stages add (High)

The Elixir image is the Erlang image plus one copy step. All three Elixir Dockerfiles end with:

```
FROM hexpm/erlang-${ARCH}:${ERLANG}-<os>-${OS_VERSION} AS final
COPY --from=build /ELIXIR_LOCAL/usr/local /usr/local
```

`wget`, `unzip`, `make`, `ca-certificates` are installed only in the discarded `build` stage.

The Erlang final stages:

| Variant | Base | Packages added in the final stage | `ENV` |
| --- | --- | --- | --- |
| Ubuntu jammy | `ubuntu:${OS_VERSION}` | `ca-certificates libodbc1 libssl3 libsctp1 netbase` (`--no-install-recommends`) | `LANG=C.UTF-8` |
| Ubuntu noble | `ubuntu:${OS_VERSION}` | `ca-certificates libodbc2 libssl3t64 libsctp1 netbase` (amd64 branch spells it `libssl3t`) | `LANG=C.UTF-8` |
| Debian bookworm (plain and slim) | `debian:${OS_VERSION}` | `ca-certificates libodbc1 libssl3 libsctp1 netbase` | `LANG=C.UTF-8` |
| Alpine | `alpine:${OS_VERSION}` | `ca-certificates libstdc++ ncurses openssl unixodbc lksctp-tools` | **none** |

Compilers (`gcc g++ make autoconf dpkg-dev`, and on Alpine `bash build-base perl-dev`) exist only in the `build` stage. None of `bash` (Alpine), `git`, `curl`, `perl`, `python3`, `make`, `gcc`, `patch`, `procps`, `less`, `locales` is installed by any final stage. Everything else is whatever the base image carries.

`LANG`: set to `C.UTF-8` on Ubuntu and Debian; the Alpine Dockerfile has no `ENV LANG` line at all (High — `grep LANG` over the Dockerfiles finds it only in the three Debian-family Erlang files). For contrast, the Docker Official `elixir` image sets `LANG=C.UTF-8` in all variants including Alpine (section 4.5).

### 1.2 What the base images carry

**Ubuntu** — Canonical's OCI rootfs manifests, <https://partner-images.canonical.com/oci/noble/current/ubuntu-noble-oci-amd64-root.manifest> (Last-Modified 2026-11-14) and the `jammy` equivalent (2026-11-14). Docker's own docs say the Hub image "is built from official rootfs tarballs provided by Canonical" (<https://github.com/docker-library/docs/blob/e3066f1c9ddae8a4da499e39f80eef604e2a02e7/ubuntu/content.md>). Confidence **Medium**: same Canonical pipeline, but I read the manifest published beside the tarball, not the Hub layer.

noble, 92 packages, the non-library ones: `apt base-files base-passwd bash bsdutils coreutils dash debconf debianutils diffutils dpkg e2fsprogs findutils gpgv grep gzip hostname init-system-helpers libc-bin login logsave mawk mount ncurses-base ncurses-bin passwd perl-base procps sed sensible-utils sysvinit-utils tar ubuntu-keyring unminimize util-linux`.

jammy, 101 packages: the same set plus `adduser lsb-base usrmerge`, minus `unminimize`.

**Debian bookworm** — `debuerreotype/docker-debian-artifacts`, branch `dist-amd64`, commit `2dcd3d429aa99a1302a4bb9b8cacb4f318c71d4a` ("Update to 20261116", Debian 12.15): <https://github.com/debuerreotype/docker-debian-artifacts/blob/2dcd3d429aa99a1302a4bb9b8cacb4f318c71d4a/bookworm/rootfs.manifest> and `bookworm/slim/rootfs.manifest`. This repo is the declared source of the Hub image (<https://github.com/docker-library/official-images/blob/master/library/debian>). Confidence **High**.

Non-library packages: `adduser apt base-files base-passwd bash bsdutils coreutils dash debconf debian-archive-keyring debianutils diffutils dpkg e2fsprogs findutils gpgv grep gzip hostname init-system-helpers libc-bin login logsave mawk mount ncurses-base ncurses-bin passwd perl-base sed sysvinit-utils tar tzdata usr-is-merged util-linux util-linux-extra`.

The plain and `-slim` manifests list **identical package names** (I diffed them). Slim differs in files removed, not packages.

**Differences that matter:** Ubuntu's base has `procps` (so `ps`, `top`, `pgrep`, `pkill`, `free`, `uptime`, `watch`); Debian's does **not**. Neither has `patch`, `less`, `file`, `curl`, `wget`, `git`, `make`, `gcc`, `python3`, `unzip`, `xxd`, `bc`, `tree`, any editor, or `locales`. `awk` is `mawk`, not `gawk`, on both.

**`perl-base`** is in both. On noble its file list (<https://packages.ubuntu.com/noble/amd64/perl-base/filelist>) contains `/usr/bin/perl` and about 60 core modules (`File::Temp`, `File::Basename`, `File::Path`, `Getopt::Long`, `POSIX`, `List::Util`, `IO::*`, `IPC::Open3`, `Text::Wrap`, `Cwd`, …). So `perl -pi -e '…'` one-liners work on bare Ubuntu and Debian; anything needing `Data::Dumper`, `JSON::PP`, `File::Find` and similar does not. Confidence High for Ubuntu; Inferred for Debian (same package in the manifest, file list not fetched).

**Locales.** Docker docs for both: "this image only includes the `C`, `C.UTF-8`, and `POSIX` locales by default" (ubuntu `content.md` above; <https://github.com/docker-library/docs/blob/e3066f1c9ddae8a4da499e39f80eef604e2a02e7/debian/content.md>). High.

**Alpine 3.22** — the Hub image is `FROM scratch` + `ADD alpine-minirootfs-3.22.8-x86_64.tar.gz /` (<https://github.com/alpinelinux/docker-alpine/blob/4e376baa03cfee6fbebd5ca593e980899807e975/x86_64/Dockerfile>, 2026-11-05). The minirootfs profile installs exactly `busybox alpine-baselayout alpine-keys alpine-release apk-tools libc-utils` (<https://github.com/alpinelinux/aports/blob/7cf2a75b759dbec5160111e7fba8d74ebda22b78/scripts/mkimg.minirootfs.sh>, branch `3.22-stable`), and `genrootfs.sh` symlinks every name from `busybox --list-full`. High for the package list; their dependencies (musl etc.) are Inferred.

So on Alpine every text/file utility is a BusyBox applet (BusyBox 1.37.0-r20). `/bin/sh` is BusyBox `ash`; the build has `CONFIG_BASH_IS_NONE=y`, so there is **no `bash`**. No `perl`, `python3`, `git`, `curl`, `make`, `gcc`.

### 1.3 Per-variant answer

| Program | hexpm Ubuntu jammy/noble | hexpm Debian bookworm(-slim) | hexpm Alpine 3.22 |
| --- | --- | --- | --- |
| `bash` | yes (base) | yes (base) | **no** (`ash` only) |
| `git` | no | no | no |
| `curl` | no | no | no (BusyBox `wget` exists) |
| `perl` | `perl-base` only | `perl-base` only | **no** |
| `python3` | no | no | no |
| `make`, `gcc` | no (build stage only) | no | no |
| `patch` | **no** | **no** | **no** (`# CONFIG_PATCH is not set`) |
| `ps` (procps) | yes (base) | **no** | BusyBox `ps` (`-o`, `-T`; `-aAdefl` accepted and ignored) |
| `less` | no | no | BusyBox `less` |
| `locales` package | no; `C.UTF-8` built in | no; `C.UTF-8` built in | n/a (musl) |
| `LANG` | `C.UTF-8` | `C.UTF-8` | **unset** |

---

## 2. BusyBox vs GNU: what actually differs on Alpine 3.22

Sources:

- BusyBox 1.37.0 source, official GitHub mirror (linked from <https://busybox.net/source.html>): `https://github.com/vda-linux/busybox_mirror/blob/1_37_0/<dir>/<applet>.c` — usage text is the `//usage:` block, options are the `getopt32` string.
- Alpine's build configuration, which decides which features are compiled in: <https://github.com/alpinelinux/aports/blob/7cf2a75b759dbec5160111e7fba8d74ebda22b78/main/busybox/busyboxconfig> (`pkgver=1.37.0`, `pkgrel=20`). Global switches: `CONFIG_DESKTOP=y`, `CONFIG_LONG_OPTS=y`, `# CONFIG_EXTRA_COMPAT is not set`.
- **Alpine wiki: not retrieved.** `wiki.alpinelinux.org` answers automated clients with a bot-protection page ("access denied: denied by administrative rule"). I did not work around it. The source code and build config above are stronger evidence anyway.

Confidence High throughout unless marked.

### 2.1 Things commonly assumed missing that are **present** on Alpine 3.22

| Feature | Evidence |
| --- | --- |
| `sort -V` | `CONFIG_FEATURE_SORT_BIG=y`; usage lists `-V  Sort version` |
| `stat -c FMT` | `CONFIG_FEATURE_STAT_FORMAT=y` |
| `head -n -N`, `head -c` | `CONFIG_FEATURE_FANCY_HEAD=y`; usage `-n -N[bkm]  Print all except N last lines` |
| `cp --parents` | `CONFIG_FEATURE_CP_LONG_OPTIONS=y`; `cp.c` registers `"parents"` |
| `readlink -f` | `CONFIG_FEATURE_READLINK_FOLLOW=y` |
| `sed -i`, `sed -i.bak`, `-E`/`-r` | usage `[-i[SFX]] [-nrE]`; long forms `--in-place --regexp-extended --quiet --silent --expression --file` |
| `find -regex -delete -quit -empty -print0 -exec … + -maxdepth -mmin -executable -path -iname` | all `CONFIG_FEATURE_FIND_*=y` |
| `xargs -0 -I -P -n -r -a` and `--no-run-if-empty` | `CONFIG_FEATURE_XARGS_SUPPORT_*=y` |
| `grep -r -E -F -o -w -x -l -L -c -m -A -B -C -q -s -H -h -i -v -e -f` | `OPTSTR_GREP`; `-a` and `-I` are accepted and ignored; `--color` accepted |
| `mktemp -d -p DIR -t -u -q`, `--tmpdir[=DIR]`, `--directory`, `--dry-run` | `mktemp.c` |
| `timeout [-s SIG] [-k KILL_SECS] SECS PROG` | same argument order as GNU |
| `awk` `gensub`, `strftime`, `systime`, `mktime`, `and/or/xor/lshift/rshift/compl`, `IGNORECASE` | `CONFIG_FEATURE_AWK_GNU_EXTENSIONS=y`; builtin table in `awk.c` |
| `diff -u -r -N -q -w -b -B -i -U n -L`, long forms such as `--unified --recursive --new-file --brief` | `CONFIG_FEATURE_DIFF_LONG_OPTIONS=y`, `CONFIG_FEATURE_DIFF_DIR=y` |
| applets bare Ubuntu/Debian lack: `less vi wget unzip xxd hexdump bc dc tree lsof netstat nc ps top pgrep watch strings dos2unix` | each `CONFIG_<NAME>=y` |

### 2.2 Real gaps

| Tool | Absent on Alpine 3.22 BusyBox | Evidence |
| --- | --- | --- |
| `patch` | **the applet is not built** — no `patch` command at all | `# CONFIG_PATCH is not set` |
| `bash` | not present; `bash` scripts and `#!/bin/bash` fail | `CONFIG_BASH_IS_NONE=y` |
| `ed`, `xz` (compress), `tsort`, `telnet`, `script`, `taskset` | not built | `# CONFIG_… is not set` |
| `make file column zip join envsubst csplit pr numfmt stdbuf fmt` | no such symbol in the config (not BusyBox applets in this build) | absent from `busyboxconfig` |
| `grep` | `-P` (PCRE), `--include`, `--exclude`, `--exclude-dir`, `-z`, `--line-buffered`, `-b`, every long option except `--color` | `OPTSTR_GREP = "lnqvscFiHhe:*f:*LorRm:+wx" "A:+B:+C:+" "E" "aI"`; `-z` needs `EXTRA_COMPAT`, which is off |
| `sed` | `-s`, `-z`, `-u`, `--debug`, `--posix`, `--null-data`; `sed --version` prints "This is not GNU sed version 4.0" | getopt string `"i::rEne:*f:*"` |
| `find` | `-printf`, `-regextype`, `-iregex`, `-newermt`, `-samefile`, `-amin`, `-cmin`, `-readable`, `-writable` | not in `params[]`; `FEATURE_FIND_SAMEFILE`, `_AMIN`, `_CMIN` not set |
| `xargs` | `-d DELIM`, `-L N`, long options other than `--no-run-if-empty` | `OPTION_STR "+trn:s:e::E:o" "p" "x" "0" "I:i::" "P:+" "a:"` |
| `timeout` | every long option: `--signal`, `--kill-after`, `--foreground`, `--preserve-status`, `-v` | `getopt32(argv, "+s:k:" …)` |
| `mktemp` | `--suffix` | long list is `directory quiet dry-run tmpdir` |
| `date` | `-d` accepts only fixed layouts (`@seconds`, `hh:mm[:ss]`, `YYYY-MM-DD hh:mm[:ss]`, `[YYYY.]MM.DD-hh:mm[:ss]`, …) — no `yesterday`, `2 days ago`, `next monday`; `%N` nanoseconds off | usage text; `# CONFIG_FEATURE_DATE_NANO is not set` |
| `sort`, `head`, `stat`, `readlink` | **long options** (`--version-sort`, `--lines=`, `--format=`, `--canonicalize`): these applets call plain `getopt32` | no `getopt32long` in those files |
| `realpath` | all options (`-m`, `--relative-to`, …) | usage is `FILE...` |
| `cp` | (nothing important; `-a -r -p -u -T -t --parents` all work) | usage |
| `diff` | context format `-c`, side-by-side `-y`, `--color`, `-x/--exclude`, `--strip-trailing-cr` | "This implementation supports unified diffs only." |
| `awk` | gawk-only features not in the builtin table: `asort`, `asorti`, `patsplit`, `strtonum`, `PROCINFO`, `BEGINFILE`/`ENDFILE`, `-i inplace`, `--long-options` | builtin table in `awk.c` (Inferred from absence) |
| `ps` | BSD forms and most procps flags; only `-o COLS` and `-T` do anything | usage `[-o COL1,COL2=HEADER] [-T]`; getopt `"Zo:*aAdefl"` |
| `ln` | `-r` (relative) | usage `[-sfnbtv] [-S SUF]` |
| `env` | `-S`, `-C` | usage `[-i0] [-u NAME]` |
| `tar` | `--transform`, `--wildcards`, `--to-command`; present: `--strip-components --exclude --exclude-from --files-from --directory --numeric-owner --overwrite --no-same-owner` and `-z -j -J -a` | long-option table in `tar.c`; `# CONFIG_FEATURE_TAR_TO_COMMAND is not set` |

Not verified from a primary source: regex-dialect differences (`\b`, `\w`, `\d` under musl) — not checked.

**Bare Ubuntu/Debian has its own gap of the same kind:** `awk` there is `mawk`, not `gawk` (manifests in 1.2), and there is no `patch`, `less`, `file`, `xxd`, `bc`, `tree`.

---

## 3. Task environments in comparable agent benchmarks

### 3.1 SWE-bench (Python)

- Classic harness template, tag `v4.1.0` (2025-09-11): <https://github.com/SWE-bench/SWE-bench/blob/726c5461e2ef52d83cf1ea2107870a8bb3328d57/swebench/harness/dockerfiles/python.py>. `FROM ubuntu:{ubuntu_version}` with default `"ubuntu_version": "22.04"` (`harness/constants/__init__.py`).
- Current per-task Dockerfiles (SWE-bench 5.0, 2026-08-17, moved to a task repo): <https://github.com/SWE-bench/swe-bench-tasks/blob/3d07b464b7b311a0cbfb5ed5b2d8a3b96f84a33d/tasks/astropy__astropy-12907/Dockerfile> — `FROM --platform=linux/amd64 ubuntu:jammy`.

apt packages, identical in both: `wget git build-essential libffi-dev libtiff-dev python3 python3-pip python-is-python3 jq curl locales locales-all tzdata`, then Miniconda (`/opt/miniconda3`) and a per-task conda env `testbed`. High.

Network: the harness only grades patches. The reference agent, mini-SWE-agent, runs the same image with `environment_class: docker` and no network restriction in its config, and tells the model "You have a full Linux shell environment" and "If a tool isn't available, you can also install it" (<https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/config/benchmarks/swebench.yaml>). Prompt text High; "network is on" Inferred from the absence of a restriction.

Anthropic's own SWE-bench scaffold instead runs offline and says so in the tool description — see 5.4.

### 3.2 SWE-bench Multilingual (300 tasks, 42 repos; C, C++, Go, Java, JS, TS, PHP, Ruby, Rust)

Site: <https://www.swebench.com/multilingual.html> — base images install "the language runtime and operating system packages for all the repositories in that language". Says nothing about Python or the network.

Base templates, `v4.1.0`, <https://github.com/SWE-bench/SWE-bench/tree/726c5461e2ef52d83cf1ea2107870a8bb3328d57/swebench/harness/dockerfiles> (High):

| Language | Base | apt packages | Python? |
| --- | --- | --- | --- |
| C/C++ | `ubuntu:22.04` | `wget git build-essential libtool automake autoconf tcl bison flex cmake python3 python3-pip python3-venv python-is-python3` | **yes, explicit** |
| Go | `ubuntu:{ver}` | `wget git build-essential` + Go tarball | not installed |
| Java | `maven:3.9-eclipse-temurin-{ver}` | `wget git build-essential ant unzip` | not installed |
| JS/TS | `ubuntu:{ver}` | `build-essential curl git libssl-dev software-properties-common wget gnupg jq ca-certificates dbus ffmpeg imagemagick procps` + Chrome + nvm | not listed (whether `software-properties-common` pulls it in was not checked) |
| PHP | `php:{ver}` | `wget git build-essential libgd-dev libzip-dev libgmp-dev libftp-dev libcurl4-openssl-dev` | not installed |
| Ruby | `ruby:{ver}` | `wget git build-essential jq` | via base: `ruby` default tag is `FROM buildpack-deps` (Inferred, see 4.3) |
| Rust | `rust:{ver}` | `wget git build-essential` | via base: `rust` is `FROM buildpack-deps` (Inferred) |

Every one installs `git` and `build-essential`, which pull full `perl`, `patch` and `make` (`git` depends on `perl`; `build-essential` → `dpkg-dev` → `perl`, `patch`, `make`: <https://packages.ubuntu.com/noble/git>, <https://packages.ubuntu.com/noble/dpkg-dev>). Network: not stated — **not found**.

### 3.3 Multi-SWE-bench (ByteDance; arXiv 2504.02605)

Repo commit `24f493f8a103e72312ded4f6b9c89f081d69cb09`; one Python module per repository under `multi_swe_bench/harness/repos/<language>/…` (about 2,000 modules; languages include c, cpp, csharp, golang, java, javascript, kotlin, php, python, ruby, rust, scala, swift, typescript — **no Elixir**). I read three:

- Go, `golang/cli/cli.py`: base `golang:latest`, nothing added. <https://github.com/multi-swe-bench/multi-swe-bench/blob/24f493f8a103e72312ded4f6b9c89f081d69cb09/multi_swe_bench/harness/repos/golang/cli/cli.py>
- Rust, `rust/tokio_rs/tokio.py`: base `rust:latest`, nothing added.
- Java, `java/alibaba/fastjson2.py`: base `ubuntu:20.04` + `gnupg ca-certificates git curl` + `zulu8-jdk`; sets `LANG=C.UTF-8 LC_ALL=C.UTF-8`.

`golang` is `FROM buildpack-deps:<suite>-scm`, `rust` is `FROM buildpack-deps:<suite>` (4.3), so Go and Rust images get Python 3 transitively through `mercurial` (Inferred). The Java sample has no Python. Paper: failed image builds are patched or the PR is discarded. Network: **not found**. Sample of 3 modules only — Medium.

### 3.4 SWE-bench Pro (Scale AI; arXiv 2509.16941)

Repo commit `66f92766bba642462d4bbe5479e83f91f9211862`; 731 per-instance base Dockerfiles in `dockerfiles/base_dockerfile/`, 11 repositories. I read one per repository for 8 of 11.

The Dockerfile template itself carries the rule, verbatim: "Ensure a basic Python environment is installed, necessary for final parsing and scoring" (<https://github.com/scaleapi/SWE-bench_Pro-os/blob/66f92766bba642462d4bbe5479e83f91f9211862/dockerfiles/base_dockerfile/instance_flipt-io__flipt-02e21636c58e86c51119b63e0fb5ca7b813b07b1/Dockerfile>).

| Repo (language) | Base | Packages (verbatim) |
| --- | --- | --- |
| flipt (Go) | `golang:1.24` | `git bash build-essential python3 python3-pip python3-setuptools python-is-python3 perl` |
| navidrome (Go) | `golang:1.24` | `curl git pkg-config build-essential cmake g++ zlib1g-dev libutfcpp-dev python3 python3-pip python3-setuptools python-is-python3` |
| teleport (Go) | `golang:1.23.1-alpine` | `apk add git bash build-base python3 py3-pip py3-setuptools ca-certificates curl … rsync openssh-client net-tools sudo musl-dev gcompat` |
| NodeBB (JS) | `node:18` | `git python3 python3-pip python3-setuptools python-is-python3`, `redis-server` |
| element-web (TS) | `node:22-bullseye` | `git build-essential python3 python3-pip python3-setuptools python-is-python3 bash curl ca-certificates` |
| protonmail/webclients (TS) | `ubuntu:20.04` | `curl git python3 python3-pip python3-setuptools python-is-python3 build-essential` + Node 18 |
| tutanota (TS) | `node:16-bullseye` | `git bash python3 python3-pip python3-setuptools python-is-python3 build-essential …` |
| ansible (Python) | `python:3.11-slim` | `git bash make gcc libffi-dev libssl-dev python-is-python3 build-essential` |

**All 7 non-Python samples install `python3` and `python-is-python3` (or the apk equivalents), including the Alpine one, which also adds `bash`.** High for the samples; Medium as a claim about all 731.

Paper: environments built by professional engineers "until the resulting Docker images could successfully run the codebase and its tests", so that "any agent can access the codebase and execute the tests out of the box". Network: **not found**.

### 3.5 SWE-PolyBench (Amazon; arXiv 2504.08703)

Repo commit `9c836c5d7f3cb991934132b77d29e6941d912a07`. Base templates: <https://github.com/amazon-science/SWE-PolyBench/blob/9c836c5d7f3cb991934132b77d29e6941d912a07/src/poly_bench_evaluation/constants.py>. Per-instance Dockerfiles are a dataset column (`AmazonScience/SWE-PolyBench`, 2,110 rows; I sampled 9 repositories through the Hugging Face rows API).

- JavaScript base: `ubuntu:22.04` + `bzip2 libgtk-3-0 libasound2 libx11-xcb1 wget git build-essential libffi-dev libtiff-dev python3 python3-pip jq curl locales locales-all tzdata` + nvm with seven Node versions + Firefox + Chromium + Chrome. **Python explicit.**
- TypeScript base: `ubuntu:22.04` + the same list plus `g++ libx11-dev libkrb5-dev gnupg unzip software-properties-common git-lfs libxkbfile-dev libsecret-1-dev quilt rsync bats …`. **Python explicit.**
- Java base: `amazonlinux` + `yum groupinstall "Development Tools"` + `wget git jq tar` + three Corretto JDKs + Maven. Python not listed.
- Some instances use their own base (`microsoft/vscode`: `node:14` + `git xvfb …`).

Network: **not found**.

Section 5.6 records what this paper says about an agent scaffold that needed Python in the image.

### 3.6 Terminal-Bench

- Paper, arXiv 2601.11868 (submitted 2026-01-17): <https://arxiv.org/abs/2601.11868>. "A Terminal-Bench task consists of an instruction, a Docker image, a set of tests, an example solution, and a time limit". 89 tasks.
- Network (§5 Limitations, High): "we allow agents to access the internet to install packages and query the web for relevant information."
- Task repo `harbor-framework/terminal-bench-2`, commit `2fd12b88aafdd04a52c298e3940bcb189f9766d6`. I downloaded all 89 `environment/Dockerfile` and `task.toml` files and counted (Medium — my tally):
  - `allow_internet = true` in **89 of 89** `task.toml` files. Each also pins `cpus`, `memory_mb`, `storage_mb` and timeouts.
  - Final-stage base images: 41 `python:3.13-slim-bookworm`, 39 `ubuntu:24.04`, 2 `python:3.11-slim`, 2 `python:3.10-slim-bookworm`, 1 `python:3.11`, 2 `debian:13.0-slim`, 2 `debian:bullseye-slim`.
  - 46 of 89 sit on a `python:` image; 10 more mention `python3`/`pip`/`uv`/`conda` in the Dockerfile; **33 mention no Python at all** (bare `ubuntu:24.04` or Debian slim plus task files).
- Terminal-Bench 1 base images: `FROM ubuntu:24.04` or `FROM python:3.13-slim-bookworm`, each plus `tmux asciinema` (<https://github.com/laude-institute/terminal-bench/blob/main/docker/base-images/ubuntu-24-04/Dockerfile> — URL now redirects to `harbor-framework`; read from `main`, not pinned). `asciinema` depends on `python3` on noble (<https://packages.ubuntu.com/noble/asciinema>), so those bases carried Python as a side effect (Inferred).

So Terminal-Bench does not give every task Python or general tooling; it leaves the image bare and lets the agent install over the network. Section 5.3 has the measured consequence.

### 3.7 Aider polyglot benchmark

<https://github.com/Aider-AI/aider/blob/38d4341e59769158405ceb09ee63f360acb038cb/benchmark/Dockerfile> (last changed 2025-02-07). `FROM buildpack-deps:jammy`, plus `software-properties-common cmake libboost-all-dev python3.11 python3.11-venv python3.11-dev python3-pip ca-certificates-java openjdk-21-jdk libtbb-dev`, Go 1.21.5, Rust via rustup, Node 20 with Jest and friends. One image for all six languages; Python present regardless. `benchmark/docker.sh` runs `docker run -it --rm --memory=12g --memory-swap=12g --add-host=host.docker.internal:host-gateway …` with no network restriction. High.

### 3.8 SWE-Lancer (OpenAI; arXiv 2502.12115)

- Dockerfile: <https://github.com/openai/frontier-evals/blob/5305e936ba7824654151bffab4027afb593d7cd8/project/swelancer/Dockerfile_x86_base> (2025-12-02; the old `openai/SWELancer-Benchmark` repo says the code moved to `openai/preparedness`). `FROM ubuntu:22.04`; first apt layer `curl git wget tar gzip gnupg openssh-client xz-utils patch ansible zip unzip`; then Python 3.12, Miniconda, Chromium, Xvfb/VNC, nginx, Ruby (rvm), `build-essential`, Node via nvm, Playwright. The task repo is a JS/TS app; Python is there regardless.
- Network: **off**. Paper: "agents run in a Docker container with the repository preconfigured and no Internet access". README: "SWELancer is designed to run with internet disabled" and "we only consider rollouts run with internet disabled to be valid". Paper appendix: "All the libraries the agent can access … are installed in the container." High.

### 3.9 Elixir-specific agent benchmarks

One found: **Longtail-SWE** (Nebius; arXiv 2611.10304, submitted 2026-11-06, v2 2026-11-11): <https://arxiv.org/abs/2611.10304>. 202 issue-resolution tasks across Clojure, Dart, **Elixir**, **Erlang**, F#, Haskell, Julia, Kotlin, Lua, OCaml, R, Scala, Swift, plus 269 easier tasks. (The NeurIPS workshop listing still says 237; the arXiv abstract and the repo README say 202.) The paper reports Elixir among the three lowest mean pass rates (50.4%, against 73.5% for Erlang).

Elixir base image: <https://github.com/SWE-rebench/Longtail-SWE/blob/87afdd67cb8187b36d7a0c045f8c917847029a82/base_dockerfiles/Dockerfile_elixir> (High):

```
FROM --platform=linux/amd64 elixir:1.18.4-otp-27
ENV TZ=Etc/UTC LANG=C.UTF-8 LC_ALL=C.UTF-8 ELIXIR_ERL_OPTIONS=+fnu
apt-get install -y --no-install-recommends git curl wget unzip zip ca-certificates build-essential
  pkg-config cmake gnupg inotify-tools nodejs npm python3 python3-pip python3-venv rustc cargo
  libssl-dev zlib1g-dev libgmp-dev libffi-dev
mix local.hex --force && mix local.rebar --force
```

The Erlang base is built on top of it; its header comment says the parent "already supplies OTP 27, build tooling, Python, Node, C/C++ toolchains". Other Elixir variants add Postgres, Node 24 or Rust. The base is the Docker Official `elixir` image (Debian + `buildpack-deps`), not `hexpm/elixir`.

Network for the agent: **not found** (the README's v1.2 note only says test commands were changed to have "no network steps").

SWE-bench Multilingual, Multi-SWE-bench, SWE-bench Pro, SWE-PolyBench and Aider polyglot contain no Elixir.

### 3.10 Summary

| Benchmark | Python in non-Python task images? | General CLI tooling | Network for the agent |
| --- | --- | --- | --- |
| SWE-bench Multilingual | C/C++ explicit; Ruby/Rust via base (Inferred); Go, Java, PHP no | `git wget build-essential` everywhere | not stated |
| Multi-SWE-bench | Go/Rust via base (Inferred); Java sample no | whatever the language image has | not found |
| SWE-bench Pro | **yes, by template rule** (7/7 non-Python samples) | `git`, usually `build-essential`, often `bash curl` | not found |
| SWE-PolyBench | JS/TS explicit; Java not listed | `git wget curl jq build-essential` | not found |
| Terminal-Bench 2.0 | 46/89 on a Python image, 10 more mention Python tooling, 33/89 none | bare; task-specific | **on**, 89/89 |
| Aider polyglot | yes | full `buildpack-deps` | not restricted |
| SWE-Lancer | yes | `curl git wget patch zip unzip …` | **off** |
| Longtail-SWE (Elixir) | **yes, explicit** | `git curl wget unzip zip build-essential cmake` + Node + Rust | not found |

---

## 4. Standard developer environments

### 4.1 GitHub Actions `ubuntu-24.04` runner

<https://github.com/actions/runner-images/blob/fbb26cb01c3651ea3a0347e54bfa2ef83d740d49/images/ubuntu/Ubuntu2404-Readme.md> — image version `20261111.370.1`, OS 24.04.5. High.

- Language and runtime: Bash 5.2.21, Clang 16/17/18, GNU C++/Fortran 12/13/14, Julia, Kotlin, Node.js 22, **Perl 5.38.2**, **Python 3.12.3**, Ruby 3.2.3, Swift.
- Tools include Git 2.56.1, Git LFS, **jq 1.7**, yq, CMake, Mercurial, Docker, zstd, Ninja.
- "Installed apt packages" (names): `acl aria2 autoconf automake binutils bison brotli bzip2 coreutils curl dbus dnsutils dpkg dpkg-dev fakeroot file findutils flex fonts-noto-color-emoji ftp g++ gcc gnupg2 haveged iproute2 iputils-ping jq libicu-dev libnss3-tools libsqlite3-dev libssl-dev libtool libyaml-dev locales lz4 m4 make mediainfo mercurial net-tools netcat openssh-client p7zip-full p7zip-rar parallel patchelf pigz pkg-config pollinate python-is-python3 rpm rsync shellcheck sphinxsearch sqlite3 ssh sshpass sudo swig systemd-coredump tar telnet texinfo time tk tree tzdata unzip upx wget xvfb xz-utils zip zsync`.

Beyond bare `ubuntu:noble`: `python3`, full `perl`, `jq`, `tree`, `file`, `unzip`, `zip`, `wget`, `curl`, `net-tools`, `make`, `gcc`, `sqlite3`, `git`, `rsync`, `parallel`, `time`, `shellcheck`. **Not listed** in the readme: `ripgrep`, `fd`, `less`, `vim`/`nano`/`ed`, `procps`, `lsof`, `bc`, `xxd`, `gawk`, `patch` (`patch` is a dependency of the listed `dpkg-dev` — Inferred present). The runner is a full Ubuntu Server VM, so unlisted does not mean absent.

### 4.2 `mcr.microsoft.com/devcontainers/base` (Ubuntu)

- Image: <https://github.com/devcontainers/images/blob/66193258c8ebb3d180c2c98a1ea7091e618512f7/src/base-ubuntu/.devcontainer/Dockerfile> — `FROM buildpack-deps:${VARIANT}-curl`, `ENV LANG=C.UTF-8`, features `common-utils:2` and `git:1`.
- `common-utils` 2.7.1 Debian/Ubuntu list: <https://github.com/devcontainers/features/blob/44ebeeaeb5bbeac4c1fab3277acce6db86cbf8f3/src/common-utils/main.sh>:

`apt-utils bash-completion openssh-client gnupg2 dirmngr iproute2 procps lsof htop net-tools psmisc curl tree wget rsync ca-certificates unzip bzip2 xz-utils zip nano vim-tiny less jq lsb-release apt-transport-https dialog libc6 libgcc1 libkrb5-3 libgssapi-krb5-2 libicu[0-9][0-9] liblttng-ust[0-9] libstdc++6 zlib1g locales sudo ncdu man-db strace manpages manpages-dev init-system-helpers bubblewrap slirp4netns util-linux iptables socat` plus `git`, a `libssl` and (optionally) `zsh`.

Beyond bare `ubuntu:noble`: `curl wget git jq tree unzip zip less nano vim-tiny procps lsof net-tools htop rsync strace sudo man-db locales`. **Not in the list:** `python3`, `make`, `gcc`, `patch`, `file`, `bc`, `xxd`, `gawk`, `sqlite3`, `ripgrep`, `fd`. So the plain devcontainer base has no Python either (High for the list; full `perl` arrives with `git` — Inferred).

### 4.3 `buildpack-deps` (noble)

<https://github.com/docker-library/buildpack-deps/tree/fb12875aa41571f6288d524576174843fe738995/ubuntu/noble> (2026-09-18). High.

- `curl`: `ca-certificates curl gnupg netbase sq wget tzdata`
- `scm` adds: `git mercurial openssh-client subversion procps` (comment: "procps is very common in build systems")
- full adds: `autoconf automake bzip2 default-libmysqlclient-dev dpkg-dev file g++ gcc imagemagick lib*-dev… libtool make patch unzip xz-utils zlib1g-dev`

No `python3` line anywhere, but `mercurial` depends on `python3` (<https://packages.ubuntu.com/noble/mercurial>), so `scm` and full carry Python 3 (Inferred). This matters because the default tags of `golang` (`buildpack-deps:<suite>-scm`), `rust`, `node`, `ruby`, `python` and `erlang` (`buildpack-deps:<suite>`) are built on it (templates in `docker-library/golang`, `rust-lang/docker-rust`, `nodejs/docker-node`, `docker-library/ruby`, read from their default branches, not pinned).

### 4.4 GitHub Codespaces universal image

<https://github.com/devcontainers/images/tree/66193258c8ebb3d180c2c98a1ea7091e618512f7/src/universal>. README: it is "the 'universal' image that is used by default if no custom Dockerfile or image is specified" in Codespaces. `FROM ubuntu:noble`, `ENV LANG="C.UTF-8"`, apt: `make unzip build-essential swig3.0 unixodbc-dev libpq-dev default-libmysqlclient-dev moreutils rsync zip libgdiplus jq python3-pip … sqlite3 libsqlite3-dev software-properties-common tk-dev uuid-dev curl gettext inotify-tools`, then `cmake cppcheck valgrind clang lldb llvm gdb python3-dev vim vim-doc xtail libsecret-1-dev fish`. Features: `common-utils`, dotnet, hugo, node 24/22, **python 3.14/3.13 with JupyterLab**, php, conda, ruby, java (+Gradle, Maven), sshd, git, git-lfs, github-cli, copilot-cli, docker-in-docker, kubectl/helm/minikube, go, jekyll, oryx. High.

### 4.5 Docker Official `elixir` image (added: the nearest "standard" Elixir image)

<https://github.com/erlef/docker-elixir/tree/0e268c530b10333abe30aa249aeb22beef8bb464/1.20> and <https://github.com/erlang/docker-erlang-otp/tree/dcff99bf8e6d498f040e504f2c233aa040e3c673/29>. High.

- default tag: `FROM erlang:29` → `FROM buildpack-deps:trixie` (full). So `git curl wget make gcc g++ patch unzip file procps openssh-client`, and Python 3 through `mercurial` (Inferred).
- `-slim`: `FROM erlang:29-slim` → `FROM debian:trixie`; build deps purged. As bare as `hexpm/elixir`.
- `-alpine`: `FROM erlang:29-alpine` → `FROM alpine:3.24`; build deps deleted.
- All three set `ENV LANG=C.UTF-8` with the comment "elixir expects utf8".

`hexpm/elixir` corresponds to the `-slim`/`-alpine` tier, not the default tier that Longtail-SWE and most language-image-based benchmarks build on.

---

## 5. Published evidence that environment and infrastructure gaps move agent benchmark scores

### 5.1 Anthropic — "Quantifying infrastructure noise in agentic coding evals" (2026-02-05)

<https://www.anthropic.com/engineering/infrastructure-noise>. High.

- Measured: Terminal-Bench 2.0 success rate under six container resource configurations, from strict enforcement of the per-task spec (1x) to uncapped; then SWE-bench with RAM varied up to 5x (227 problems × 10 samples).
- Effect: "the gap between the most- and least-resourced setups on Terminal-Bench 2.0 was 6 percentage points (p < 0.01)". Infra error rate fell "from 5.8% at strict enforcement to 0.5% when uncapped". From 1x to 3x the score moved within noise (p = 0.40); from 3x to uncapped "success jumps almost 4 percentage points". SWE-bench: "only 1.54 percentage points higher at 5x than 1x".
- Mechanism relevant here: on `bn-fit-modify`, "some models' first move is to install the standard Python data science stack"; under tight limits "the pod runs out of memory during installation, before the agent writes a single line of solution code"; "Different models have different default approaches, and the resource configuration determines which of those approaches happen to succeed."
- Recommends: specify both a guaranteed allocation and a hard kill threshold per task; report the multiplier; treat resource configuration as "a first-class experimental variable, documented and controlled with the same rigor as prompt format or sampling temperature"; "leaderboard differences below 3 percentage points deserve skepticism until the eval configuration is documented and matched."

### 5.2 Anthropic — "Demystifying evals for AI agents" (2026-01-09)

<https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents>. High.

- "Opus 4.5 initially scored 42% on CORE-Bench, until an Anthropic researcher found multiple issues: rigid grading …, ambiguous task specs, and stochastic tasks … After fixing bugs and using a less constrained scaffold, Opus 4.5's score jumped to 95%." (Grading and scaffold, not missing tools.)
- Recommends "a robust eval harness with a stable environment": "the environment itself doesn't introduce further noise"; "If multiple distinct trials fail because of the same limitation in the environment (like limited CPU memory), these trials are not independent".

### 5.3 Terminal-Bench 2.0 paper — missing executables are the top command failure

arXiv 2601.11868, §4.5 "Command-Level Error Analysis". High.

- Measured: 3,800 failed commands sampled across tasks and models (Terminus 2 scaffold), classified by an LLM judge (GPT-5; 82.0% agreement with 50 author labels).
- Result: "command failures calling executables that are not installed or not in PATH are the most frequent (24.1% of all failures) followed by failures when running executables (9.6%)."
- This is a share of failed *commands*, with the network on so agents can install what is missing. The paper does **not** report how much task success changes. Limitations section: "variability in machine resources and container runtime enforcement can lead to differences in effective task environments."

### 5.4 Anthropic — SWE-bench scaffold describes the environment to the model

"Raising the bar on SWE-bench Verified with Claude 3.5 Sonnet", page dated 2025-01-06: <https://www.anthropic.com/engineering/swe-bench-sonnet>. High.

- The Bash tool description given to the model includes: "You don't have access to the internet via this tool." and "You do have access to a mirror of common linux and python packages via apt and pip."
- "While inspecting failed tasks, we found cases where the model behaved correctly, but there were environment setup issues, or problems with install patches being applied twice. Resolving these systems issues is crucial for getting an accurate picture of an AI agent's performance." No number given.

Claude 3.7 Sonnet announcement, 2025-02-24: <https://www.anthropic.com/news/claude-3-7-sonnet>: "Due to infrastructure limitations, only 489/500 problems are actually solvable on our internal infrastructure (i.e., the golden solution passes the tests)." The 11 were counted as failures for the headline number — a built-in 2.2-point ceiling loss.

### 5.5 OpenAI

- "Introducing SWE-bench Verified" (2024-08-13, updated 2025-02-24): <https://openai.com/index/introducing-swe-bench-verified/>. Third of three named problems: "It is sometimes difficult to reliably set up the SWE-bench development environments for the agents, inadvertently causing unit tests to fail regardless of the solution." Response: a new containerised Docker harness built with the SWE-bench authors. Numbers given are for the annotation campaign as a whole (38.3% flagged for underspecification, 61.1% for unfair tests, 68.3% filtered out; GPT-4o 16% → 33.2%); **the environment share is not separated out.**
- "Introducing GPT-4.1 in the API" (2025-04-14): <https://openai.com/index/gpt-4-1/>: "Our scores omit 23 of 500 problems whose solutions could not run on our infrastructure; if these are conservatively scored as 0, the 54.6% score becomes 52.1%." A stated 2.5-point swing from infrastructure alone.
- "Why SWE-bench Verified no longer measures frontier coding capabilities" (2026-02-23): <https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/>. Mentions that "Depending on setup of the environment (for example Linux vs Windows, or the python version), some tests could spuriously fail"; the quantified findings (59.4% of 138 audited problems) are about test design and contamination, not environment.
- SWE-Lancer README (see 3.8): after making the benchmark run offline, "198 tasks that were adjusted and verified to run successfully offline. We have dropped the remaining 39 problems" — 39 of 237 (16%) did not survive being run without a network.

All three OpenAI pages were read in a browser; they return 403 to plain HTTP clients. High.

### 5.6 SWE-PolyBench paper — an agent scaffold that required Python in the image

arXiv 2504.08703, the section on adapting SWE-agent. High.

- SWE-agent "imposes specific requirements on pre-installed packages, including Python3.11, SWE-ReX, and pipx, within the provided Docker images."
- Layering a standalone Python on the task images "fails for 129 instances due to version incompatibilities between system libraries"; those 129 were moved to the JS base image "which has a comprehensive list of pre-installed packages"; 111 produced predictions and "the rest 18 instances" were scored as empty predictions.

This is the closest published case to "the image lacks Python": the cost was 18 instances scored as failures without an attempt, plus a different image for 129. The paper does not give the denominator for that run in this passage.

### 5.7 HAL — Holistic Agent Leaderboard (Princeton; arXiv 2510.11977)

High.

- Measured: LLM-aided log analysis over 21,730 rollouts; rubric category "environmental barriers".
- Result: "In AssistantBench, CORE-Bench, and SciCode, agents encountered at least one environmental barrier, such as a crashing browser, an unavailable file, or an unavailable coding import, in roughly 40% of failed tasks."
- Caveat they state: they "cannot determine whether addressing these failures would lead to successful task completion".
- Recommends log analysis as "a necessary component of agent leaderboards" and a standardised harness.

### 5.8 METR

- HCAST (arXiv 2503.17354): every task was run five times and all 945 transcripts read; "When agents fail, we confirm that this wasn't for reasons beyond the agent's control, e.g. because they weren't allocated enough compute to solve the task, the necessary packages/resources weren't included, or the task evaluates the submission with unpredictable/unrealistic metrics." Also: "Three tasks only have 2 to 4 runs because the runs frequently encountered infrastructure bugs. These runs are considered invalid". Practice, not an effect size. High.
- "Measuring AI Ability to Complete Long Software Tasks" (arXiv 2503.14499): "a small number of runs failed due to internal infrastructure issues". No number.

### 5.9 SWE-bench harness

- Changelog 5.0.0 (2026-08-17): "Infrastructure failures are labelled in the report, without being removed from the score (#586)". Implementation: <https://github.com/SWE-bench/SWE-bench/blob/02e7a74ffd0b707aab73d203fe87bdc7c76afc8e/swebench/harness/infra_failure.py> — docstring: "Separates 'the environment broke' from 'the model's patch was wrong' … so a broken image is not silently counted as a model failure"; signatures include `network_unreachable`, `out_of_memory`, `missing_module` (ambiguous tier). High.
- The issue that prompted it, <https://github.com/SWE-bench/SWE-bench/issues/586>, is a **third-party** audit claiming 5 of 8 sampled always-failed SWE-bench Pro instances were broken at environment level. Small sample, not confirmed by the maintainers beyond adding the label. Low weight.
- I searched SWE-bench, SWE-agent, mini-SWE-agent and Terminal-Bench issues for missing-tool reports. Hits are single reports (for example SWE-agent #1170, title "'pip not found' for tools/edit_anthropic when running SweBench MultiModal"; title only, body not read). **No maintainer-quantified study of missing tools in SWE-bench images was found.**

### 5.10 Agentic Benchmark Checklist (arXiv 2507.02825)

Academic, with authors of several benchmarks. Checklist item T.1: "For self-hosted tools, it is essential to explicitly specify the correct tool or package versions in the prompt". T.6: "the environment setup should be fully reproducible and frozen at the time of benchmark release". Their per-benchmark audit marks one benchmark down with "The prompt does not specify the versions of important tools, such as Python and Pytorch." High.

### 5.11 What nobody has measured

No primary source was found that holds a benchmark fixed and compares scores with and without Python or general CLI tools in the image. The nearest numbers are: 24.1% of failed commands (Terminal-Bench, network on), about 40% of failed tasks hitting some environmental barrier (HAL, causality not established), 2.2–2.5 points from tasks that cannot run on a vendor's infrastructure (Anthropic, OpenAI), and 6 points from resource headroom (Anthropic).

---

## 6. Closing table: which programs are where

`yes` = installed by a line I read. `(dep)` = Inferred from a package dependency page. `bb` = BusyBox applet. `—` = not installed by anything I read. `n.l.` = not listed, but the image is a full OS so absence is not established.

| Program | bare `ubuntu:noble`/`jammy` | bare `debian:bookworm(-slim)` | bare `alpine:3.22` | `hexpm/elixir` Ubuntu / Debian / Alpine | SWE-bench (Python) image | GH runner `ubuntu-24.04` | `devcontainers/base:ubuntu` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `bash` | yes | yes | — | yes / yes / — | yes | yes | yes |
| `python3` | — | — | — | — / — / — | yes | yes (3.12.3) | — |
| `perl` | `perl-base` | `perl-base` | — | `perl-base` / `perl-base` / — | yes (dep of `git`) | yes (5.38.2) | `perl-base`; full (dep of `git`) |
| `git` | — | — | — | — / — / — | yes | yes | yes |
| `curl` | — | — | — | — / — / — | yes | yes | yes |
| `wget` | — | — | bb | — / — / bb | yes | yes | yes |
| `make` | — | — | — | — / — / — | yes | yes | — |
| `gcc` | — | — | — | — / — / — | yes | yes | — |
| `patch` | — | — | — | — / — / — | (dep of `dpkg-dev`) | (dep of `dpkg-dev`) | — |
| `ps` (procps) | yes | — | bb | yes / — / bb | yes (base) | n.l. | yes |
| `less` | — | — | bb | — / — / bb | not checked | n.l. | yes |
| `jq` | — | — | — | — / — / — | yes | yes | yes |
| `ripgrep`, `fd` | — | — | — | — / — / — | — | n.l. | — |
| `tree` | — | — | bb | — / — / bb | — | yes | yes |
| `file` | — | — | — | — / — / — | — | yes | — |
| `unzip` | — | — | bb | — / — / bb | — | yes | yes |
| `zip` | — | — | — | — / — / — | — | yes | yes |
| `vim`/`vi` | — | — | bb `vi` | — / — / bb `vi` | — | n.l. | `vim-tiny` |
| `nano` | — | — | — | — / — / — | — | n.l. | yes |
| `ed` | — | — | — | — / — / — | — | n.l. | — |
| `lsof` | — | — | bb | — / — / bb | — | n.l. | yes |
| `net-tools` (`netstat`) | — | — | bb `netstat` | — / — / bb | — | yes | yes |
| `bc` | — | — | bb | — / — / bb | — | n.l. | — |
| `xxd` | — | — | bb | — / — / bb | — | n.l. | — |
| `awk` | `mawk` | `mawk` | bb awk | `mawk` / `mawk` / bb | `mawk` | n.l. (`gawk` not listed) | `mawk` |
| `gawk` | — | — | — | — / — / — | — | n.l. | — |
| `sqlite3` CLI | — | — | — | — / — / — | not in apt list | yes | — |
| `grep`/`sed`/`find`/`diff` | GNU | GNU | bb | GNU / GNU / bb | GNU | GNU | GNU |
| `locales` pkg | — (`C.UTF-8` built in) | — (`C.UTF-8` built in) | n/a | — / — / n/a | yes (`locales-all`) | yes | yes |
| `LANG` set | no | no | no | `C.UTF-8` / `C.UTF-8` / **unset** | not set by the Dockerfile | n.l. | `C.UTF-8` |

Two extra columns that are not in the requested set but bear on the decision:

| Program | Docker Official `elixir` (default tag) | Longtail-SWE Elixir base |
| --- | --- | --- |
| `bash`, `git`, `curl`, `wget`, `make`, `gcc`, `patch`, `unzip`, `file`, `ps` | yes (from `buildpack-deps`) | yes |
| `python3` | (dep of `mercurial`) | **yes, explicit**, with `pip` and `venv` |
| `perl` | (dep of `git`) | (dep of `git`) |
| `zip`, `cmake`, Node, Rust | — | yes |
| `jq`, `less`, `tree`, editors | — | — |
| `LANG` | `C.UTF-8` | `C.UTF-8`, `LC_ALL=C.UTF-8`, `ELIXIR_ERL_OPTIONS=+fnu` |

---

## 7. Not verified, or not found

- **Alpine wiki** pages (`BusyBox`, `How to get regular stuff working`): blocked by bot protection; not read. Section 2 rests on BusyBox source and Alpine's build config instead.
- **Layer contents of the actual Hub images.** I read manifests and Dockerfiles, not image layers. For Ubuntu the manifest is Canonical's, published beside the rootfs, dated 2026-11-14. A dated `hexpm` tag pins an older base snapshot; I did not read the manifest for any specific older date, so a package could in principle have entered or left the base since then.
- **Debian `perl-base` file list** — assumed to match Ubuntu's.
- **Regex dialect differences** between musl/BusyBox and GNU (`\b`, `\w`, `\d`, `\+`) — not checked.
- **Network policy** for SWE-bench Multilingual, Multi-SWE-bench, SWE-bench Pro, SWE-PolyBench and Longtail-SWE agents — no statement found. For SWE-bench + mini-SWE-agent it is inferred on from the absence of a restriction.
- **Multi-SWE-bench**: 3 of roughly 2,000 repo modules read. **SWE-bench Pro**: 8 of 731 base Dockerfiles read (8 of 11 repositories). **SWE-PolyBench**: 9 repositories sampled from the dataset.
- **Transitive packages** marked `(dep)` come from Ubuntu noble dependency pages; I did not resolve them for jammy, bookworm, bullseye or trixie.
- **Terminal-Bench 1 base images and the language-image templates** (`golang`, `rust`, `node`, `ruby`) were read from default branches, not pinned commits.
- **`less` in the SWE-bench image** — depends on whether `git`'s recommended packages are installed; not checked.
- **A controlled with/without-Python comparison on any benchmark** — not found (5.11).
- **A maintainer-quantified study of missing tools in SWE-bench images** — not found.
- **OpenAI's environment-specific share** of the SWE-bench Verified filtering — not published.
- **Longtail-SWE task count** differs between the NeurIPS workshop listing (237) and arXiv v2 / the repo (202); I used the latter.
