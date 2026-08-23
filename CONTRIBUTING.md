# Contributing

These are maintenance scripts that people run as root on machines they care
about. That single fact drives every rule below.

## The bar

A script here must be safe to hand to a stranger. Concretely:

- It says what it will do before it does it.
- It changes nothing destructive without `--yes` or an interactive confirmation.
- It can be run from cron with no terminal, and returns a meaningful exit code.
- Its `--help` is accurate. If the help and the code disagree, that is a bug.
- `shellcheck` reports zero findings. `PSScriptAnalyzer` reports zero findings.

CI enforces the last one. The rest is on review.

## House style for shell scripts

**Pick one error model and say which.** Put a comment at the top explaining the
choice.

- A script that must survive individual failures and keep going (a batch driver,
  a fleet updater) uses `set -uo pipefail` and checks every fallible command
  explicitly.
- A linear script that should stop at the first problem (an installer) uses
  `set -euo pipefail`.

Never depend on the caller writing `|| true` to disable `set -e` inside your
functions. That makes error handling non-local: the same line behaves
differently depending on how the function was called, which is exactly how a
summary report silently stopped printing in an earlier version of this repo.

**Never write `((n++))` as a bare statement.** It returns exit status 1 when `n`
is 0, which terminates the script under `set -e`. Use `n=$((n + 1))`.

**`main "$@"` is the last line of the file.** Everything above it defines
functions and constants. This is what makes a truncated download harmless — see
[docs/curl-bash.md](docs/curl-bash.md). Do not put side-effecting code at the
top level.

**Validate input before arithmetic.** A boolean environment variable must accept
`1/true/yes/on` and `0/false/no/off` and reject anything else with exit 2.
Without that, `LZC_FOO_YES=true` reaches `(( ))` as a bare word and dies with
`true: unbound variable` — a crash a user hits by writing the obvious thing.
Normalise numbers through `10#` so `08` is decimal rather than invalid octal.
This applies to a sourced library as much as to a script, with one change: a
library validates the same way but *warns and falls back to the default*
instead of exiting, because it does not own the caller's exit status.

**A sourced library must not be able to abort its caller.** Every entry point
returns 0 and every fallible command inside it is handled at the call site.
`return 0` at the end of the function is not enough — under `set -e` the shell
exits at the failing command and never reaches it. `lib/lzc-obs.sh` is the
worked example: it runs inside root maintenance scripts, so a dead log
collector must cost a warning on stderr and nothing else.

**Anything that can hang gets a `timeout`.** And a timeout value must be at
least 1: `timeout 0` means *no limit*, which silently removes the protection.

**Nothing hardcoded.** Paths, endpoints, sizes and limits come from environment
variables or flags, with sensible defaults.

**Secrets are never arguments.** Process arguments are readable by every user on
the machine. Take the *name* of an environment variable, and pass the value
through a mode-0600 file or stdin. See `lib/lzc-obs.sh` for the pattern.

## Conventions

| Thing | Rule |
| --- | --- |
| Exit codes | The shared table in [docs/exit-codes.md](docs/exit-codes.md). Do not invent new ones. |
| Environment variables | `LZC_<FOLDER>_<OPTION>`, folder name uppercased. `env \| grep LZC_` should show a user everything they can set. |
| Colour | Only when stdout is a TTY. Honour `NO_COLOR`. Offer `--color auto\|always\|never`. |
| Locking | Any script that mutates state takes an `flock` on `/run/lock/lzc-<script>.lock` and exits 75 if held. |
| Output streams | Errors and warnings to stderr, normal output to stdout. |
| Logs and metrics | Optional, via `lib/lzc-obs.sh`. See [docs/observability.md](docs/observability.md). |

## PowerShell

Do not bolt a Unix flag interface onto PowerShell. Use `[CmdletBinding()]`,
typed and validated `param()` blocks, `SupportsShouldProcess` with `-WhatIf` and
`-Confirm` for anything destructive, and comment-based help so `Get-Help` works.
The exit-code table still applies.

## Before you open a pull request

```bash
shellcheck -s bash <changed files>      # must be silent
bash -n <changed files>                 # must be silent
<script> --help                         # read it; does it match the code?
<script> --dry-run                      # does it describe the right thing?
```

For PowerShell:

```powershell
Invoke-ScriptAnalyzer -Path <file> -Severity Error,Warning
```

Update the `README.md` next to the script in the same commit. Docs describe the
current state only — no changelog entries, no "previously this was called X".
That is what git history is for.

## Testing without the target platform

Most of these scripts need a specific OS, root, or hardware. You can still test
the logic: put stubs for the platform commands (`pct`, `apt-get`, `systemctl`)
early on `PATH` and drive the script against them. That is how the Proxmox
updater's cluster handling, container lifecycle and interrupt cleanup are
verified without a Proxmox host.

State plainly in your PR which parts you executed and which you only reasoned
about. "I could not test this on real hardware" is a fine thing to say. Claiming
something works when you did not observe it is not.
