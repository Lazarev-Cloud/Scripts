# Running a script straight from the network

Every script here can be fetched and run in one command. That convenience is
also the most dangerous way to run anything as root, so this page explains what
the risks actually are and gives the form that avoids them.

## The short answer

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/<path-to-script>

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/lzc.sh "$URL" \
  && echo "$SUM  /tmp/lzc.sh" | sha256sum -c - \
  && sudo bash /tmp/lzc.sh --help
```

Get the two values from a checkout:

```bash
git rev-parse HEAD
sha256sum <path-to-script>
```

## Why pin a commit SHA

A URL containing `refs/heads/main` means "whatever was pushed most recently",
executed as root, on every host that runs it. Any bad commit reaches every
machine on its next run.

A tag is not a pin either: tags can be moved. A commit SHA is content-addressed
— the content cannot change without the SHA changing — so it is the only
reference that survives someone gaining write access to the repository.

For the same reason, a checksum published in this repository, on the same
branch, is worth little on its own: whoever could alter the script could alter
the checksum next to it. Record the SHA and hash somewhere you control, once,
and reuse them.

## The one-liner, done properly

```bash
s=$(curl -fsSL --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/<SHA>/<path>") \
  && [ -n "$s" ] && sudo bash -c "$s" -- --yes
```

Three details, each load-bearing:

**`&& [ -n "$s" ]`** — without it, a failed download leaves an empty string,
`bash -c ""` exits **0**, and the run reports success having done nothing. This
is the failure mode worth caring about, because it is silent: cron records a
clean run and monitoring stays green while no machine was ever updated.

**`--` before the flags** — `bash -c "$script" foo` assigns `foo` to `$0`, not
`$1`. Without a placeholder the first real argument is swallowed. Environment
variables avoid the problem entirely:

```bash
LZC_UPDATE_LXCS_CLUSTER=1 LZC_UPDATE_LXCS_YES=1 sudo -E bash -c "$s"
```

**`$(...)` rather than a pipe** — `curl … | bash` consumes stdin, so the script
cannot prompt you and cannot read a password. Command substitution leaves stdin
attached to your terminal. It also buffers the whole script before bash parses
it, which matters below.

## Truncated downloads

A connection that dies mid-transfer can hand bash a partial script. Two things
protect against it, and both are already true here:

1. Bash parses the entire `-c` string before executing any of it, so a cut
   inside a function is a syntax error and nothing runs at all.
2. Every script in this repository ends with `main "$@"` as its **last line**.
   A cut at any earlier line therefore defines some functions and then reaches
   the end of input without ever calling one.

If you write your own scripts in this style, keep that property. It is the
difference between a truncated download doing nothing and a truncated download
doing half of something.

## What this cannot protect you from

Pinning and checksums prove you ran *the bytes you intended*. They say nothing
about whether those bytes are safe. Read the script, or at least its `--help`
and its README's blast-radius section, before running it as root on a machine
you care about.

## The alternative: install once

If you run these regularly, installing is both safer and more convenient —
there is one artifact to verify instead of one per invocation:

```bash
git clone https://github.com/Lazarev-Cloud/Scripts
cd Scripts && git checkout <SHA>
sudo ./install.sh
```

See [the installer](../install.sh) and the root [README](../README.md).
