#!/usr/bin/env bash
# cowork-fix.sh
#
# Gets Claude Desktop's Cowork feature working on Linux, especially on old,
# slow CPUs without AVX/AVX2/SSE4.2 (e.g. Core 2 Duo).
#
# Targets:
#   1. QEMU / KVM prerequisites ("Cowork requires QEMU")
#      Installs QEMU, OVMF (UEFI firmware) and virtiofsd with the distro's
#      package manager, symlinks them to the Debian-style paths Claude Desktop
#      expects, and adds you to the kvm group. Needs sudo.
#   2. Cowork VM CLI (~/.config/Claude/claude-code-vm/<version>/claude)
#      Wraps it with Intel SDE like the Claude Code fix does. Only on CPUs
#      without AVX2; needs SDE (the Claude Code fix script can install it).
#   3. installSdk timeout ("request req-2 (installSdk) timed out after 30s")
#      Raises the 30 s timeout compiled into cowork-linux-helper to 900 s.
#      Needs sudo and python3. Not possible on AppImage installs.
#   4. All of the above
#
# Usage:
#   ./cowork-fix.sh                interactive menu
#   ./cowork-fix.sh 1 3            run targets 1 and 3 without the menu
#   ./cowork-fix.sh --restore      undo the fixes (packages stay installed)
#   Exit code is 1 if any step failed, 0 otherwise.
#
# Not an official Anthropic tool. Use at your own risk.

set -u
shopt -s lastpipe

# --- Colors / output helpers -------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

CHANGED=0
FAILED=0
REBOOT=0

header() { echo; echo "${BLUE}== $1 ==${RESET}"; }
ok()     { echo "  ${GREEN}[OK]${RESET}      $1"; }
patched(){ echo "  ${YELLOW}[PATCHED]${RESET} $1"; CHANGED=1; }
restored(){ echo "  ${YELLOW}[RESTORED]${RESET} $1"; CHANGED=1; }
skip()   { echo "  [SKIP]    $1"; }
warn()   { echo "  ${YELLOW}[WARN]${RESET}    $1"; }
fail()   { echo "  ${RED}[ERROR]${RESET}   $1"; FAILED=1; }

usage() { sed -n '/^# Usage:/,/^#   Exit code/p' "$0" | sed 's/^# \{0,1\}//'; }

# Shows a root command and asks before it runs. Without a terminal it only
# prints the command so the user can run it.
ask_sudo() {
    local answer=""
    echo "  Command: sudo $*"
    if [[ ! -t 0 ]]; then
        warn "no terminal to ask for confirmation, run the command above yourself"
        return 1
    fi
    read -r -p "  Run it now? [Y/n]: " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]] || { skip "not run"; return 1; }
}

confirm_sudo() { ask_sudo "$@" && sudo "$@"; }

# --- Arguments ---------------------------------------------------------------
MODE="fix"
NUMS=()
for arg in "$@"; do
    case "$arg" in
        --restore)  MODE="restore" ;;
        -h|--help)  usage; exit 0 ;;
        *)          NUMS+=("$arg") ;;
    esac
done

# --- Target selection --------------------------------------------------------
SELECTED=""

parse_selection() {
    local picks=() n
    [[ $# -gt 0 ]] || return 1
    for n in "$@"; do
        case "$n" in
            1|2|3) picks+=("$n") ;;
            4)     picks+=(1 2 3) ;;
            *)     return 1 ;;
        esac
    done
    SELECTED=" ${picks[*]} "
}

selected() { [[ "$SELECTED" == *" $1 "* ]]; }

if [[ ${#NUMS[@]} -gt 0 ]]; then
    parse_selection "${NUMS[@]}" || { echo "${RED}Invalid choice: ${NUMS[*]}${RESET} (use numbers 1-4)"; exit 1; }
else
    [[ "$MODE" == "fix" ]] && echo "What do you want to fix?" || echo "What do you want to restore?"
    echo "  1: QEMU / KVM setup (\"Cowork requires QEMU\")"
    echo "  2: Cowork VM CLI (SDE wrapper, for CPUs without AVX2)"
    echo "  3: installSdk 30s timeout"
    echo "  4: All"
    while true; do
        read -r -p "Enter numbers separated by spaces (e.g. 1 3): " -a CHOICES || exit 1
        parse_selection "${CHOICES[@]}" && break
        echo "${RED}Invalid choice.${RESET} Use numbers 1-4 separated by spaces."
    done
fi

DISTRO=""
[[ -r /etc/os-release ]] && DISTRO=" $(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}") "

# --- 1) QEMU / KVM prerequisites ---------------------------------------------
# Paths Claude Desktop checks (Debian/Ubuntu layout), and where other distros
# ship the same files. The first existing candidate gets symlinked.
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
VIRTIOFSD="/usr/libexec/virtiofsd"
OVMF_CODE_CANDIDATES=(/usr/share/edk2/x64/OVMF_CODE.4m.fd     # Arch
                      /usr/share/edk2/ovmf/OVMF_CODE_4M.fd    # Fedora
                      /usr/share/edk2/ovmf/OVMF_CODE.fd)
OVMF_VARS_CANDIDATES=(/usr/share/edk2/x64/OVMF_VARS.4m.fd
                      /usr/share/edk2/ovmf/OVMF_VARS_4M.fd
                      /usr/share/edk2/ovmf/OVMF_VARS.fd)
VIRTIOFSD_CANDIDATES=(/usr/lib/virtiofsd                      # Arch
                      /usr/lib/qemu/virtiofsd                 # older Debian/Ubuntu
                      /usr/bin/virtiofsd)

install_packages() {
    local pkgs=()
    if [[ "$DISTRO" == *" arch "* ]]; then
        pkgs=(qemu-system-x86 edk2-ovmf virtiofsd)
        confirm_sudo pacman -S --needed "${pkgs[@]}"
    elif [[ "$DISTRO" == *" debian "* || "$DISTRO" == *" ubuntu "* ]]; then
        pkgs=(qemu-system-x86 ovmf virtiofsd)
        confirm_sudo apt-get install -y "${pkgs[@]}"
    elif [[ "$DISTRO" == *" fedora "* || "$DISTRO" == *" rhel "* ]]; then
        pkgs=(qemu-system-x86 edk2-ovmf virtiofsd)
        confirm_sudo dnf install -y "${pkgs[@]}"
    elif [[ "$DISTRO" == *" suse "* ]]; then
        pkgs=(qemu-x86 qemu-ovmf-x86_64 virtiofsd)
        confirm_sudo zypper install -y "${pkgs[@]}"
    else
        fail "unknown distribution, install QEMU (x86_64), OVMF and virtiofsd yourself"
        return 1
    fi
}

any_exists() {
    local c
    for c in "$@"; do [[ -e "$c" ]] && return 0; done
    return 1
}

# link TARGET CANDIDATE... : makes TARGET a symlink to the first existing candidate.
link_expected() {
    local target="$1" c; shift
    if [[ -e "$target" ]]; then
        ok "$target exists"
        return
    fi
    for c in "$@"; do
        if [[ -e "$c" ]]; then
            ask_sudo ln -s "$c" "$target" || return
            if sudo mkdir -p "$(dirname "$target")" && sudo ln -s "$c" "$target"; then
                patched "$target -> $c"
            else
                fail "could not create $target"
            fi
            return
        fi
    done
    fail "$target is missing and no known replacement was found"
}

# unlink TARGET CANDIDATE... : removes TARGET only if it is our symlink to a candidate.
unlink_expected() {
    local target="$1" dest c; shift
    if [[ -L "$target" ]]; then
        dest="$(readlink "$target")"
        for c in "$@"; do
            if [[ "$dest" == "$c" ]]; then
                confirm_sudo rm -f "$target" && restored "removed symlink $target" || fail "could not remove $target"
                return
            fi
        done
    fi
    ok "$target is not a symlink made by this script"
}

fix_qemu() {
    header "QEMU / KVM setup"

    if [[ "$MODE" == "restore" ]]; then
        unlink_expected "$OVMF_CODE" "${OVMF_CODE_CANDIDATES[@]}"
        unlink_expected "$OVMF_VARS" "${OVMF_VARS_CANDIDATES[@]}"
        unlink_expected "$VIRTIOFSD" "${VIRTIOFSD_CANDIDATES[@]}"
        skip "installed packages and kvm group membership are left as they are"
        return
    fi

    if ! grep -Eqw 'vmx|svm' /proc/cpuinfo 2>/dev/null; then
        fail "CPU virtualization (VT-x / AMD-V) is not available, enable it in the BIOS"
    fi

    if command -v qemu-system-x86_64 >/dev/null 2>&1 \
       && any_exists "$VIRTIOFSD" "${VIRTIOFSD_CANDIDATES[@]}" \
       && any_exists "$OVMF_CODE" "${OVMF_CODE_CANDIDATES[@]}"; then
        ok "QEMU, OVMF and virtiofsd are installed"
    else
        echo "  QEMU, OVMF or virtiofsd is missing, installing packages:"
        if install_packages; then
            patched "packages installed"
        else
            warn "packages not installed, skipping the remaining QEMU steps"
            return
        fi
    fi

    link_expected "$OVMF_CODE" "${OVMF_CODE_CANDIDATES[@]}"
    link_expected "$OVMF_VARS" "${OVMF_VARS_CANDIDATES[@]}"
    link_expected "$VIRTIOFSD" "${VIRTIOFSD_CANDIDATES[@]}"

    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        ok "/dev/kvm is accessible"
    elif id -nG | grep -qw kvm; then
        warn "you are in the kvm group but /dev/kvm is not accessible yet, log out and back in (or reboot)"
        REBOOT=1
    else
        local me; me="$(id -un)"
        echo "  /dev/kvm is not accessible, adding $me to the kvm group:"
        if ask_sudo usermod -aG kvm "$me"; then
            if sudo usermod -aG kvm "$me"; then
                patched "added $me to the kvm group"
                REBOOT=1
            else
                fail "could not add $me to the kvm group"
            fi
        fi
    fi
}

# --- 2) Cowork VM CLI --------------------------------------------------------
SDE_HOME="$HOME/.local/opt/intel-sde"

is_elf() {
    [[ -f "$1" ]] && [[ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" == '177ELF' ]]
}

is_script() {
    [[ -f "$1" ]] && [[ "$(head -c 2 "$1" 2>/dev/null)" == '#!' ]]
}

wrap() {
    local target="$1" real="$1.realbinary"

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

fix_vm_cli() {
    header "Cowork VM CLI"
    SDE=""
    if [[ "$MODE" == "fix" ]]; then
        if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
            skip "your CPU supports AVX2, no wrapper needed"
            return
        fi
        SDE="$(command -v intel-sde || command -v sde64 || command -v sde \
               || { [[ -x "$SDE_HOME/sde64" ]] && echo "$SDE_HOME/sde64"; } || true)"
        if [[ -z "$SDE" ]]; then
            fail "Intel SDE not found; install it with Claude-Code/Linux/fix/claude-sigill-fix.sh --install-sde"
            return
        fi
    fi

    local found=0 bin
    find "$HOME/.config/Claude/claude-code-vm" -maxdepth 2 \
         \( -name 'claude' -o -name 'claude.realbinary' \) 2>/dev/null \
        | sed 's/\.realbinary$//' | sort -u | while IFS= read -r bin; do
            found=1
            wrap "$bin"
        done
    [[ "$found" -eq 1 ]] || skip "Cowork VM CLI not found (open Cowork once so Claude Desktop downloads it)"
}

# --- 3) installSdk timeout ---------------------------------------------------
sudo_install() {
    sudo cp "$1" "$2" && sudo chown root:root "$2" && sudo chmod 755 "$2"
}

fix_timeout() {
    header "installSdk timeout (cowork-linux-helper)"
    local HELPER="" h COUNT TMP
    for h in /usr/lib/claude-desktop/resources/cowork-linux-helper \
             /opt/claude-desktop/resources/cowork-linux-helper; do
        [[ -f "$h" ]] && { HELPER="$h"; break; }
    done
    if [[ -z "$HELPER" ]]; then
        skip "cowork-linux-helper not found (AppImage installs must be extracted and rebuilt by hand)"
        return
    fi

    if [[ "$MODE" == "restore" ]]; then
        if [[ -f "$HELPER.orig.bak" ]]; then
            if confirm_sudo cp "$HELPER.orig.bak" "$HELPER" && sudo chown root:root "$HELPER" \
               && sudo chmod 755 "$HELPER" && sudo rm -f "$HELPER.orig.bak"; then
                restored "cowork-linux-helper restored from backup"
            else
                fail "could not restore cowork-linux-helper"
            fi
        else
            ok "cowork-linux-helper has no backup, nothing to restore"
        fi
        return
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 is required for this patch"
        return
    fi

    # 30 s and 900 s as little-endian int64 nanoseconds (Go time.Duration).
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
        echo "  found $COUNT x 30s constant, sudo needed to patch"
        TMP="$(mktemp)"
        cp "$HELPER" "$TMP"
        python3 - "$TMP" <<'PYEOF'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
d = d.replace(struct.pack("<Q", 30_000_000_000), struct.pack("<Q", 900_000_000_000))
open(p, "wb").write(d)
PYEOF
        # The file is unpatched right now, so this backup always matches the
        # currently installed version (an app update replaces the old one).
        if confirm_sudo cp "$HELPER" "$HELPER.orig.bak" && sudo_install "$TMP" "$HELPER"; then
            patched "cowork-linux-helper 30s -> 900s"
        else
            fail "could not patch cowork-linux-helper"
        fi
        rm -f "$TMP"
    fi
}

# --- Run selected targets ----------------------------------------------------
selected 1 && fix_qemu
selected 2 && fix_vm_cli
selected 3 && fix_timeout

# --- Summary -----------------------------------------------------------------
echo
echo "${BLUE}================ SUMMARY ================${RESET}"
if [[ "$CHANGED" -eq 1 ]]; then
    [[ "$MODE" == "restore" ]] && echo "${YELLOW}Changes were undone.${RESET}" \
                               || echo "${YELLOW}Some fixes were (re)applied.${RESET}"
    echo "Fully quit Claude Desktop and start it again."
else
    echo "${GREEN}Nothing to do.${RESET}"
fi
[[ "$REBOOT" -eq 1 ]] && echo "${YELLOW}Log out and back in (or reboot) so the kvm group takes effect.${RESET}"
[[ "$FAILED" -eq 1 ]] && echo "${RED}Some steps failed, see the [ERROR] lines above.${RESET}"
exit "$FAILED"
