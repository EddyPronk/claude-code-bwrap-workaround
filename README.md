# claude-code-bwrap-workaround

A user-side workaround for [anthropics/claude-code#43454](https://github.com/anthropics/claude-code/issues/43454):
on Ubuntu 26.04, with Claude Code's sandbox enabled, every Bash command fails with

```
apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted; caller must provide CAP_SYS_ADMIN): Permission denied
```

This gets the sandbox running again, with seccomp filtering, without changing AppArmor, sysctls or
anything system-wide. It **reimplements the two seccomp filter rule sets of
[sandbox-runtime](https://github.com/anthropics/sandbox-runtime) at commit `9a277e5e04af`** (2026-10-14).
It does **not** give the command the nested PID and mount namespace that Claude Code's helper sets up: the
command can see bwrap's init, the shell and the `socat` bridges. That's the main trade-off; see Limits.

It's unofficial, not affiliated with or endorsed by Anthropic, and meant to be thrown away once Claude Code
fixes the issue.

Tested on Ubuntu 26.04.1 (kernel 7.0, bubblewrap 0.11.1, stock AppArmor), x86_64, with Claude Code 2.1.300
and 2.1.301. Other releases are untested.

## Compared with `allowAllUnixSockets`

The issue thread's common workaround is `"sandbox": {"network": {"allowAllUnixSockets": true}}`, which
makes Claude Code skip its helper. Measured in the same VM with the same probe (`evidence/verify.log`):

| | `allowAllUnixSockets: true` | this workaround |
|---|---|---|
| filesystem and network limits | kept | kept |
| seccomp mode / filters loaded (`Seccomp`, `Seccomp_filters` in `/proc/self/status`) | disabled (0) / 0 | filtering (2) / 2 |
| `socket(AF_UNIX)`, `socket(AF_VSOCK)`, `io_uring_setup` | allowed | refused |
| new user/mount namespaces, `setns`, mount calls | not filtered (AppArmor's capability stripping still blocks most) | refused by the filter |
| command sees bwrap's init, the shell, the socat bridges | yes | yes |
| AppArmor or sysctl change | none | none |
| install | one setting | three packages, `./install.sh` |

## Install

As an admin, once (Claude Code's sandbox itself needs `bubblewrap` and `socat`):

```
sudo apt install bubblewrap socat python3-seccomp
```

As the user who runs Claude Code (no sudo):

```
git clone https://github.com/EddyPronk/claude-code-bwrap-workaround
cd claude-code-bwrap-workaround
./install.sh
```

It puts the wrapper in `~/.local/bin/bwrap` and the helper in
`~/.local/share/claude-code-bwrap-workaround/seccomp-exec.py`. It won't replace a `~/.local/bin/bwrap`
that isn't its own. `~/.local/bin` must come before `/usr/bin` in the `PATH` that `claude` starts with;
Ubuntu's `~/.profile` adds it only if the folder existed at login, so after a first install `install.sh`
asks you to run `. ~/.profile` in that shell (or log in again) before starting `claude`. It warns only if
a new login shell wouldn't find the wrapper either.

## Check

In Claude Code, with the sandbox enabled, ask it to run in the sandbox (and not to retry outside it):

```
python3 /path/to/claude-code-bwrap-workaround/probe.py
```

Expected: `Seccomp: 2   Seccomp_filters: 2`; `EPERM` for every `socket(AF_UNIX)`, `socket(AF_VSOCK)`,
`io_uring_*`, `unshare`, `clone(CLONE_NEW…)`, `setns` and mount line; `ENOSYS` for `clone3`; `ok` for
`socket(AF_INET)`, `socketpair`, the thread and `fork`.

## Uninstall

```
./install.sh --uninstall
```

## How it works

Claude Code runs each sandboxed command as `bwrap … /bin/bash -c '<script>'`, finding `bwrap` through
`PATH`. The script starts two `socat` bridges, then the command with
`ARGV0=apply-seccomp /proc/self/fd/3 /bin/bash -c '<command>'`: Claude Code's own binary (fd 3), under the
name `apply-seccomp`. The source of that helper is in sandbox-runtime, `vendor/seccomp-src/`:

- **It puts the command in a nested PID and mount namespace**, so the command can't see bwrap's init, the
  shell or the `socat` bridges, and needs `CAP_SYS_ADMIN` for that. Where it doesn't have it, it makes a
  nested user namespace to get it. Its own comment describes this bug: that path "can itself fail on hosts
  where unprivileged user namespaces are gated by an LSM (Ubuntu 24.04's AppArmor restriction, for
  example) — the unshare succeeds but the new namespace grants no capabilities, so the setgroups write
  fails". On Ubuntu, AppArmor's `bwrap-userns-restrict` profile does that on purpose: what bwrap runs gets
  the `unpriv_bwrap` profile, which withholds capabilities.
- **It installs two seccomp filters** (`seccomp-unix-block.c`): "unix" (`socket(AF_UNIX)`,
  `socket(AF_VSOCK)`, `io_uring_*` → EPERM) and "namespaces" (`unshare` and `clone` with new user or mount
  namespaces, `setns`, the mount calls → EPERM, `clone3` → ENOSYS).

Seccomp filters don't need a namespace or a capability: any process may install one once `no_new_privs`
is set, which bwrap does. So:

- **`bwrap`** (the wrapper) replaces the first `ARGV0=apply-seccomp /proc/self/fd/3 /bin/bash -c ` in
  Claude Code's script (the generated invocation; the command's own text, which comes after it, is left
  alone) with `/usr/bin/python3 -I <helper> /bin/bash -c `, and runs the real `/usr/bin/bwrap`. Any other
  call goes to `/usr/bin/bwrap` unchanged. `-I` (isolated mode) keeps `PYTHONPATH`, a `sitecustomize` or
  user site-packages from running code before the filters are in place.
- **`seccomp-exec.py`** installs both filter rule sets with libseccomp, as written in
  `seccomp-unix-block.c` at `9a277e5e04af`, then runs the command. It's a copy of that policy, not the
  filters of the Claude Code version you have installed.

Nothing is granted: AppArmor attaches to `/usr/bin/bwrap`, so the real bwrap runs under Ubuntu's policy
as before.

## Limits

- **No nested PID and mount namespace.** The command shares bwrap's PID namespace with bwrap's init, the
  shell and the `socat` bridges: it can see them, and ptrace them where Yama allows (Ubuntu's default
  allows only a process's own descendants). `allowAllUnixSockets` has the same gap.
- **No `user.max_user_namespaces=0`** inside; the namespaces filter is what refuses new user namespaces.
- **A snapshot of one commit's rules.** It doesn't follow later changes in Claude Code. For comparison,
  Claude Code 2.1.296's own helper, measured where it works (Debian 13), applied only the `AF_UNIX` and
  `io_uring_setup` rules (`evidence/probe-reference-debian-claude-2.1.296.txt`, an older probe).
- **It depends on the exact text** `ARGV0=apply-seccomp /proc/self/fd/3 /bin/bash -c `. If a release
  changes it, the call passes through unchanged and you get the original error back. A missing helper or
  `python3-seccomp` makes it refuse to run the command.
- **Per user, and it depends on `PATH`:** a `claude` started without `~/.local/bin` first (some launchers,
  services) uses `/usr/bin/bwrap` and fails as before. Other programs that find `bwrap` through `PATH`
  reach the wrapper too; without the exact text they get the real bwrap unchanged.
- **x86_64 tested only.** `probe.py` uses x86_64 syscall numbers.

## Evidence

- [`evidence/verify.log`](evidence/verify.log): one run of [`tests/verify.sh`](tests/verify.sh) in an
  Ubuntu 26.04.1 VM (stock AppArmor, Claude Code 2.1.301, signed in; 2026-10-15). Claude Code runs
  `probe.py` and `ps` in its sandbox (1) without the workaround: the `apply-seccomp` error; (3) after
  `./install.sh`: all probed restrictions return the expected errors; (4) with `allowAllUnixSockets`
  instead: no filter. The results shown are Claude Code's own record of each tool result
  (`--output-format stream-json`, read by `tests/results.py`), not the model's summary; the script
  checks 32 of them and exits non-zero if any fails. Settings are passed with `--settings` in a fresh
  folder, with `allowUnsandboxedCommands: false`, so no command can run outside the sandbox.
- [`evidence/wrapper-tests.log`](evidence/wrapper-tests.log): [`tests/wrapper-tests.sh`](tests/wrapper-tests.sh),
  the wrapper and `install.sh` without Claude Code: the filters apply, a `sitecustomize` on `PYTHONPATH`
  can't run first, the marker text inside a command is left alone, a helper path with a space and a
  quote works, a missing helper refuses, `install.sh` won't replace or remove another `bwrap`.

In `verify.log` the test user's home directory is shown as `/home/ubuntu`; nothing else was changed.

To reproduce, on a machine you can change, signed in to Claude Code, with the three packages installed:
`bash tests/verify.sh` and `bash tests/wrapper-tests.sh`. `verify.sh` leaves the workaround installed and
changes no settings file.

## For Claude Code

A possible upstream option, not a drop-in fix: where the nested namespace isn't available, Claude Code
currently aborts, deliberately, rather than run with less isolation. It could instead offer to run with
the filters only (they need just `no_new_privs`), as an explicit reduced-isolation mode that says the PID
and mount isolation is missing.
