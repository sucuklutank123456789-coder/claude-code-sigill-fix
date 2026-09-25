#!/usr/bin/env bash
# claude-sigill-fix.sh
#
# Makes Claude Code run on legacy x86-64 CPUs without AVX/AVX2/SSE4.2
# (e.g. Core 2 Duo) on Linux, where native binaries crash with
# "Illegal instruction (core dumped)" / SIGILL.
#
# How it works: every Claude Code native binary is renamed to
# <name>.realbinary and replaced with a tiny wrapper that runs it
# under Intel SDE with Haswell emulation (-hsw).
#
# Safe to re-run: it only touches what an update has broken.
#
# Targets (pick them from the menu, or pass the numbers as arguments,
# e.g. `./claude-sigill-fix.sh 4 1`):
#   1. Terminal CLI (npm global install)
#   2. Claude Desktop (embedded CLI + Cowork installSdk timeout, needs sudo)
#   3. VS Code extension (native binary + startup timeout)
#   4. Zed Claude Agent (ACP)
#   5. All of the above
#
# Not an official Anthropic tool. Use at your own risk.

set -u

# --- Colors / output helpers -------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

CHANGED=0
FAILED=0

header() { echo; echo "${BLUE}== $1 ==${RESET}"; }
ok()     { echo "  ${GREEN}[OK]${RESET}      $1"; }
patched(){ echo "  ${YELLOW}[PATCHED]${RESET} $1"; CHANGED=1; }
skip()   { echo "  [SKIP]    $1"; }
fail()   { echo "  ${RED}[ERROR]${RESET}   $1"; FAILED=1; }

# --- Target selection --------------------------------------------------------
SELECTED=""

# Parses space-separated numbers into SELECTED. Returns 1 on invalid input.
parse_selection() {
    local picks=() n
    [[ $# -gt 0 ]] || return 1
    for n in "$@"; do
        case "$n" in
            1|2|3|4) picks+=("$n") ;;
            5)       picks+=(1 2 3 4) ;;
            *)       return 1 ;;
        esac
    done
    SELECTED=" ${picks[*]} "
}

selected() { [[ "$SELECTED" == *" $1 "* ]]; }

if [[ $# -gt 0 ]]; then
    parse_selection "$@" || { echo "${RED}Invalid choice: $*${RESET} (use numbers 1-5)"; exit 1; }
else
    echo "Which one do you want to fix?"
    echo "  1: Claude Code CLI (terminal)"
    echo "  2: Claude Desktop app"
    echo "  3: VS Code extension"
    echo "  4: Zed Claude Agent (ACP)"
    echo "  5: All"
    while true; do
        read -r -p "Enter numbers separated by spaces (e.g. 4 1): " -a CHOICES || exit 1
        parse_selection "${CHOICES[@]}" && break
        echo "${RED}Invalid choice.${RESET} Use numbers 1-5 separated by spaces."
    done
fi

# --- Requirement: Intel SDE --------------------------------------------------
SDE="$(command -v intel-sde || command -v sde64 || command -v sde || true)"
if [[ -z "$SDE" ]]; then
    echo "${RED}Intel SDE not found.${RESET}"
    echo "Install it first (Arch: paru -S intel-sde), or download it from Intel"
    echo "and put the 'sde64' binary on your PATH."
    exit 1
fi

is_elf() {
    [[ -f "$1" ]] && [[ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" == '177ELF' ]]
}

is_script() {
    [[ -f "$1" ]] && [[ "$(head -c 2 "$1" 2>/dev/null)" == '#!' ]]
}

# Wrap one native binary with the SDE wrapper.
wrap() {
    local target="$1"
    local real="${target}.realbinary"

    if is_script "$target" && [[ -f "$real" ]]; then
        ok "already wrapped: $target"
        return
    fi

    if is_elf "$target"; then
        mv -f "$target" "$real" || { fail "could not rename $target"; return; }
    elif [[ ! -f "$real" ]]; then
        fail "neither native binary nor .realbinary found: $target"
        return
    fi

    printf '#!/usr/bin/env bash\nexec "%s" -hsw -- "%s" "$@"\n' "$SDE" "$real" > "$target" \
        && chmod +x "$target" "$real" \
        && patched "wrapped: $target" \
        || fail "could not write wrapper: $target"
}

# --- 1) Terminal CLI ---------------------------------------------------------
fix_cli() {
    header "Terminal CLI"
    local CLI="" NPM_ROOT c
    if command -v npm >/dev/null 2>&1; then
        NPM_ROOT="$(npm root -g 2>/dev/null)"
        for c in "$NPM_ROOT/@anthropic-ai/claude-code/bin/claude.exe" \
                 "$NPM_ROOT/@anthropic-ai/claude-code/bin/claude"; do
            if [[ -f "$c" || -f "$c.realbinary" ]]; then CLI="$c"; break; fi
        done
    fi
    if [[ -z "$CLI" ]] && command -v claude >/dev/null 2>&1; then
        CLI="$(readlink -f "$(command -v claude)")"
    fi

    if [[ -n "$CLI" ]]; then
        wrap "$CLI"
    else
        skip "Claude Code CLI not installed"
    fi
}

# --- 2) Claude Desktop -------------------------------------------------------
fix_desktop() {
    header "Claude Desktop embedded CLI"
    local FOUND=0 bin
    while IFS= read -r bin; do
        [[ -n "$bin" ]] || continue
        FOUND=1
        wrap "$bin"
    done < <(find "$HOME/.config/Claude/claude-code" "$HOME/.config/Claude/claude-code-vm" -maxdepth 2 \
                \( -name 'claude' -o -name 'claude.realbinary' \) \
                2>/dev/null | sed 's/\.realbinary$//' | sort -u)
    [[ "$FOUND" -eq 1 ]] || skip "Desktop embedded CLI not found"

    header "Claude Desktop Cowork installSdk timeout (cowork-linux-helper)"
    local HELPER="" h COUNT TMP
    for h in /usr/lib/claude-desktop/resources/cowork-linux-helper \
             /opt/claude-desktop/resources/cowork-linux-helper; do
        [[ -f "$h" ]] && { HELPER="$h"; break; }
    done

    if [[ -n "$HELPER" ]] && command -v python3 >/dev/null 2>&1; then
        COUNT="$(python3 - "$HELPER" <<'PYEOF'
import struct, sys
try:
    d = open(sys.argv[1], "rb").read()
except Exception:
    print("ERR"); sys.exit(0)
print(d.count(struct.pack("<Q", 30_000_000_000)))
PYEOF
)"
        if [[ "$COUNT" == "0" ]]; then
            ok "cowork-linux-helper already patched"
        elif [[ "$COUNT" == "ERR" ]]; then
            fail "could not read cowork-linux-helper"
        else
            echo "  ${YELLOW}found $COUNT x 30s constant, sudo needed to patch${RESET}"
            TMP="$(mktemp)"
            cp "$HELPER" "$TMP"
            python3 - "$TMP" <<'PYEOF'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
d = d.replace(struct.pack("<Q", 30_000_000_000), struct.pack("<Q", 900_000_000_000))
open(p, "wb").write(d)
PYEOF
            sudo cp -n "$HELPER" "$HELPER.orig.bak" 2>/dev/null
            if sudo cp "$TMP" "$HELPER" && sudo chown root:root "$HELPER" && sudo chmod 755 "$HELPER"; then
                patched "cowork-linux-helper 30s -> 900s"
            else
                fail "could not copy patched cowork-linux-helper into place"
            fi
            rm -f "$TMP"
        fi
    elif [[ -n "$HELPER" ]]; then
        fail "python3 is required for the Cowork patch"
    else
        skip "cowork-linux-helper not found (AppImage installs need a manual rebuild)"
    fi
}

# --- 3) VS Code extension ----------------------------------------------------
fix_vscode() {
    header "VS Code extension"
    local VSCODE_DIR EXT_JS
    VSCODE_DIR="$(find "$HOME/.vscode/extensions" "$HOME/.vscode-oss/extensions" -maxdepth 1 \
                  -iname 'anthropic.claude-code-*' 2>/dev/null | sort -V | tail -1)"

    if [[ -n "$VSCODE_DIR" ]]; then
        wrap "$VSCODE_DIR/resources/native-binary/claude"

        EXT_JS="$VSCODE_DIR/extension.js"
        [[ -f "$EXT_JS" ]] || EXT_JS="$VSCODE_DIR/dist/extension.js"
        if [[ -f "$EXT_JS" ]]; then
            if grep -q '60000' "$EXT_JS"; then
                sed -i 's/60000/900000/g' "$EXT_JS" \
                    && patched "extension.js startup timeout 60000 -> 900000" \
                    || fail "could not patch extension.js"
            else
                ok "extension.js timeout already patched"
            fi
        else
            skip "extension.js not found"
        fi
    else
        skip "VS Code extension not installed"
    fi
}

# --- 4) Zed Claude Agent (ACP) -----------------------------------------------
fix_zed() {
    header "Zed Claude Agent (ACP)"
    local FOUND=0 bin
    while IFS= read -r bin; do
        [[ -n "$bin" ]] || continue
        FOUND=1
        wrap "$bin"
    done < <(find "$HOME/.local/share/zed" "$HOME/.npm/_npx" "$HOME/.cache/zed" \
                \( -path '*claude-agent-sdk-linux-x64/claude' -o -path '*claude-agent-sdk-linux-x64/claude.realbinary' \) \
                2>/dev/null | sed 's/\.realbinary$//' | sort -u)
    [[ "$FOUND" -eq 1 ]] || skip "Zed agent binary not found"
}

# --- Run selected targets ----------------------------------------------------
selected 1 && fix_cli
selected 2 && fix_desktop
selected 3 && fix_vscode
selected 4 && fix_zed

# --- Summary -----------------------------------------------------------------
echo
echo "${BLUE}================ SUMMARY ================${RESET}"
if [[ "$CHANGED" -eq 1 ]]; then
    echo "${YELLOW}Some patches were (re)applied.${RESET}"
    echo "Fully close and reopen the patched apps (VS Code, Zed, Claude Desktop)."
else
    echo "${GREEN}Everything was already patched, nothing to do.${RESET}"
fi
[[ "$FAILED" -eq 1 ]] && echo "${RED}Some steps failed, see the [ERROR] lines above.${RESET}"
exit 0
