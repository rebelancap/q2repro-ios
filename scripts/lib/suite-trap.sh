#!/usr/bin/env bash
# suite-trap.sh — the trap that OWNS the exit status. Source this, never execute it.
#
# Why this file exists (guide §11 / DONOR-MAP §13.3): every script in this repo used to
# carry `trap restore_ios_project EXIT` and nothing else, so the verdict was whatever the
# last command happened to return. A suite that reads $? from the last completed command
# prints PASSED for a run that was killed halfway through — the donors' harness did exactly
# that twice in one day. Three outcomes must be distinguishable:
#
#   PASSED       every case ran and every case passed
#   FAILED       a case failed, or a command returned non-zero
#   INTERRUPTED  a signal arrived (Ctrl-C, SIGTERM, a killed CI job)
#
# and an INCONCLUSIVE case must NEVER exit 0 — "we could not tell" is not a pass.
#
# Contract for the sourcing script:
#   SUITE_NAME="…"            set BEFORE sourcing (used in the verdict line)
#   suite_cleanup_hook()      optional; redefine to release resources (restore the
#                             generated project, shut a simulator lane down, …). It runs
#                             on EVERY exit path — pass, fail, or signal.
#   OWN_LANE=1                set once this run actually claimed a simulator, so a polite
#                             "already booted by another session" abort cannot tear down
#                             the lane it was being polite to.
#   fail "…" / die "…"        record a failure / record and abort
#
# FAILED and INTERRUPTED are declared BEFORE the traps are installed so `set -u` cannot
# lose the verdict when a signal lands during initialisation.

SUITE_NAME="${SUITE_NAME:-suite}"
FAILED=0
INTERRUPTED=0
OWN_LANE=0

suite_cleanup_hook() { :; }   # redefined by the sourcing script

_suite_on_signal() {
    INTERRUPTED=1
    exit 143
}

_suite_cleanup() {
    local rc=$?
    suite_cleanup_hook || true
    if [ "${INTERRUPTED:-0}" != 0 ]; then
        echo ""
        echo "=== $SUITE_NAME: INTERRUPTED (signal) — no verdict, do not read this as a pass ==="
        exit 143
    fi
    if [ "$rc" != 0 ]; then
        echo ""
        echo "=== $SUITE_NAME: FAILED (exit $rc) ==="
        exit "$rc"
    fi
    if [ "${FAILED:-0}" != 0 ]; then
        echo ""
        echo "=== $SUITE_NAME: FAILED ($FAILED case(s)) ==="
        exit 1
    fi
    echo ""
    echo "=== $SUITE_NAME: PASSED ==="
    exit 0
}

trap _suite_on_signal INT TERM HUP
trap _suite_cleanup EXIT

# ---- assertion vocabulary ---------------------------------------------------------
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
pass() { echo "PASS: $*"; }
die()  { echo "FATAL: $*" >&2; FAILED=$((FAILED + 1)); exit 1; }

# inconclusive — a case that could not decide. Counts as a FAILURE on purpose: the whole
# point of the trap is that "we could not tell" must not be reported as green.
inconclusive() { echo "INCONCLUSIVE: $*" >&2; FAILED=$((FAILED + 1)); }

# need <regex> <file> [message] — the file must contain the pattern.
need() {
    if grep -qE "$1" "$2" 2>/dev/null; then pass "${3:-found /$1/ in $(basename "$2")}"
    else fail "${3:-missing /$1/ in $2}"; fi
}

# refute <regex> <file> [message] — the file must NOT contain the pattern.
refute() {
    if grep -qE "$1" "$2" 2>/dev/null; then fail "${3:-unexpected /$1/ in $2}"
    else pass "${3:-no /$1/ in $(basename "$2")}"; fi
}

# count_is <regex> <file> <n> — exact match count (every scripted edit asserts its count).
count_is() {
    local n; n="$(grep -cE "$1" "$2" 2>/dev/null || true)"
    if [ "${n:-0}" = "$3" ]; then pass "count /$1/ = $3"
    else fail "count /$1/ = ${n:-0}, expected $3 (in $2)"; fi
}

# alive <bundle-executable-name> — bracket-trick pgrep so the pattern cannot match the
# watcher's own command line (that once killed chained overnight runs).
alive() {
    local n; n="$(pgrep -f "$(printf '%s' "$1" | sed 's/^\(.\)/[\1]/')" 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n:-0}" -gt 0 ]
}

# sim_wait_shutdown <udid> — CoreSimulator wedges if a device is booted while another boot
# is still tearing down. Wait for state=Shutdown before booting (guide §15 #26).
sim_wait_shutdown() {
    local udid="$1" i
    for i in $(seq 1 60); do
        xcrun simctl list devices | grep -q "$udid.*Shutdown" && return 0
        xcrun simctl list devices | grep -q "$udid.*Booted" || return 0
        sleep 2
    done
    return 1
}
