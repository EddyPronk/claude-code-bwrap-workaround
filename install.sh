#!/bin/bash
# install.sh — install the workaround for the current user (no sudo): the bwrap wrapper in ~/.local/bin,
# its helper in ~/.local/share/claude-code-bwrap-workaround.
#   ./install.sh               install, then check what the shell finds as bwrap
#   ./install.sh --uninstall   remove both files
set -eu
here=$(cd "$(dirname "$0")" && pwd)
BIN=$HOME/.local/bin/bwrap
SHARE=$HOME/.local/share/claude-code-bwrap-workaround
OURS=https://github.com/EddyPronk/claude-code-bwrap-workaround   # in our wrapper's header

ours() { grep -qF "$OURS" "$BIN" 2>/dev/null; }

if [ "${1:-}" = --uninstall ]; then
    if [ -e "$BIN" ] && ! ours; then
        echo "install.sh: $BIN isn't this workaround's wrapper; leaving it" >&2
    else
        rm -f "$BIN"
    fi
    rm -f "$SHARE/seccomp-exec.py"
    rmdir "$SHARE" 2>/dev/null || true
    echo "removed the workaround ($BIN, $SHARE/seccomp-exec.py)"
    exit 0
fi

[ -x /usr/bin/bwrap ] || { echo "install.sh: no /usr/bin/bwrap (sudo apt install bubblewrap socat)" >&2; exit 1; }
command -v socat >/dev/null \
    || echo "install.sh: note: no socat; Claude Code's sandbox needs it (sudo apt install socat)" >&2
# The wrapper runs the helper with python3 -I (isolated mode); the module must load that way.
/usr/bin/python3 -I -c 'import seccomp' 2>/dev/null \
    || { echo "install.sh: python3-seccomp is missing (sudo apt install python3-seccomp)" >&2; exit 1; }
if [ -e "$BIN" ] && ! ours; then
    echo "install.sh: $BIN exists and isn't this workaround's wrapper; not replacing it." >&2
    echo "  Move it away first if you want this one." >&2
    exit 1
fi

install -D -m 644 "$here/seccomp-exec.py" "$SHARE/seccomp-exec.py"
install -D -m 755 "$here/bwrap" "$BIN"
echo "installed $BIN and $SHARE/seccomp-exec.py"

hash -r
found=$(command -v bwrap || true)
# What a login shell finds: it reads ~/.profile, which on Ubuntu adds ~/.local/bin only if the folder
# existed at login, so a shell started before the first install doesn't have it yet.
login=$(bash -lc 'command -v bwrap' </dev/null 2>/dev/null || true)
if [ "$found" = "$BIN" ]; then
    echo "bwrap resolves to $BIN: done"
elif [ "$login" = "$BIN" ]; then
    echo "done. This shell's PATH predates ~/.local/bin, so it still finds ${found:-no bwrap}."
    echo "Before starting claude from this shell, run:  . ~/.profile   (or log in again)"
else
    echo "warning: bwrap resolves to ${found:-nothing}, also in a new login shell, not $BIN." >&2
    echo "  Claude Code would not use the workaround. Put ~/.local/bin before /usr/bin in the PATH" >&2
    echo "  that claude starts with (e.g. in ~/.profile), then check with:  command -v bwrap" >&2
fi
