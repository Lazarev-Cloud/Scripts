# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Standalone system-maintenance scripts — Bash for Linux, PowerShell for Windows, one Python
metrics exporter. Nothing imports anything else; each script is copied onto a host, or piped
in over `curl`, and run as root/Administrator. There is no build step and no test suite. The
only automated gate is `.github/workflows/lint.yml`.

Read `CONTRIBUTING.md` before writing any script here — it is the normative style guide, and
the conventions below are a summary of it, not a substitute.

## Verifying changes

CI runs two linters, both pinned, with zero tolerance for findings. `bash -n`
runs first because a parse error makes the shellcheck output much harder to
read:

```bash
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -r -n1 -t bash -n
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -r shellcheck -s bash
```

```powershell
Invoke-ScriptAnalyzer -Path <file> -Severity Error,Warning,Information
```

A genuine false positive goes in the source as a targeted `# shellcheck disable=SCxxxx` with
a reason — never as a flag in the workflow. PowerShell is linted under Windows PowerShell
5.1, not `pwsh` 7, because that is what the scripts target.

Most scripts need root, a specific distro, or Proxmox. To exercise the logic anyway, put
stubs for the platform commands (`pct`, `apt-get`, `systemctl`) early on `PATH` and drive the
script against them. Beyond that, `<script> --help` and `<script> --dry-run` both work on any
machine and are the fastest way to catch a regression.

## Layout

Every utility is `<platform>/<name>/` holding the script and a `README.md`. The section
indexes (`linux/README.md`, `windows/README.md`, `monitoring/README.md`) and `docs/README.md`
are hand-maintained — adding a script means editing them too. `linux/proxmox/ve/` is the one
folder that nests deeper.

`lib/lzc-obs.sh` is the only shared code. `install.sh` copies the Linux scripts to
`PREFIX/sbin` as `lzc-*` commands and the library to `PREFIX/lib/lzc/`.

## The conventions that cut across every script

These are what make the scripts interchangeable to a wrapper, and they are the things most
likely to be broken by an edit that only looks at one file.

- **Exit codes** come from one table in `docs/exit-codes.md`: `0` success, `1` partial
  failure, `2` usage, `3` unsupported platform or missing tool, `4` needs root, `5` needed
  confirmation with no TTY, `75` lock held, `130` interrupted. Do not invent new ones —
  encode detail in metrics instead. `75` is `EX_TEMPFAIL`, deliberately chosen so cron and
  systemd read lock contention as "retry", not as a fault worth paging on.
- **Environment variables** are `LZC_<FOLDER>_<OPTION>`. `env | grep LZC_` should show a user
  everything they can set.
- **Safe by default**: destructive work prints its plan and needs `--yes`; `--dry-run` wins
  over `--yes`. No script prompts without a TTY — it refuses instead, so cron never hangs.
- **`flock` on `/run/lock/lzc-<script>.lock`** for anything that mutates state; a run that
  loses the race exits `75` and changes nothing. `install.sh` is the exception.
- **`main "$@"` is the last line of every executable file.** Everything above it only defines
  things. This is what makes a truncated `curl | bash` download harmless — see
  `docs/curl-bash.md`. Do not add top-level side effects.

**Two error models, and each script says which it uses in a header comment.** A batch driver
that must survive individual failures (`update-lxcs.sh`, `maintenance.sh`,
`fix_permissions.sh`) uses `set -uo pipefail` and checks every fallible command explicitly. A
linear script that should stop at the first problem uses `set -e`:
`setup_prometheus_exporter.sh` and the two lock doctors use `set -Eeuo pipefail`,
`install.sh` uses `set -euo pipefail`. Adding `set -e`
to a script in the first group reintroduces bugs this repo has already fixed once: it aborted
`update-lxcs.sh` before its own summary printed, because `((n++))` returns 1 when `n` is 0.
Never write `((n++))` as a bare statement; use `n=$((n + 1))`.

**Validate before arithmetic.** Booleans take `1/true/yes/on` and `0/false/no/off` and reject
anything else with exit 2; numbers go through `10#` so `08` is decimal. Skipping this means
`LZC_FOO_YES=true` reaches `(( ))` as a bare word and dies with `true: unbound variable` —
the obvious spelling crashing the script.

**`lib/lzc-obs.sh` may never abort its caller.** It is sourced inside root maintenance
scripts, so every `obs_*` entry point returns 0 — bar `obs_enabled`, a predicate — every
`curl` inside it is `|| true` at the call site, and a malformed setting warns and falls back
to its default rather than exiting. `return 0` at the end of a function is not sufficient:
under `set -e` the shell exits at the failing command and never reaches it. This is the one
place in the repo where a bad setting does not exit 2. Variable *names* taken from config
(`LZC_OBS_TOKEN_ENV`) are validated before `${!name}` touches them — that expansion evaluates
array subscripts, so an unchecked one is a code path.

## The three substantial programs

Everything else is a few hundred lines of flag parsing around one native command.

**`linux/proxmox/ve/update-lxcs.sh`** — updates every LXC container on a Proxmox node, then
optionally every node in the cluster. Cluster mode does not re-download itself on the remote
node: `remote_payload` pipes this node's own script text (plus the inlined obs library, plus
`LZC_*` settings) into `ssh … bash -s --`, so every node provably runs identical code. A
container locked by another PVE task counts as a *failure*, not a skip — it was scheduled for
patching and did not get patched. `_LZC_OBS_LOADED` guards the no-op obs stubs so they cannot
overwrite the real library that was prepended to the remote stream.

**`linux/maintenance/maintenance.sh`** — subcommand-dispatched host maintenance, deliberately
overlapping the small `linux/*` scripts (`clean-logs`, `fix-apt-lock`, …). The standalone
script is the copy-one-file route; this is the everything-in-one route. A behaviour change
usually belongs in both.

**`monitoring/prometheus_unified_metrics.py`** — collector classes emitting through
`prometheus_client`, served over stdlib `http.server`, or written as a node_exporter textfile.
Metric namespace is `hostwatch_` (`NS` at the top of the file). It installs nothing at
runtime: `prometheus_client` is required and its absence is exit 3, `psutil` is optional and
its absence is `hostwatch_collector_up 0` for two collectors. Default bind is `127.0.0.1` —
the endpoint is unauthenticated. `setup_prometheus_exporter.sh` provisions a venv under
`/opt` and a sandboxed systemd unit, and converges on re-run rather than rewriting.

## Documentation rules

Docs describe the current state only — no changelog entries, no "previously this was called
X". Git history is for that. Update the `README.md` next to a script in the same commit as
the script. A script's `--help` is authoritative; if help and code disagree, that is a bug.

The GitHub Pages site is built from these same README files by `_config.yml`, with **no YAML
front matter anywhere on purpose** — GitHub renders front matter as a metadata table rather
than hiding it, and these files are read on GitHub far more than on the site. That rules out
any theme with a generated sidebar, since those build navigation from per-page front matter.
Do not add front matter to make a theme work; change the theme.
