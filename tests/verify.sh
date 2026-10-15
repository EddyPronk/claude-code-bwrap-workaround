#!/bin/bash
# verify.sh — reproduce the evidence on an Ubuntu 26.04 machine (we use a fresh VM), as a user who has
# signed in to Claude Code, after an admin ran `sudo apt install bubblewrap socat python3-seccomp`.
#
# Claude Code runs in a new empty folder, with its sandbox settings given on the command line
# (--settings), so no settings file of the user's or a project's changes the result, and none is
# changed. allowUnsandboxedCommands is false: nothing can run outside the sandbox.
#
#   1. without the workaround: probe.py and ps in Claude Code's sandbox (expected: the apply-seccomp error)
#   2. ./install.sh
#   3. with it: the same (expected: every probed filter rule refuses, threads and fork work)
#   4. for comparison: allowAllUnixSockets on, without the workaround (expected: no filter)
#   The workaround is left installed.
#
# Each step checks Claude Code's own record of the tool results (stream-json, via tests/results.py),
# not the model's summary of them. Exit status 0 only if every check passes.
#   bash tests/verify.sh 2>&1 | tee verify.log
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "$HOME/verify-work.XXXXXX")
RESULTS=$(mktemp)
trap 'rm -rf "$work" "$RESULTS"' EXIT
cd "$work" || exit 1
failed=0

settings() {   # true|false: the sandbox settings for one run, with allowAllUnixSockets as given
    echo "{\"sandbox\": {\"enabled\": true, \"autoAllowBashIfSandboxed\": true,
      \"allowUnsandboxedCommands\": false, \"network\": {\"allowAllUnixSockets\": $1}}}"
}
run() {   # LABEL ALLOW_ALL_UNIX_SOCKETS: Claude Code runs probe.py and ps; their results go to $RESULTS
    hash -r
    echo "== $1 (bwrap: $(command -v bwrap); allowAllUnixSockets: $2)"
    claude -p "Run these Bash commands in the sandbox, one at a time. (1) python3 $repo/probe.py (2) ps -eo pid,ppid,comm" \
        --settings "$(settings "$2")" --model haiku --permission-mode default \
        --output-format stream-json --verbose 2>&1 \
        | python3 -I "$repo/tests/results.py" | tee "$RESULTS"
}
expect() {   # PATTERN...: each must match a line of the results (extended regex)
    if ! grep -q '^\$ ' "$RESULTS"; then echo "  FAIL: no command ran"; failed=1; return; fi
    for p in "$@"; do
        if grep -qE -- "$p" "$RESULTS"; then echo "  pass: $p"; else echo "  FAIL: $p"; failed=1; fi
    done
}

echo "Claude Code: $(claude --version 2>&1)"
echo "python3-seccomp (isolated mode): $(/usr/bin/python3 -I -c 'import seccomp; print("loads")' 2>&1 | tail -n 1)"
"$repo/install.sh" --uninstall >/dev/null

run "1. without the workaround" false
expect "apply-seccomp: write /proc/self/setgroups"

echo "== 2. install"
"$repo/install.sh"

run "3. with the workaround" false
expect "^Seccomp: 2 " \
    "^socket\(AF_UNIX\) +EPERM" "^socket\(AF_VSOCK\) +EPERM" "^socket\(AF_INET\) +ok" "^socketpair\(AF_UNIX\) +ok" \
    "^io_uring_setup +EPERM" "^io_uring_enter +EPERM" "^io_uring_register +EPERM" \
    "^unshare\(CLONE_NEWUSER\) +EPERM" "^unshare\(CLONE_NEWNS\) +EPERM" "^unshare\(UNSHARE_EMPTY_MNTNS\) +EPERM" \
    "^clone\(CLONE_NEWUSER\) +EPERM" "^clone\(CLONE_NEWNS\) +EPERM" "^clone3 +ENOSYS" \
    "^setns +EPERM" "^mount +EPERM" "^umount2 +EPERM" "^pivot_root +EPERM" "^open_tree +EPERM" \
    "^move_mount +EPERM" "^fsopen +EPERM" "^fsconfig +EPERM" "^fsmount +EPERM" "^fspick +EPERM" \
    "^mount_setattr +EPERM" "^open_tree_attr +EPERM" "^a thread .* ok" "^fork +ok"

echo "== 4. for comparison: allowAllUnixSockets, without the workaround"
"$repo/install.sh" --uninstall
run "4. allowAllUnixSockets" true
expect "^Seccomp: 0 " "^socket\(AF_UNIX\) +ok" "^io_uring_setup +ok"
"$repo/install.sh" >/dev/null

echo
if [ $failed = 0 ]; then echo "verify.sh: all checks passed"; else echo "verify.sh: some checks FAILED"; fi
exit $failed
