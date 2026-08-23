# Exit codes

Every script in this repository uses the same table. A wrapper, a cron job or a
monitoring check can therefore treat them all identically.

There is exactly one addition, and it is a Windows convention rather than a new
invention: `ResetNetwork.ps1` also returns `3010`, which is what Windows itself
uses for "the operation succeeded and needs a reboot to finish". Nothing else
in the repository returns a code outside the table.

| Code | Meaning | What to do |
| ---: | --- | --- |
| `0` | Success. | Nothing. |
| `1` | The work ran, but part of it failed. | Read the output; the script says what failed. |
| `2` | Usage error — unknown flag, or a bad argument value. | Fix the command line. |
| `3` | Unsupported platform, or a required tool is missing. | Install the prerequisite, or run it on the right host. |
| `4` | Must be run as root. | Re-run with `sudo`. |
| `5` | Confirmation needed, but there is no terminal and `--yes` was not given. | Add `--yes` for unattended use. |
| `75` | Another instance holds the lock. | Retry later. Nothing is wrong. |
| `130` | Interrupted (Ctrl-C). | Nothing; the script cleaned up after itself. |

## Why 75

`75` is `EX_TEMPFAIL` from `sysexits.h`. cron and systemd conventionally read it
as "this is transient, try again", which is exactly right for lock contention:
another copy of the script is already doing the work, so the run was not needed
and nothing failed. Using `1` there would page somebody at 03:00 for a
non-event.

## Distinguishing failures

`1` deliberately covers every kind of partial failure. Scripts do not invent
extra codes to encode *which* part failed, because that does not scale and it
makes wrappers fragile. When you need that detail in monitoring, use the
metrics instead — see [observability.md](observability.md). For example
`update-lxcs.sh` reports failed containers and unreachable cluster nodes as
separate metric series while returning `1` for both.

## In a cron job

```bash
#!/usr/bin/env bash
lzc-update-lxcs --cluster --yes
rc=$?
case $rc in
    0)  ;;                                   # fine
    75) ;;                                   # already running, not a fault
    *)  echo "lxc update failed with $rc" >&2; exit "$rc" ;;
esac
```
