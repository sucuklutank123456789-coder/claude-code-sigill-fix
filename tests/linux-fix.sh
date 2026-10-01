#!/usr/bin/env bash
# Runs Claude-Code/Linux/fix/claude-code-fix.sh against fake Claude Code
# installs in a throwaway home directory and checks the wrappers it writes:
# arguments, stdin and exit codes pass through QEMU, re-runs change nothing,
# SDE wrappers are rewritten for QEMU, a missing emulator is reported, the
# script stops without QEMU instead of falling back to SDE on its own, and
# --restore puts everything back. The fake binaries are copies of /bin/echo,
# /bin/false and /bin/cat. Needs qemu-x86_64 (Debian/Ubuntu: qemu-user).
# Runs on Linux in CI.

set -euo pipefail

FIX="$(cd "$(dirname "$0")/.." && pwd)/Claude-Code/Linux/fix/claude-code-fix.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A space in the path checks the quoting in the wrappers.
export HOME="$WORK/home dir"
CPUINFO="$WORK/cpuinfo"
printf 'flags\t\t: fpu sse sse2 ssse3 sse4_1\n' > "$CPUINFO"
export CLAUDE_SIGILL_FIX_CPUINFO="$CPUINFO"

CLI="$HOME/.local/share/claude/versions/2.0.0"
DESKTOP="$HOME/.config/Claude/claude-code/2.0.0/claude"
EXT="$HOME/.vscode/extensions/anthropic.claude-code-2.0.0"
VSCODE="$EXT/resources/native-binary/claude"
ZED="$HOME/.local/share/zed/external_agents/node_modules/@zed-industries/claude-agent-sdk-linux-x64/claude"

mkdir -p "$(dirname "$CLI")" "$(dirname "$DESKTOP")" "$(dirname "$VSCODE")" "$(dirname "$ZED")"
cp /bin/echo "$CLI"
cp /bin/false "$DESKTOP"
cp /bin/cat "$VSCODE"
cp /bin/cat "$ZED"
echo 'x={initializeTimeoutMs:t=60000,loadTimeoutMs??60000}' > "$EXT/extension.js"

# make_path DIR [NAME...]: fills DIR with links to everything in /usr/bin and
# /bin except NAME... and prints DIR, so a real claude, droid or npm on this
# machine stays out of the test.
make_path() {
    local dir="$1" f n skip pattern
    shift
    mkdir -p "$dir"
    for f in /usr/bin/* /bin/*; do
        n="${f##*/}"
        skip=0
        for pattern in claude droid npm "$@"; do
            # shellcheck disable=SC2053  # NAME may be a glob pattern
            [[ "$n" == $pattern ]] && skip=1
        done
        [[ "$skip" -eq 1 || -e "$dir/$n" ]] || ln -s "$f" "$dir/$n"
    done
    echo "$dir"
}
PATH="$(make_path "$WORK/bin")"
export PATH

PASSED=0
pass() { echo "ok: $1"; PASSED=$((PASSED + 1)); }
die()  { echo "FAILED: $1" >&2; [[ -n "${OUT:-}" ]] && printf '%s\n' "--- output ---" "$OUT" >&2; exit 1; }

# run [ARGS...]: runs the fix script without a terminal; sets OUT and RC.
run() {
    RC=0
    OUT="$(bash "$FIX" --no-sudo "$@" < /dev/null 2>&1)" || RC=$?
}

is_elf() { [[ "$(head -c 4 "$1" | od -An -c | tr -d ' ')" == '177ELF' ]]; }

# --- First run wraps every target --------------------------------------------
run 6
[[ "$RC" -eq 0 ]] || die "first run exited with $RC"
[[ "$(grep -c '\[PATCHED\] wrapped:' <<< "$OUT")" -eq 4 ]] || die "expected 4 wrapped targets"
grep -q 'extension.js startup timeout 60000 -> 900000' <<< "$OUT" || die "extension.js not patched"
grep -q 'initializeTimeoutMs:t=900000,loadTimeoutMs??900000' "$EXT/extension.js" || die "extension.js content"
for t in "$CLI" "$DESKTOP" "$VSCODE" "$ZED"; do
    is_elf "$t.realbinary" || die "no .realbinary for $t"
    grep -q 'qemu-x86_64' "$t" || die "wrapper for $t does not use QEMU"
done
pass "first run wraps all targets with QEMU"

# --- The wrappers pass arguments, stdin and exit codes through --------------
# shellcheck disable=SC2016  # a literal $HOME must reach the program unexpanded
[[ "$("$CLI" "a b" 'c"d' '$HOME')" == 'a b c"d $HOME' ]] || die "arguments not passed through"
[[ "$(printf 'line 1\nline 2\n' | "$ZED")" == $'line 1\nline 2' ]] || die "stdin/stdout not passed through"
rc=0; "$DESKTOP" || rc=$?
[[ "$rc" -eq 1 ]] || die "exit code not passed through (got $rc)"
pass "wrappers pass arguments, stdin and exit codes through"

# --- A second run changes nothing --------------------------------------------
run 6
[[ "$RC" -eq 0 ]] || die "second run exited with $RC"
grep -q 'PATCHED' <<< "$OUT" && die "second run patched something"
grep -q 'Nothing to do' <<< "$OUT" || die "second run summary"
pass "second run changes nothing"

# --- Wrappers from older versions or for SDE are rewritten --------------------
printf '#!/usr/bin/env bash\nexec /usr/bin/sde64 -hsw -- %q "$@"\n' "$CLI.realbinary" > "$CLI"
run 1
[[ "$RC" -eq 0 ]] || die "rewrite run exited with $RC"
grep -q '\[PATCHED\] wrapped:' <<< "$OUT" || die "SDE wrapper not rewritten"
grep -q 'qemu-x86_64' "$CLI" || die "rewritten wrapper does not use QEMU"
[[ "$("$CLI" ok)" == "ok" ]] || die "rewritten wrapper does not run"
pass "SDE wrapper is rewritten for QEMU"

# --- An update replaces the wrapper with a new native binary -----------------
cp /bin/echo "$CLI"
run 1
grep -q '\[PATCHED\] wrapped:' <<< "$OUT" || die "updated binary not wrapped"
[[ "$("$CLI" updated)" == "updated" ]] || die "wrapper after update does not run"
pass "an updated binary is wrapped again"

# --- --engine=sde, and a wrapper whose emulator is gone ----------------------
mkdir -p "$WORK/sde"
cat > "$WORK/sde/sde64" <<'EOF'
#!/usr/bin/env bash
# Fake SDE: drops its own options up to "--" and runs the program natively.
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
exec "$@"
EOF
chmod +x "$WORK/sde/sde64"
RC=0
OUT="$(PATH="$WORK/sde:$PATH" bash "$FIX" --no-sudo --engine=sde 1 < /dev/null 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] || die "--engine=sde run exited with $RC"
grep -q "$WORK/sde/sde64" "$CLI" || die "wrapper does not use the fake SDE"
[[ "$("$CLI" via sde)" == "via sde" ]] || die "SDE wrapper does not run"
rm "$WORK/sde/sde64"
rc=0; err="$("$CLI" x 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 127 ]] || die "missing emulator: exit code $rc, expected 127"
grep -q "emulator .*sde64 not found" <<< "$err" || die "missing emulator message: $err"
pass "--engine=sde works, and a missing emulator is reported"

# --- Without QEMU and without a terminal, nothing changes --------------------
noqemu="$(make_path "$WORK/noqemu" 'qemu-*')"
before="$(cat "$CLI")"
RC=0
OUT="$(PATH="$noqemu" bash "$FIX" --no-sudo 1 < /dev/null 2>&1)" || RC=$?
[[ "$RC" -eq 1 ]] || die "run without QEMU exited with $RC, expected 1"
grep -q 'Nothing changed' <<< "$OUT" || die "run without QEMU: no 'Nothing changed'"
[[ "$(cat "$CLI")" == "$before" ]] || die "run without QEMU changed the wrapper"
pass "without QEMU and a terminal, the script stops without falling back to SDE"

# --- --restore puts everything back ------------------------------------------
run --restore 6
[[ "$RC" -eq 0 ]] || die "restore exited with $RC"
for t in "$CLI" "$DESKTOP" "$VSCODE" "$ZED"; do
    is_elf "$t" || die "$t is not the original binary after restore"
    [[ ! -e "$t.realbinary" ]] || die "$t.realbinary left after restore"
done
grep -q 'initializeTimeoutMs:t=60000,loadTimeoutMs??60000' "$EXT/extension.js" || die "extension.js not restored"
pass "--restore puts the original binaries and timeouts back"

echo "all $PASSED checks passed"
