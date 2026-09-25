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
# If Intel SDE is missing, it offers to install it (AUR on Arch-based
# systems, otherwise the Linux tarball from Intel into ~/.local/opt/intel-sde).
#
# Usage:
#   ./claude-sigill-fix.sh              interactive menu
#   ./claude-sigill-fix.sh 4 1          fix targets 4 and 1 without the menu
#   ./claude-sigill-fix.sh --restore    undo the fixes (menu or numbers too)
#
# Options for unattended use (agents, cron, systemd timers):
#   --no-sudo       never call sudo (SDE is then never installed from the AUR)
#   --install-sde   install Intel SDE without asking if it is missing
#                   (with --no-sudo it downloads into ~/.local/opt/intel-sde)
#   Exit code is 1 if any step failed, 0 otherwise.
#
# Targets:
#   1. Terminal CLI (npm global install and the native installer)
#   2. Claude Desktop (embedded Claude Code CLI; Cowork is not covered here)
#   3. VS Code extension (also Insiders, VSCodium, Cursor, Windsurf, Flatpak)
#   4. Zed Claude Agent (ACP)
#   5. Droid (Factory AI CLI)
#   6. All of the above
#
# Not an official Anthropic tool. Use at your own risk.

set -u
shopt -s lastpipe  # `... | wrap_found` must update CHANGED/FAILED in this shell

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
restored(){ echo "  ${YELLOW}[RESTORED]${RESET} $1"; CHANGED=1; }
skip()   { echo "  [SKIP]    $1"; }
warn()   { echo "  ${YELLOW}[WARN]${RESET}    $1"; }
fail()   { echo "  ${RED}[ERROR]${RESET}   $1"; FAILED=1; }

usage() { sed -n '/^# Usage:/,/^#   6\./p' "$0" | sed 's/^# \{0,1\}//'; }

# --- Arguments ---------------------------------------------------------------
MODE="fix"
NO_SUDO=0
AUTO_SDE=0
NUMS=()
for arg in "$@"; do
    case "$arg" in
        --restore)      MODE="restore" ;;
        --no-sudo)      NO_SUDO=1 ;;
        --install-sde)  AUTO_SDE=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          NUMS+=("$arg") ;;
    esac
done

# --- CPU check ---------------------------------------------------------------
# The native binaries need AVX2 (hence SDE's Haswell mode). A CPU that has it
# runs them natively, and wrapping them would only make them much slower.
if [[ "$MODE" == "fix" ]] && grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
    echo "${YELLOW}Your CPU supports AVX2, so Claude Code should run natively.${RESET}"
    echo "This fix is only for CPUs without AVX/AVX2/SSE4.2 and would make everything much slower."
    ANSWER=""
    [[ -t 0 ]] && read -r -p "Continue anyway? [y/N]: " ANSWER
    [[ "$ANSWER" =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }
fi

# --- Target selection --------------------------------------------------------
SELECTED=""

# Parses space-separated numbers into SELECTED. Returns 1 on invalid input.
parse_selection() {
    local picks=() n
    [[ $# -gt 0 ]] || return 1
    for n in "$@"; do
        case "$n" in
            1|2|3|4|5) picks+=("$n") ;;
            6)         picks+=(1 2 3 4 5) ;;
            *)         return 1 ;;
        esac
    done
    SELECTED=" ${picks[*]} "
}

selected() { [[ "$SELECTED" == *" $1 "* ]]; }

if [[ ${#NUMS[@]} -gt 0 ]]; then
    parse_selection "${NUMS[@]}" || { echo "${RED}Invalid choice: ${NUMS[*]}${RESET} (use numbers 1-6)"; exit 1; }
else
    [[ "$MODE" == "fix" ]] && echo "Which one do you want to fix?" || echo "Which one do you want to restore?"
    echo "  1: Claude Code CLI (terminal)"
    echo "  2: Claude Desktop app"
    echo "  3: VS Code extension (also Cursor, Windsurf, VSCodium)"
    echo "  4: Zed Claude Agent (ACP)"
    echo "  5: Droid (Factory AI CLI)"
    echo "  6: All"
    while true; do
        read -r -p "Enter numbers separated by spaces (e.g. 4 1): " -a CHOICES || exit 1
        parse_selection "${CHOICES[@]}" && break
        echo "${RED}Invalid choice.${RESET} Use numbers 1-6 separated by spaces."
    done
fi

# --- Requirement: Intel SDE --------------------------------------------------
SDE_PAGE="https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html"
SDE_HOME="$HOME/.local/opt/intel-sde"

find_sde() {
    command -v intel-sde || command -v sde64 || command -v sde \
        || { [[ -x "$SDE_HOME/sde64" ]] && echo "$SDE_HOME/sde64"; } || true
}

fetch() {  # fetch URL [OUTFILE]; prints to stdout when OUTFILE is omitted
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -A 'Mozilla/5.0' ${2:+-o "$2"} "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -U 'Mozilla/5.0' -O "${2:--}" "$1"
    else
        echo "${RED}curl or wget is required to download SDE.${RESET}" >&2
        return 1
    fi
}

# Generic install: download the Linux tarball from Intel into ~/.local/opt/intel-sde.
install_sde_generic() {
    local url tmp
    echo "Looking up the latest Intel SDE release..."
    url="$(fetch "$SDE_PAGE" | grep -oE 'https://downloadmirror\.intel\.com/[0-9]+/sde-external-[0-9.]+-[0-9-]+-lin\.tar\.(xz|bz2)' \
           | sort -uV | tail -1)"
    if [[ -z "$url" ]]; then
        echo "${RED}Could not find the download link automatically.${RESET}"
        echo "Download the Linux .tar.xz manually from:"
        echo "  $SDE_PAGE"
        echo "then extract it to $SDE_HOME (so that $SDE_HOME/sde64 exists) and re-run this script."
        return 1
    fi
    echo "Downloading $url"
    tmp="$(mktemp -d)"
    if fetch "$url" "$tmp/sde.tar" && mkdir -p "$SDE_HOME" \
        && tar -xf "$tmp/sde.tar" -C "$SDE_HOME" --strip-components=1; then
        rm -rf "$tmp"
        [[ -x "$SDE_HOME/sde64" ]]
    else
        rm -rf "$tmp"
        echo "${RED}Download or extraction failed.${RESET}"
        return 1
    fi
}

install_sde() {
    local distro="" aur
    [[ -r /etc/os-release ]] && distro="$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")"
    # The AUR build asks for sudo, so --no-sudo goes straight to Intel's tarball.
    if [[ "$NO_SUDO" -eq 0 && " $distro " == *" arch "* ]]; then
        aur="$(command -v paru || command -v yay || true)"
        if [[ -n "$aur" ]]; then
            echo "Arch-based system detected, running: $(basename "$aur") -S intel-sde"
            "$aur" -S intel-sde && return 0
            echo "${YELLOW}AUR install failed, falling back to Intel's download.${RESET}"
        fi
    fi
    # No distro packages SDE outside the AUR, so everyone else uses Intel's tarball.
    install_sde_generic
}

SDE=""
if [[ "$MODE" == "fix" ]]; then
    SDE="$(find_sde)"
    if [[ -z "$SDE" ]]; then
        echo "${RED}Intel SDE not found.${RESET} The fix does not work without SDE."
        echo "SDE is Intel software under Intel's own license; installing it means you accept that license."
        ANSWER=""
        if [[ "$AUTO_SDE" -eq 1 ]]; then
            ANSWER="y"
        elif [[ -t 0 ]]; then
            read -r -p "Do you want to install SDE now? [y/N]: " ANSWER
        fi
        if [[ "$ANSWER" =~ ^[Yy]$ ]] && install_sde; then
            SDE="$(find_sde)"
        fi
        if [[ -z "$SDE" ]]; then
            echo "SDE is not installed. Install it (Arch: paru -S intel-sde, others: $SDE_PAGE)"
            echo "and re-run this script."
            exit 1
        fi
        echo "${GREEN}Intel SDE installed:${RESET} $SDE"
    fi
fi

# --- Wrapping ----------------------------------------------------------------
is_elf() {
    [[ -f "$1" ]] && [[ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" == '177ELF' ]]
}

is_script() {
    [[ -f "$1" ]] && [[ "$(head -c 2 "$1" 2>/dev/null)" == '#!' ]]
}

# Wrap one native binary with the SDE wrapper (or undo that in restore mode).
wrap() {
    local target="$1"
    local real="${target}.realbinary"

    if [[ "$MODE" == "restore" ]]; then
        if [[ -f "$real" ]]; then
            mv -f "$real" "$target" && restored "unwrapped: $target" || fail "could not restore $target"
        else
            ok "not wrapped: $target"
        fi
        return
    fi

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

# Wraps every path read from stdin (".realbinary" suffixes are stripped).
# Prints "$1" as a skip message when there is none.
wrap_found() {
    local found=0 bin
    while IFS= read -r bin; do
        [[ -n "$bin" ]] || continue
        found=1
        wrap "$bin"
    done < <(sed 's/\.realbinary$//' | sort -u)
    [[ "$found" -eq 1 ]] || skip "$1"
}

# --- 1) Terminal CLI ---------------------------------------------------------
fix_cli() {
    header "Terminal CLI"
    local npm_root c
    {
        # npm global install
        if command -v npm >/dev/null 2>&1; then
            npm_root="$(npm root -g 2>/dev/null)"
            for c in "$npm_root/@anthropic-ai/claude-code/bin/claude.exe" \
                     "$npm_root/@anthropic-ai/claude-code/bin/claude"; do
                [[ -f "$c" || -f "$c.realbinary" ]] && echo "$c"
            done
        fi
        # Native installer: every downloaded version, so auto-updates are covered too
        find "$HOME/.local/share/claude/versions" -maxdepth 2 -type f 2>/dev/null \
            | sed 's/\.realbinary$//' | sort -u | while IFS= read -r c; do
                if is_elf "$c" || [[ -f "$c.realbinary" ]]; then echo "$c"; fi
            done
        # Anything else on PATH
        if command -v claude >/dev/null 2>&1; then
            c="$(readlink -f "$(command -v claude)")"
            if is_elf "$c" || [[ -f "$c.realbinary" ]]; then echo "$c"; fi
        fi
    } | wrap_found "Claude Code CLI not installed"
}

# --- 2) Claude Desktop -------------------------------------------------------
fix_desktop() {
    header "Claude Desktop embedded CLI"
    find "$HOME/.config/Claude/claude-code" -maxdepth 2 \
         \( -name 'claude' -o -name 'claude.realbinary' \) 2>/dev/null \
        | wrap_found "Desktop embedded CLI not found"
}

# --- 3) VS Code extension ----------------------------------------------------
# Only the two subprocess startup timeouts are touched, e.g.
#   initializeTimeoutMs:t=60000   loadTimeoutMs??60000
TIMEOUT_RE='((initialize|load)TimeoutMs(:[A-Za-z_$][A-Za-z0-9_$]*=|\?\?|:|=))'

patch_extension_js() {
    local js="$1" from=60000 to=900000
    [[ "$MODE" == "restore" ]] && { from=900000; to=60000; }

    if grep -Eq "${TIMEOUT_RE}${from}([^0-9]|\$)" "$js"; then
        if sed -Ei "s/${TIMEOUT_RE}${from}([^0-9]|\$)/\\1${to}\\4/g" "$js"; then
            [[ "$MODE" == "restore" ]] && restored "extension.js timeout -> 60000" \
                                       || patched "extension.js startup timeout 60000 -> 900000"
        else
            fail "could not patch $js"
        fi
    elif grep -Eq "${TIMEOUT_RE}${to}([^0-9]|\$)" "$js"; then
        ok "extension.js timeout already set to $to"
    else
        fail "timeout setting not found in $js (the extension changed?), not patched"
    fi
}

fix_vscode() {
    header "VS Code extension"
    local root dir js found=0
    for root in "$HOME/.vscode/extensions" \
                "$HOME/.vscode-insiders/extensions" \
                "$HOME/.vscode-oss/extensions" \
                "$HOME/.cursor/extensions" \
                "$HOME/.windsurf/extensions" \
                "$HOME/.var/app/com.visualstudio.code/data/vscode/extensions" \
                "$HOME/.var/app/com.vscodium.codium/data/codium/extensions"; do
        dir="$(find "$root" -maxdepth 1 -iname 'anthropic.claude-code-*' 2>/dev/null | sort -V | tail -1)"
        [[ -n "$dir" ]] || continue
        found=1

        # Flatpak apps have their own /usr, so SDE must live in the home directory.
        if [[ "$MODE" == "fix" && "$root" == "$HOME/.var/app/"* && "$SDE" != "$HOME/"* ]]; then
            warn "$SDE is not visible inside Flatpak; install SDE into $SDE_HOME instead"
        fi

        wrap "$dir/resources/native-binary/claude"

        js="$dir/extension.js"
        [[ -f "$js" ]] || js="$dir/dist/extension.js"
        if [[ -f "$js" ]]; then
            patch_extension_js "$js"
        else
            skip "extension.js not found in $dir"
        fi
    done
    [[ "$found" -eq 1 ]] || skip "VS Code extension not installed"
}

# --- 4) Zed Claude Agent (ACP) -----------------------------------------------
fix_zed() {
    header "Zed Claude Agent (ACP)"
    find "$HOME/.local/share/zed" "$HOME/.npm/_npx" "$HOME/.cache/zed" \
         \( -path '*claude-agent-sdk-linux-x64/claude' -o -path '*claude-agent-sdk-linux-x64/claude.realbinary' \) \
         2>/dev/null | wrap_found "Zed agent binary not found"
}

# --- 5) Droid (Factory AI CLI) -----------------------------------------------
fix_droid() {
    header "Droid (Factory AI CLI)"
    local c
    {
        command -v droid >/dev/null 2>&1 && readlink -f "$(command -v droid)"
        echo "$HOME/.local/bin/droid"
    } | while IFS= read -r c; do
        if is_elf "$c" || [[ -f "$c.realbinary" ]]; then echo "$c"; fi
    done | wrap_found "Droid not installed"
}

# --- Run selected targets ----------------------------------------------------
selected 1 && fix_cli
selected 2 && fix_desktop
selected 3 && fix_vscode
selected 4 && fix_zed
selected 5 && fix_droid

# --- Summary -----------------------------------------------------------------
echo
echo "${BLUE}================ SUMMARY ================${RESET}"
if [[ "$CHANGED" -eq 1 && "$MODE" == "restore" ]]; then
    echo "${YELLOW}Original files were restored.${RESET}"
    echo "Fully close and reopen the restored apps."
elif [[ "$CHANGED" -eq 1 ]]; then
    echo "${YELLOW}Some patches were (re)applied.${RESET}"
    echo "Fully close and reopen the patched apps (VS Code, Zed, Claude Desktop)."
else
    echo "${GREEN}Nothing to do.${RESET}"
fi
[[ "$FAILED" -eq 1 ]] && echo "${RED}Some steps failed, see the [ERROR] lines above.${RESET}"
exit "$FAILED"
