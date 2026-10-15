#!/bin/bash
# wrapper-tests.sh — the wrapper and install.sh without Claude Code: bwrap called with a script shaped
# like Claude Code's. Needs bubblewrap and python3-seccomp; uses a throwaway HOME, changes nothing else.
#   bash tests/wrapper-tests.sh          exit status 0 only if all pass
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() {   # NAME OUTPUT PATTERN [not]: OUTPUT must (or with "not", must not) match PATTERN
    if printf '%s\n' "$2" | grep -qE -- "$3"; then hit=1; else hit=0; fi
    if [ "${4:-}" = not ]; then hit=$((1 - hit)); fi
    if [ $hit = 1 ]; then echo "pass: $1"; else echo "FAIL: $1"; printf '%s\n' "$2" | sed 's/^/    /'; failed=1; fi
}
claude_like() {   # COMMAND: bwrap as Claude Code calls it, roughly, through the wrapper under test
    local q="'${1//\'/\'\\\'\'}'"   # single-quoted, as Claude Code quotes the command
    "$WRAPPER" --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$tmp" "$tmp" \
        --unshare-pid --unshare-user --cap-drop ALL -- \
        /bin/bash -c "ARGV0=apply-seccomp /proc/self/fd/3 /bin/bash -c $q" 2>&1
}

WRAPPER=$repo/bwrap
export BWRAP_WORKAROUND_HELPER=$repo/seccomp-exec.py

out=$(claude_like 'grep ^Seccomp: /proc/self/status; python3 -c "import socket; socket.socket(socket.AF_UNIX)" 2>&1 | tail -n 1')
check "the filters apply" "$out" "^Seccomp:.*2"
check "AF_UNIX refused" "$out" "PermissionError"

# A sitecustomize.py on PYTHONPATH would run inside the helper's Python before the filters. It leaves
# a file: a print would be lost in Python's buffer when the helper execs the command.
mkdir -p "$tmp/pp"
echo "open('$tmp/sitecustomize-ran', 'w').close()" >"$tmp/pp/sitecustomize.py"
PYTHONPATH=$tmp/pp claude_like 'true' >/dev/null
check "PYTHONPATH can't run code before the filters (python3 -I)" "$(ls "$tmp")" "sitecustomize-ran" not

# The command's own text contains the marker: it must reach the command unchanged.
out=$(claude_like 'echo "ARGV0=apply-seccomp /proc/self/fd/3 /bin/bash -c x"')
check "the marker inside the command is left alone" "$out" '^ARGV0=apply-seccomp /proc/self/fd/3 /bin/bash -c x$'

# A helper path with a space and a quote.
mkdir -p "$tmp/a b'c"
cp "$repo/seccomp-exec.py" "$tmp/a b'c/"
out=$(BWRAP_WORKAROUND_HELPER="$tmp/a b'c/seccomp-exec.py" claude_like 'grep ^Seccomp: /proc/self/status')
check "a helper path with a space and a quote" "$out" "^Seccomp:.*2"

# Missing helper: refuse, don't run the command.
out=$(BWRAP_WORKAROUND_HELPER=$tmp/missing.py claude_like 'echo RAN')
check "a missing helper refuses to run the command" "$out" "^RAN$" not

# install.sh with a bwrap in ~/.local/bin that isn't ours.
home=$tmp/home
mkdir -p "$home/.local/bin"
printf '#!/bin/sh\necho mine\n' >"$home/.local/bin/bwrap"
out=$(HOME=$home "$repo/install.sh" 2>&1)
check "install.sh refuses to replace another bwrap" "$(cat "$home/.local/bin/bwrap")" "^echo mine$"
out=$(HOME=$home "$repo/install.sh" --uninstall 2>&1)
check "install.sh --uninstall leaves another bwrap" "$(cat "$home/.local/bin/bwrap" 2>&1)" "^echo mine$"
rm "$home/.local/bin/bwrap"
HOME=$home "$repo/install.sh" >/dev/null 2>&1
check "install.sh installs" "$(cat "$home/.local/bin/bwrap" 2>&1)" "claude-code-bwrap-workaround"
HOME=$home "$repo/install.sh" --uninstall >/dev/null 2>&1
check "install.sh --uninstall removes ours" "$(ls "$home/.local/bin")" "bwrap" not

echo
if [ $failed = 0 ]; then echo "wrapper-tests.sh: all passed"; else echo "wrapper-tests.sh: some FAILED"; fi
exit $failed
