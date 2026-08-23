# Local checks

`run_checks.sh` runs what CI runs, against your working tree, before you push.

```bash
./tests/run_checks.sh          # everything
./tests/run_checks.sh --quiet  # failures and the summary only
```

Read-only. It needs no root and changes nothing.

## What it checks

| Check | Also in CI | Notes |
| --- | :---: | --- |
| `bash -n` | yes | Same file discovery as the workflow. |
| `shellcheck` | yes | Warns when your local version differs from the pinned one. |
| `py_compile` | yes | The monitoring exporter. |
| YAML | no | Every workflow, plus `_config.yml`. |
| `--help` | no | Every executable script must answer `--help` with status `0`. |
| Executable bits | no | Every runnable `*.sh` must be committed `100755`. |
| PSScriptAnalyzer | yes | Only when `pwsh` is present, and **indicative only** — see below. |

The three CI cannot do are the point of running this locally.

**`--help`** executes each script. ShellCheck reads code; it does not run it, so
a script that dies on an unset variable before printing anything is clean to
ShellCheck and broken to a user. This catches that.

**Executable bits** exist because every README documents `./script.sh`. A script
committed `100644` answers that with `Permission denied` on a fresh clone, and
nothing else in the pipeline notices — this repository shipped exactly that bug
once.

**PSScriptAnalyzer** runs under `pwsh` 7 here, while CI analyses under Windows
PowerShell 5.1, which is what the scripts target. The two parse some constructs
differently, so a clean result locally is encouraging, not conclusive. On a
machine without `pwsh` the check is skipped.

A check whose tool is missing is reported as **skipped**, never as passed. The
summary lists them, so "all passed" always means "all that actually ran".

## Version pinning

The ShellCheck version is read out of `.github/workflows/lint.yml` rather than
repeated here. Two copies of a pinned version is one copy that goes stale, and a
local run that quietly uses a different ShellCheck than CI is worse than no
local run: it produces a clean result CI then contradicts.

## Exit status

`0` everything that ran passed · `1` something failed · `2` usage error ·
`3` not run from a checkout. The shared table is in
[docs/exit-codes.md](../docs/exit-codes.md).
