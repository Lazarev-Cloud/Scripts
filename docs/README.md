# Using the Scripts

1. Pick the platform folder (`linux`, `windows`) or `monitoring`.
2. Read the README next to the script.
3. Run the script with `--help` (Bash) or `Get-Help` (PowerShell) — that output
   is the authoritative reference for flags, environment variables, exit codes
   and blast radius.

Most scripts need administrative privileges.

## Running them

```bash
cd linux/update_upgrade
sudo ./update_upgrade.sh --help     # what it does and what it touches
sudo ./update_upgrade.sh -n         # dry run: print the plan, change nothing
sudo ./update_upgrade.sh --yes      # apply, unattended
```

```powershell
cd windows\Winget
Get-Help .\WingetFix.ps1 -Full
.\WingetFix.ps1 -WhatIf
```

```bash
cd monitoring
python3 prometheus_unified_metrics.py --once   # print one exposition, exit
sudo ./setup_prometheus_exporter.sh --dry-run  # plan the install
```

## Conventions

These hold across the Bash scripts:

- **Safe by default.** Anything destructive prints its plan and does nothing
  until you pass `-y`/`--yes`. `-n`/`--dry-run` forces report-only and wins
  over `--yes`.
- **No prompt without a terminal.** Every script that prompts guards the
  prompt with a TTY check and refuses instead of hanging. `clean_logs` and
  `network_restart` never prompt at all — they simply do nothing without
  `--yes`. Either way they are safe to run from cron.
- **Most flags have an environment variable**, which is the practical route
  when piping a script in over `curl`. Every one is named
  `LZC_<SCRIPT>_<SETTING>`; the exact prefix is in the script's README.
  `--dry-run` and `--color` are the exceptions — every script has both flags,
  but only some expose them as variables.
- **stdout is the report, stderr is problems.** Colour only when stdout is a
  terminal, and `--color never` disables it everywhere. `NO_COLOR` is honoured.
- **The slow, blocking calls run under `timeout`** — package transactions,
  `journalctl`, `du`, probes into a container. Local helpers such as `find`,
  `rm` and `sleep` generally are not wrapped.
- **Concurrent runs are refused** via `flock`, not queued: a run that loses the
  race exits `75` and changes nothing. Every script that touches the system
  takes a lock, and the path is overridable — with its `_LOCK` variable, or
  `_SELF_LOCK` in the two lock doctors, where the name distinguishes the
  script's own lock from the package-manager lock it is inspecting.
  `install.sh` is the exception — it takes no lock.
- **`main "$@"` is the last line of every executable script**, so a truncated
  download never executes a partial program. (`lib/lzc-obs.sh` is sourced, not
  executed: it defines functions and, as its last statement, normalises its own
  `LZC_OBS_*` settings. It touches nothing else.)

PowerShell scripts use the platform equivalents: `SupportsShouldProcess`, so
`-WhatIf` previews and `-Confirm`/`-Force` gate the change; they are read-only
until told otherwise, and they refuse rather than prompt when non-interactive.

## Exit codes

One table covers the whole repository — see [exit-codes.md](exit-codes.md).
`0` success, `1` partial failure, `2` usage error, `3` unsupported platform or
missing prerequisite, `4` must be root, `5` refused for want of confirmation,
`75` another instance holds the lock, `130` interrupted. A wrapper can treat
every script identically.

Two things to know before wiring one into alerting:

- **`75` is not a fault.** Another copy was already doing the work. Retry
  later; do not page on it.
- **`ResetNetwork.ps1` also returns `3010`** when a reset needs a reboot to
  finish. It is the only script in the repo that returns a code outside the
  table, and both its `.NOTES` and its README say so.

The `Exit status` section of each script's `--help` lists what that particular
script means by each code.

## Running from the network

Fetch, verify, then run — pin to a commit SHA and check the hash first. A
branch name is not a pin: it means "whatever was pushed most recently",
executed as root. See
[linux/proxmox/ve/README.md](../linux/proxmox/ve/README.md) for the full
pattern, including why `bash -c "$script"` needs a `--` before its flags.
