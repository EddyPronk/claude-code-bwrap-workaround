#!/usr/bin/python3
"""check-names.py — which of the namespaces filter's calls this libseccomp can name, and which rule it
accepts (by name or by number). A diagnostic for seccomp-exec.py."""
import errno
import seccomp

print("libseccomp", seccomp.get_api() if hasattr(seccomp, "get_api") else "", )
for name, nr in [("clone3", 435), ("setns", 308), ("mount", 165), ("umount2", 166),
                 ("pivot_root", 155), ("open_tree", 428), ("move_mount", 429), ("fsopen", 430),
                 ("fsconfig", 431), ("fsmount", 432), ("fspick", 433), ("mount_setattr", 442),
                 ("open_tree_attr", 467)]:
    try:
        resolved = seccomp.resolve_syscall(seccomp.Arch.NATIVE, name)
    except Exception as e:
        resolved = f"unknown ({e})"
    results = []
    for label, key in (("by name", name), ("by number", nr)):
        f = seccomp.SyscallFilter(defaction=seccomp.ALLOW)
        try:
            f.add_rule_exactly(seccomp.ERRNO(errno.EPERM), key)
            results.append(f"{label} ok")
        except Exception as e:
            results.append(f"{label} {e}")
    print(f"{name:<16} resolves to {resolved}; " + "; ".join(results))
