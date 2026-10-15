#!/usr/bin/python3
"""seccomp-exec.py COMMAND [ARG...] — install Claude Code's two seccomp filters, then exec COMMAND.

Stands in for Claude Code's apply-seccomp on Ubuntu 26.04 (anthropics/claude-code#43454), with
libseccomp (python3-seccomp) instead of hand-written BPF. The rules mirror
anthropics/sandbox-runtime vendor/seccomp-src/seccomp-unix-block.c at commit 9a277e5e04af
(2026-10-14), one for one:

- "unix": socket(AF_UNIX) and socket(AF_VSOCK) fail with EPERM; io_uring_setup, io_uring_enter and
  io_uring_register fail with EPERM (IORING_OP_SOCKET would create sockets past the socket() rule).
- "namespaces": unshare with CLONE_NEWUSER, CLONE_NEWNS or UNSHARE_EMPTY_MNTNS, and clone with
  CLONE_NEWUSER or CLONE_NEWNS, fail with EPERM; clone3 with ENOSYS (its flags are in a struct a
  filter can't read; libc then falls back to clone); setns and the mount calls with EPERM.

What it can't copy, because it needs the nested user namespace Ubuntu forbids: apply-seccomp also
puts the command in its own PID and mount namespace (it can't see or ptrace bwrap's init, the shell
or the socat bridges) and sets user.max_user_namespaces=0 there. See README.md.
https://github.com/EddyPronk/claude-code-bwrap-workaround
"""
import errno
import socket
import sys
import os

try:
    import seccomp
except ImportError:
    sys.exit("seccomp-exec.py: needs python3-seccomp (sudo apt install python3-seccomp); "
             "not running the command unfiltered")

if len(sys.argv) < 2:
    sys.exit("usage: seccomp-exec.py COMMAND [ARG...]")

CLONE_NEWUSER, CLONE_NEWNS, UNSHARE_EMPTY_MNTNS = 0x10000000, 0x00020000, 0x00100000
AF_VSOCK = 40
# Calls newer than some libseccomp releases: by number where the name is unknown (same on every
# architecture since Linux 5.1), as seccomp-unix-block.c does.
BY_NUMBER = {"mount_setattr": 442, "open_tree_attr": 467}


def resolve(name):
    """The name if this libseccomp knows it, else its number (BY_NUMBER). libseccomp 2.6.0 doesn't
    raise for an unknown name: it returns a negative number (seen for open_tree_attr)."""
    try:
        known = seccomp.resolve_syscall(seccomp.Arch.NATIVE, name) >= 0
    except Exception:
        known = False
    if known:
        return name
    if name in BY_NUMBER:
        return BY_NUMBER[name]
    sys.exit(f"seccomp-exec.py: this libseccomp can't name {name}; not running the command")


def flag_rules(f, action, name, flags):
    """One rule a flag, masked, so other flags beside it don't matter (as the C code does)."""
    for bit in range(64):
        flag = 1 << bit
        if flags & flag:
            f.add_rule_exactly(action, resolve(name), seccomp.Arg(0, seccomp.MASKED_EQ, flag, flag))


EPERM, ENOSYS = seccomp.ERRNO(errno.EPERM), seccomp.ERRNO(errno.ENOSYS)

unix = seccomp.SyscallFilter(defaction=seccomp.ALLOW)
for family in (socket.AF_UNIX, AF_VSOCK):
    unix.add_rule(EPERM, "socket", seccomp.Arg(0, seccomp.MASKED_EQ, 0xFFFFFFFF, family))
for name in ("io_uring_setup", "io_uring_enter", "io_uring_register"):
    unix.add_rule(EPERM, name)

namespaces = seccomp.SyscallFilter(defaction=seccomp.ALLOW)
flag_rules(namespaces, EPERM, "unshare", CLONE_NEWUSER | CLONE_NEWNS | UNSHARE_EMPTY_MNTNS)
flag_rules(namespaces, EPERM, "clone", CLONE_NEWUSER | CLONE_NEWNS)
namespaces.add_rule_exactly(ENOSYS, resolve("clone3"))
for name in ("setns", "mount", "umount2", "pivot_root", "open_tree", "move_mount", "fsopen",
             "fsconfig", "fsmount", "fspick", "mount_setattr", "open_tree_attr"):
    namespaces.add_rule_exactly(EPERM, resolve(name))

# libseccomp sets no_new_privs before loading (its default); bwrap has set it already.
unix.load()
namespaces.load()
os.execvp(sys.argv[1], sys.argv[1:])
