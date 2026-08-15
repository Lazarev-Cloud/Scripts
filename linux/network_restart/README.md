# Restart Network Interface

`network_restart.sh` restarts a single network interface and verifies it came
back. It detects which subsystem owns the interface, warns when the interface
carries your SSH session, and arms a rollback **before** taking the link down so
a bad bounce recovers without anyone at the console.

It changes nothing unless you pass `--yes`.

## Requirements

Linux with `iproute2` (`ip`) and `timeout`. An applying run also needs `flock`
(util-linux) for the concurrency lock. `nmcli`, `networkctl` and `ifup` are used
when the interface is managed by NetworkManager, systemd-networkd or ifupdown.
`systemd-run` is used for the rollback when available, `setsid` otherwise.
`ping` is used for the connectivity check when present. Root is required for
`--yes`; the plan can be printed by any user.

## Running it

```bash
./network_restart.sh eth0                    # print the plan, change nothing
sudo ./network_restart.sh eth0 --yes         # restart it
sudo ./network_restart.sh eth0 --yes --force # ... even if it carries your SSH session
sudo ./network_restart.sh --interface vmbr0 --yes --rollback 300
```

There is no prompt in either direction. The default is a plan, so a run without
`--yes` is always safe, and a run with `--yes` never blocks waiting for a
terminal that cron does not have.

## Why this is dangerous, and what protects you

Taking an interface down over SSH is the classic way to lose a remote host. The
original one-liner form of this script — `ifconfig eth0 down; ifconfig eth0 up`
— fails in exactly that way: the moment `down` runs, the SSH connection dies,
the shell gets SIGHUP, and `up` never executes. The host is gone until someone
walks to it.

Five things address that:

1. **SIGHUP is ignored** (`trap '' HUP`). An *ignored* signal disposition is
   inherited across `execve()`, so `ip`/`nmcli`/`ifup` children ignore it too. A
   dropped SSH session cannot kill the run between "down" and "up".
2. **The rollback is armed before the link goes down**, not after. If the script
   dies, is killed, or never reaches verification, the rollback still fires.
3. **The rollback is cancelled only after verification passes.** Failure leaves
   it armed on purpose, and the script says so.
4. **SSH-session detection understands topology**, not just IP ownership.
5. **An applying run holds an exclusive lock**, so two operators — or an
   operator and a cron job — cannot bounce the same host at once.

### The topology part

Checking "does the SSH server IP live on this interface" is not enough. On a
Proxmox host the session IP sits on `vmbr0` while the physical NIC is `enp1s0`;
bouncing `enp1s0` drops the bridge's uplink and strands the box even though the
IP is not on `enp1s0`. Bonds and VLANs have the same shape.

So the target is treated as carrying the session when it is the session
interface, is anywhere in that interface's master chain, has it in *its* master
chain, or shares a master with it. Anything undetermined counts as carrying it.
That case requires `--force`.

`SSH_CONNECTION` is read first, and the parent process chain is walked as a
fallback — `sudo` scrubs `SSH_*` from the environment, which is the single most
common invocation.

## The rollback

A small recovery script is written to `/run/network-restart/` and scheduled to
run after `--rollback` seconds (default 120, `0` disables it):

```
ip link set dev <iface> up
<manager-specific bring-up, e.g. nmcli device connect <iface>>
# only if this interface owned a default route and none exists by then:
ip route add default via <recorded gateway> dev <iface>
```

It is scheduled as a transient `systemd-run --on-active=` unit where systemd is
running, so it lives in its own cgroup and survives both the SSH session and
this script being killed. Where systemd is not available it is a detached
`setsid` process. Either way it checks a cancel token first, so cancellation is
reliable even if stopping the unit fails.

Only a default route that **this interface itself owned** is ever recreated. The
host's default gateway is recorded separately and used only as a ping target;
conflating the two is how bouncing a bridge port ends up re-adding the bridge's
default route via the wrong device.

## Locking

An applying run takes an exclusive `flock` on
`/run/lock/lzc-network-restart.lock` and exits **75** if another instance
already holds it. 75 is `EX_TEMPFAIL`, which cron and systemd read as "retry
later" rather than as a fault.

The lock is taken at the last possible moment — after the plan is printed and
after the SSH-session refusal, immediately before the rollback is armed. That
ordering is deliberate:

- a plan takes no lock at all, so printing one is never blocked by, and never
  blocks, a run that is genuinely bouncing something;
- a run refused for exit 5 changes nothing whatsoever, not even creating the
  lock file, and reports 5 rather than the 3 a host without `flock` would
  otherwise report for what is really a safety refusal;
- a run that loses the race exits 75 before arming or bouncing anything, so the
  interface state it read a moment earlier is discarded rather than acted on.

The lock file is never deleted: if one process unlinked it and the next
recreated it, two processes could hold locks on different inodes at the same
path.

## Managers

Detected in this order, and overridable with `--manager`:

| Manager | Detected by | Restart |
| --- | --- | --- |
| `networkmanager` | `NetworkManager` active and the device is not `unmanaged` | `nmcli device disconnect` / `connect` |
| `networkd` | `systemd-networkd` active and the link is configured | `networkctl down` / `up`, falling back to `ip link` |
| `ifupdown` | the interface appears in `/etc/network/interfaces{,.d/*}` | `ifdown` / `ifup` |
| `iproute2` | fallback | `ip link set dev … down` / `up` |

`networkctl up`/`down` is not present in every systemd release; availability is
probed by trying it and falling back, rather than by parsing a version number.

The `iproute2` fallback bounces the link only. It does not renew a DHCP lease or
re-apply manager configuration — if the interface is managed, let it be
detected rather than forcing `--manager iproute2`.

## Verification

After the bounce, in order:

1. the link reaches state `UP` (or `UNKNOWN`, which is normal for some devices)
   within `--wait` seconds;
2. a global IPv4 address returns within `--wait` seconds — **only if the
   interface had one before**, so an unnumbered bridge port is not failed;
3. `ping` to `--check-host` succeeds. `auto` uses the default gateway recorded
   *before* the bounce, `none` skips the check.

Everything checked here is captured during preflight. Reading the default
gateway afterwards would be useless: taking the interface down removes the
route, so the check would silently degrade to "the link is up" and call a dead
network healthy.

## Blast radius

Every connection through the interface drops. If it carries your SSH session you
**will** be disconnected, and if it does not come back you lose the host until
someone reaches its console — that case requires `--force`.

Nothing else is touched: no other interface, no firewall, no routing beyond
restoring this interface's own default route if it is missing afterwards.
Configuration files are never written.

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-i, --interface NAME` | `LZC_NETWORK_RESTART_INTERFACE` | Interface to restart. May also be positional. |
| `-y, --yes` | `LZC_NETWORK_RESTART_YES` | Actually do it. Without it, this is a plan. |
| `-n, --dry-run` | — | Plan only (the default). Wins over `--yes`. |
| `-f, --force` | `LZC_NETWORK_RESTART_FORCE` | Proceed even when the interface carries this SSH session. |
| `--manager NAME` | `LZC_NETWORK_RESTART_MANAGER` | `auto`, `networkmanager`, `networkd`, `ifupdown`, `iproute2`. |
| `--rollback SECONDS` | `LZC_NETWORK_RESTART_ROLLBACK` | Rollback delay; `0` disables it (120). |
| `--wait SECONDS` | `LZC_NETWORK_RESTART_WAIT` | How long to wait, after the bounce, for the interface to come back — first for the link to reach `UP`, then for a global IPv4 address to return if it had one. Minimum 1 (60). |
| `--check-host HOST` | `LZC_NETWORK_RESTART_CHECK_HOST` | Ping target; `auto` or `none` (auto). |
| `--timeout SECONDS` | `LZC_NETWORK_RESTART_TIMEOUT` | Bounds each individual command — one `nmcli`/`networkctl`/`ifup`/`ip` invocation, or the ping. **Not** the wait for the interface to return, which is `--wait`. Minimum 1 (30). |
| `--color WHEN` | — | `auto`, `always`, `never`. |
| — | `LZC_NETWORK_RESTART_SETTLE` | Seconds between down and up (2). |
| — | `LZC_NETWORK_RESTART_PING_COUNT` | Ping packets. Minimum 1 (3). |
| — | `LZC_NETWORK_RESTART_STATE_DIR` | Rollback state directory (`/run/network-restart`). |
| — | `LZC_NETWORK_RESTART_LOCK` | Lock file (`/run/lock/lzc-network-restart.lock`). |
| `-V, --version` | — | Print version and exit. |
| `-h, --help` | — | Print help and exit. |

Every variable a user may set is `LZC_NETWORK_RESTART_*`, so `env | grep LZC_`
shows everything that is configurable.

Boolean variables (`LZC_NETWORK_RESTART_YES`, `LZC_NETWORK_RESTART_FORCE`)
accept `1/true/yes/on` and `0/false/no/off`, case-insensitively; an empty value
means off. Anything else is a usage error, not a crash — writing the obvious
`=true` in a cron file must not fail with `true: unbound variable`.

Numeric variables must be whole numbers and are read as decimal, so a
zero-padded `08` is 8 rather than an invalid octal literal. Values handed to
`timeout(1)` have a minimum of 1, because `timeout 0` means *no* limit and would
silently remove the protection the option exists to provide.

`NO_COLOR` (any non-empty value, per [no-color.org](https://no-color.org))
disables colour, as does a non-terminal stdout. `--color always` overrides both.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Plan printed, or the interface came back and verification passed. |
| 1 | The bounce or the verification failed — **the rollback is left armed**. |
| 2 | Usage error: unknown flag, missing option value, or a bad value — including an interface that does not exist on this host. |
| 3 | A prerequisite is missing: `ip`, `timeout`, or `flock`. |
| 4 | `--yes` was given by a user who is not root. |
| 5 | Refused: the target interface carries this SSH session and `--force` was not given. Nothing was changed. |
| 75 | Another instance holds the lock (`EX_TEMPFAIL`, so cron and systemd treat it as "retry later" rather than a real fault). |
| 130 | Interrupted (SIGINT/SIGTERM) — **the rollback is left armed**. |

Exit 1 and exit 130 mean the host is mid-recovery, not that it is broken: wait
out the rollback window before reconnecting. Exit 5 is the only refusal that
changes nothing at all.

## Notes and limits

- The rollback restores *connectivity*, not *configuration*. It brings the
  interface back up and re-adds the default route it owned. It does not undo
  changes you made to config files — this script never makes any.
- A rollback scheduled with `setsid` (no systemd) does not survive a reboot. One
  scheduled with `systemd-run` does not either; both live in `/run`.
- Sibling ports of the same bridge or bond are treated as carrying the session,
  because which port actually forwards traffic cannot be read from
  configuration. That is deliberately conservative — use `--force` when you know
  better.
- IPv6-only hosts: the address check and the `auto` ping target are IPv4. Pass
  `--check-host <v6 address>` or `--check-host none`.
- For a change you expect to be risky, run it under
  `systemd-run --collect --same-dir --pty ./network_restart.sh …` so the whole
  run lives outside your login session.
