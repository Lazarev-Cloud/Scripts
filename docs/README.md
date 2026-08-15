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
  when piping a script in over `curl`. The prefix is per-script; see its
  README. `--dry-run` and `--color` are the usual exceptions — only some
  scripts expose those two as variables.
- **stdout is the report, stderr is problems.** Colour only when stdout is a
  terminal, and `--color never` disables it everywhere.
- **The slow, blocking calls run under `timeout`** — package transactions,
  `journalctl`, `du`, probes into a container. Local helpers such as `find`,
  `rm` and `sleep` generally are not wrapped.
- **Concurrent runs are refused** via `flock`, not queued — except
  `fix_permissions` and `network_restart`, which take no lock.
- **`main "$@"` is the last line of every executable script**, so a truncated
  download never executes a partial program. (`lib/lzc-obs.sh` is a sourced
  library and defines functions only.)

PowerShell scripts use the platform equivalents: `SupportsShouldProcess`, so
`-WhatIf` previews and `-Confirm`/`-Force` gate the change; they are read-only
until told otherwise, and they refuse rather than prompt when non-interactive.

## Exit codes differ between scripts

There is no single repo-wide exit-code table. `0` always means success and `2`
is usually a usage error, but the rest is per-script — the same number does
not mean the same thing everywhere. Notably:

- "no terminal and no `--yes`" is `4` in `fix_apt_lock`, `fix_dnf_lock`,
  `fix_permissions` and `maintenance`, but `2` in `fix_broken_packages` and
  `update_upgrade`.
- "root required" is `5` in `fix_broken_packages` and `update_upgrade`, `3` in
  `fix_permissions`, and `2` in `clean_logs` and `network_restart`.
- `4` means "not an APT system" in the two APT scripts, but "installed and the
  service did not serve /metrics" in the exporter installer.
- Lock contention is `75` (`EX_TEMPFAIL`) in most scripts; the Proxmox updater
  exits `1`.

Read the `Exit status` section of the script's `--help` before wiring one into
alerting.

## Running from the network

Fetch, verify, then run — pin to a commit SHA and check the hash first. A
branch name is not a pin: it means "whatever was pushed most recently",
executed as root. See
[linux/proxmox/ve/README.md](../linux/proxmox/ve/README.md) for the full
pattern, including why `bash -c "$script"` needs a `--` before its flags.
