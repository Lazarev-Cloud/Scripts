# Lazarev Cloud Scripts

Maintenance and troubleshooting utilities for Linux and Windows hosts. Each
script lives in its own folder with a README covering its flags, environment
variables, exit codes and blast radius.

```
.
├── linux/       # Bash utilities (9 script folders)
├── windows/     # PowerShell utilities (10 script folders)
├── monitoring/  # Prometheus host-metrics exporter and its installer
├── lib/         # Shared Bash library (optional log/metric shipping)
├── docs/        # Conventions common to every script
└── install.sh   # Installs the Linux scripts as lzc-* commands
```

- [linux/README.md](linux/README.md) — Linux scripts
- [windows/README.md](windows/README.md) — Windows scripts
- [monitoring/README.md](monitoring/README.md) — metrics exporter and installer
- [docs/README.md](docs/README.md) — how to run these safely

## What to expect

Scripts that change the system are safe by default: they print what they would
do and need `--yes` (Bash) or `-Force`/confirmation (PowerShell) before acting.
The one exception is `ResetNetwork`, whose default `DnsCache` scope flushes the
DNS resolver cache without prompting. All of them support `-h/--help`, and the
help text is the
authoritative reference for that script — flags, environment variables, exit
codes and exactly what it touches.

Scripts run unattended from cron or Task Scheduler: they detect a missing
terminal and refuse to prompt rather than hanging. Every flag also has an
environment variable named `LZC_<SCRIPT>_<SETTING>`, which is how you configure
a script piped in over `curl` or driven from Intune. All of them report the
same [exit codes](docs/exit-codes.md).

`./install.sh` copies the Linux scripts to `/usr/local/sbin` as `lzc-*`
commands with bash completion; `--uninstall` removes them again. It only copies
files already on the machine and never downloads anything.

## Quality bar

`.github/workflows/lint.yml` runs ShellCheck over every `.sh` and
PSScriptAnalyzer over every `.ps1` on each push and pull request. Both are
pinned and both currently report zero findings; any new finding fails the
build.

## License

MIT — see [LICENSE](LICENSE).
