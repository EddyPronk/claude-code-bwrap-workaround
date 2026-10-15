#!/usr/bin/python3
"""probe.py — what a seccomp-filtered command may do: one line per call that Claude Code's
apply-seccomp filters (anthropics/sandbox-runtime, vendor/seccomp-src/seccomp-unix-block.c), plus a
few that must keep working. Run it inside a sandbox; compare the output between sandboxes.
"""
import ctypes
import errno
import os
import socket
import threading

libc = ctypes.CDLL(None, use_errno=True)
NR = {"io_uring_setup": 425, "io_uring_enter": 426, "io_uring_register": 427, "clone": 56,
      "unshare": 272, "setns": 308, "mount": 165, "umount2": 166, "pivot_root": 155,
      "open_tree": 428, "move_mount": 429, "fsopen": 430, "fsconfig": 431, "fsmount": 432,
      "fspick": 433, "mount_setattr": 442, "open_tree_attr": 467, "clone3": 435}


def raw(name, *args):
    """Call a syscall by number (x86_64); return 'ok' or the errno name."""
    r = libc.syscall(NR[name], *args)
    return "ok" if r >= 0 else errno.errorcode.get(ctypes.get_errno(), str(ctypes.get_errno()))


def try_(label, fn):
    try:
        fn()
        print(f"{label:<40} ok")
    except OSError as e:
        print(f"{label:<40} {errno.errorcode.get(e.errno, e.errno)}")


def clone_flag(flag):
    """clone(flag | SIGCHLD) by number: like fork, the child exits at once. 'ok' or the errno name."""
    r = libc.syscall(NR["clone"], flag | 17, 0, 0, 0, 0)
    if r == 0:
        os._exit(0)
    if r < 0:
        return errno.errorcode.get(ctypes.get_errno(), str(ctypes.get_errno()))
    os.waitpid(r, 0)
    return "ok"


status = {l.split(":")[0]: l.split()[1] for l in open("/proc/self/status") if l.startswith("Seccomp")}
# Seccomp is the mode (0 none, 2 filtering); Seccomp_filters the number of filters (Linux 5.9+).
print(f"Seccomp: {status.get('Seccomp')}   Seccomp_filters: {status.get('Seccomp_filters', '?')}")
try_("socket(AF_UNIX)", lambda: socket.socket(socket.AF_UNIX).close())
try_("socket(AF_VSOCK)", lambda: socket.socket(40).close())
try_("socket(AF_INET)", lambda: socket.socket(socket.AF_INET).close())
try_("socketpair(AF_UNIX)", lambda: [s.close() for s in socket.socketpair()])
print(f"{'io_uring_setup':<40} {raw('io_uring_setup', 1, ctypes.create_string_buffer(120))}")
# With fd -1: EPERM when filtered, EBADF when the call reaches the kernel.
print(f"{'io_uring_enter':<40} {raw('io_uring_enter', -1, 0, 0, 0, 0, 0)}")
print(f"{'io_uring_register':<40} {raw('io_uring_register', -1, 0, 0, 0)}")
try_("unshare(CLONE_NEWUSER)", lambda: os.unshare(os.CLONE_NEWUSER))
try_("unshare(CLONE_NEWNS)", lambda: os.unshare(os.CLONE_NEWNS))
print(f"{'unshare(UNSHARE_EMPTY_MNTNS)':<40} {raw('unshare', 0x00100000)}")
print(f"{'clone(CLONE_NEWUSER)':<40} {clone_flag(0x10000000)}")
print(f"{'clone(CLONE_NEWNS)':<40} {clone_flag(0x00020000)}")
print(f"{'clone3':<40} {raw('clone3', 0, 0)}")
for name in ("setns", "mount", "umount2", "pivot_root", "open_tree", "move_mount", "fsopen",
             "fsconfig", "fsmount", "fspick", "mount_setattr", "open_tree_attr"):
    print(f"{name:<40} {raw(name, -1, 0, 0, 0, 0)}")
t = threading.Thread(target=lambda: None)
t.start(); t.join()
print(f"{'a thread (clone, via clone3 fallback)':<40} ok")
pid = os.fork()
if pid == 0:
    os._exit(0)
os.waitpid(pid, 0)
print(f"{'fork':<40} ok")
