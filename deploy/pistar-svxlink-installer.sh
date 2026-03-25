#!/bin/bash
#
# pistar-svxlink-installer.sh
# Installs SVXLink support on an existing Pi-Star system.
#
# This script:
#   1. Installs the svxlink-server package
#   2. Deploys the SVXLink-enabled dashboard (git remote swap)
#   3. Installs the svxlink_ctrl helper script
#   4. Deploys the SVXLinkHosts.txt reflector list
#   5. Creates a default SVXLink configuration
#   6. Configures sudoers for web-based control
#
# Usage:
#   sudo ./pistar-svxlink-installer.sh [--dashboard-repo <url>] [--uninstall]
#

set -e

# ── Configuration ─────────────────────────────────────────────────────
DASHBOARD_DIR="/var/www/dashboard"
DASHBOARD_REPO_DEFAULT="https://github.com/AndyTaylorTweet/Pi-Star_DV_Dash"
SVXLINK_CONF_DIR="/etc/svxlink"
SVXLINK_CONF="${SVXLINK_CONF_DIR}/svxlink.conf"
SVXLINK_CTRL="/usr/local/sbin/svxlink_ctrl"
SVXLINK_HOSTS="/usr/local/etc/SVXLinkHosts.txt"
SVXLINK_LOG_DIR="/var/log/svxlink"
SUDOERS_FILE="/etc/sudoers.d/020_svxlink"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Color helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Preflight checks ─────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
    fi
}

check_pistar() {
    if [ ! -f /etc/pistar-release ]; then
        error "This does not appear to be a Pi-Star system (/etc/pistar-release not found)"
    fi
    info "Pi-Star detected: $(grep 'Version' /etc/pistar-release | cut -d= -f2)"
}

check_disk_space() {
    # Require at least 50MB free on root filesystem
    MIN_KB=51200
    AVAIL_KB=$(df / --output=avail | tail -1 | tr -d ' ')
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [ "$AVAIL_KB" -lt "$MIN_KB" ]; then
        error "Not enough disk space: ${AVAIL_MB}MB available, need at least 50MB. Free up space and try again."
    fi
    info "Disk space OK: ${AVAIL_MB}MB available"
}

check_rw() {
    # Verify filesystem is mounted read-write
    if ! touch /tmp/.svxlink_rw_test 2>/dev/null; then
        error "Filesystem appears read-only. Run 'rpi-rw' first."
    fi
    rm -f /tmp/.svxlink_rw_test
}

# ── Parse arguments ──────────────────────────────────────────────────
DASHBOARD_REPO="$DASHBOARD_REPO_DEFAULT"
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dashboard-repo)
            DASHBOARD_REPO="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            echo "Usage: sudo $0 [--dashboard-repo <url>] [--uninstall]"
            echo ""
            echo "Options:"
            echo "  --dashboard-repo <url>  Git repo URL for SVXLink-enabled dashboard"
            echo "                          (default: ${DASHBOARD_REPO_DEFAULT})"
            echo "  --uninstall             Remove SVXLink support and restore original dashboard"
            echo "  -h, --help              Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# ── Uninstall ─────────────────────────────────────────────────────────
do_uninstall() {
    info "Uninstalling SVXLink support..."

    # Stop SVXLink
    systemctl stop svxlink 2>/dev/null || true
    systemctl disable svxlink 2>/dev/null || true

    # Remove helper script
    if [ -f "$SVXLINK_CTRL" ]; then
        rm -f "$SVXLINK_CTRL"
        info "Removed $SVXLINK_CTRL"
    fi

    # Remove sudoers entry
    if [ -f "$SUDOERS_FILE" ]; then
        rm -f "$SUDOERS_FILE"
        info "Removed $SUDOERS_FILE"
    fi

    # Restore original dashboard repo
    if [ -d "${DASHBOARD_DIR}/.git" ]; then
        git config --global --add safe.directory "$DASHBOARD_DIR"
        cd "$DASHBOARD_DIR"
        # Read saved original remote, fall back to default
        if [ -f "${DASHBOARD_DIR}/.original_remote" ]; then
            ORIG_REMOTE=$(cat "${DASHBOARD_DIR}/.original_remote")
        else
            ORIG_REMOTE="$DASHBOARD_REPO_DEFAULT"
        fi
        [ -z "$ORIG_REMOTE" ] && ORIG_REMOTE="$DASHBOARD_REPO_DEFAULT"
        CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
        if [ "$CURRENT_REMOTE" != "$ORIG_REMOTE" ]; then
            git remote set-url origin "$ORIG_REMOTE"
            git fetch origin
            git reset --hard origin/master
            rm -f "${DASHBOARD_DIR}/.original_remote"
            info "Dashboard restored to: $ORIG_REMOTE"
        fi
    fi

    # Optionally remove svxlink package
    read -p "Remove svxlink-server package? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        apt-get remove -y svxlink-server 2>/dev/null || true
        info "Removed svxlink-server package"
    fi

    info "SVXLink support uninstalled."
    exit 0
}

# ── Install: Step 1 - SVXLink package ────────────────────────────────
install_svxlink_package() {
    info "Step 1/7: Installing svxlink-server package..."

    if command -v svxlink >/dev/null 2>&1; then
        info "svxlink-server is already installed: $(svxlink --version 2>&1 | head -1)"
        return
    fi

    # Make filesystem writable (Pi-Star uses read-only root)
    mount -o remount,rw / 2>/dev/null || true
    mount -o remount,rw /boot 2>/dev/null || true

    # Disable stale repos temporarily to avoid apt-get update failures
    # (Pi-Star bullseye-backports is commonly expired)
    DISABLED_LISTS=""
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -q 'backports' "$f" 2>/dev/null; then
            mv "$f" "${f}.disabled"
            DISABLED_LISTS="${DISABLED_LISTS} ${f}"
            warn "Temporarily disabled stale repo: $(basename "$f")"
        fi
    done
    # Also check main sources.list for backports
    if grep -q 'backports' /etc/apt/sources.list 2>/dev/null; then
        sed -i '/backports/s/^/#/' /etc/apt/sources.list
        DISABLED_LISTS="${DISABLED_LISTS} /etc/apt/sources.list:backports"
        warn "Temporarily commented out backports in sources.list"
    fi

    apt-get update -qq || warn "Some repos failed to update, continuing anyway..."
    apt-get install -y svxlink-server || error "Failed to install svxlink-server. You may need to install it manually."

    # Re-enable disabled repos
    for f in $DISABLED_LISTS; do
        if [ "$f" = "/etc/apt/sources.list:backports" ]; then
            sed -i '/backports/s/^#//' /etc/apt/sources.list
        elif [ -f "${f}.disabled" ]; then
            mv "${f}.disabled" "$f"
        fi
    done

    info "svxlink-server installed successfully"
}

# ── Install: Step 2 - Dashboard update ───────────────────────────────
install_dashboard() {
    info "Step 2/7: Updating dashboard with SVXLink support..."

    if [ ! -d "${DASHBOARD_DIR}/.git" ]; then
        error "Dashboard git repo not found at $DASHBOARD_DIR"
    fi

    # Mark dashboard dir as safe for git (running as root, dir owned by www-data)
    git config --global --add safe.directory "$DASHBOARD_DIR"

    cd "$DASHBOARD_DIR"

    # Check current remote
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [ "$CURRENT_REMOTE" = "$DASHBOARD_REPO" ]; then
        info "Dashboard already points to $DASHBOARD_REPO"
        git fetch origin
        git reset --hard origin/master
    else
        info "Switching dashboard remote from $CURRENT_REMOTE to $DASHBOARD_REPO"
        # Save the original remote for uninstall
        echo "$CURRENT_REMOTE" > "${DASHBOARD_DIR}/.original_remote"
        git remote set-url origin "$DASHBOARD_REPO"
        git fetch origin
        git reset --hard origin/master
    fi

    info "Dashboard updated"
}

# ── Install: Step 3 - Control script ─────────────────────────────────
install_ctrl_script() {
    info "Step 3/7: Installing svxlink_ctrl helper script..."

    if [ -f "${SCRIPT_DIR}/svxlink_ctrl" ]; then
        cp "${SCRIPT_DIR}/svxlink_ctrl" "$SVXLINK_CTRL"
    else
        # Fallback: download from dashboard repo
        if [ -f "${DASHBOARD_DIR}/deploy/svxlink_ctrl" ]; then
            cp "${DASHBOARD_DIR}/deploy/svxlink_ctrl" "$SVXLINK_CTRL"
        else
            error "svxlink_ctrl not found in ${SCRIPT_DIR}/ or ${DASHBOARD_DIR}/deploy/"
        fi
    fi

    chmod 755 "$SVXLINK_CTRL"
    chown root:root "$SVXLINK_CTRL"
    info "Installed $SVXLINK_CTRL"
}

# ── Install: Step 4 - Hosts file ─────────────────────────────────────
install_hosts_file() {
    info "Step 4/7: Installing SVXLink hosts file..."

    if [ -f "$SVXLINK_HOSTS" ]; then
        info "SVXLinkHosts.txt already exists, keeping existing file"
        return
    fi

    if [ -f "${SCRIPT_DIR}/SVXLinkHosts.txt" ]; then
        cp "${SCRIPT_DIR}/SVXLinkHosts.txt" "$SVXLINK_HOSTS"
    elif [ -f "${DASHBOARD_DIR}/deploy/SVXLinkHosts.txt" ]; then
        cp "${DASHBOARD_DIR}/deploy/SVXLinkHosts.txt" "$SVXLINK_HOSTS"
    else
        # Create a minimal hosts file
        cat > "$SVXLINK_HOSTS" <<'HOSTS'
# SVXLink Reflector Hosts
# Format: Name  Host
# Lines starting with # are comments
HOSTS
        warn "Created empty hosts file at $SVXLINK_HOSTS - add reflectors manually"
    fi

    chmod 644 "$SVXLINK_HOSTS"
    info "Installed $SVXLINK_HOSTS"
}

# ── Install: Step 5 - Default SVXLink config ─────────────────────────
install_svxlink_config() {
    info "Step 5/7: Configuring SVXLink..."

    mkdir -p "$SVXLINK_CONF_DIR" 2>/dev/null || true
    # Log dir may exist as a symlink from the svxlink package
    if [ ! -d "$SVXLINK_LOG_DIR" ]; then
        mkdir -p "$SVXLINK_LOG_DIR" 2>/dev/null || true
    fi

    # Read callsign from mmdvmhost if available
    CALLSIGN=""
    if [ -f /etc/mmdvmhost ]; then
        CALLSIGN=$(grep -A 20 '^\[General\]' /etc/mmdvmhost | grep '^Callsign=' | head -1 | cut -d= -f2 | tr -d '[:space:]')
    fi
    if [ -z "$CALLSIGN" ]; then
        CALLSIGN="N0CALL"
        warn "Could not determine callsign from mmdvmhost, using $CALLSIGN"
    fi

    # Backup existing config if present
    if [ -f "$SVXLINK_CONF" ]; then
        cp "$SVXLINK_CONF" "${SVXLINK_CONF}.bak"
        info "Backed up existing config to ${SVXLINK_CONF}.bak"
    fi

    cat > "$SVXLINK_CONF" <<CONF
[GLOBAL]
LOGICS=SimplexLogic
CFG_DIR=svxlink.d
TIMESTAMP_FORMAT="%c"
CARD_SAMPLE_RATE=48000

[SimplexLogic]
TYPE=Simplex
RX=Rx1
TX=Tx1
MODULES=
CALLSIGN=${CALLSIGN}
SHORT_IDENT_INTERVAL=60
LONG_IDENT_INTERVAL=60
EVENT_HANDLER=/usr/share/svxlink/events.tcl
DEFAULT_LANG=en_US
RGR_SOUND_DELAY=0
FX_GAIN_NORMAL=0
FX_GAIN_LOW=-12

[Rx1]
TYPE=Local
AUDIO_DEV=udp:127.0.0.1:3810
AUDIO_CHANNEL=0
SQL_DET=VOX
SQL_START_DELAY=0
SQL_DELAY=0
SQL_HANGTIME=2000
VOX_FILTER_DEPTH=20
VOX_THRESH=1000
DEEMPHASIS=0
PEAK_METER=1
DTMF_DEC_TYPE=INTERNAL
DTMF_MUTING=1
DTMF_HANGTIME=40

[Tx1]
TYPE=Local
AUDIO_DEV=udp:127.0.0.1:4810
AUDIO_CHANNEL=0
PTT_TYPE=NONE
TIMEOUT=300
TX_DELAY=500
PREEMPHASIS=0
DTMF_TONE_LENGTH=100
DTMF_TONE_SPACING=50
DTMF_DIGIT_PWR=-15

[ReflectorLogic]
TYPE=Reflector
HOST=
CALLSIGN=${CALLSIGN}
AUTH_KEY="Change this key now!"
JITTER_BUFFER_DELAY=0
CONF

    chmod 644 "$SVXLINK_CONF"
    info "Created SVXLink config at $SVXLINK_CONF"
    info "Audio: Rx=udp:127.0.0.1:3810 Tx=udp:127.0.0.1:4810"
    warn "Set AUTH_KEY via /admin/expert/edit_svxlink.php before connecting to a reflector"
}

# ── Install: Step 6 - MMDVMHost FM Network ───────────────────────────
install_mmdvmhost_fm_network() {
    info "Step 6/7: Configuring MMDVMHost FM Network..."

    MMDVM_CONF="/etc/mmdvmhost"
    if [ ! -f "$MMDVM_CONF" ]; then
        warn "MMDVMHost config not found at $MMDVM_CONF, skipping FM Network setup"
        return
    fi

    # Check if [FM Network] section already exists
    if grep -q '^\[FM Network\]' "$MMDVM_CONF" 2>/dev/null; then
        # Section exists - ensure Enable=1
        if grep -A 5 '^\[FM Network\]' "$MMDVM_CONF" | grep -q '^Enable=1'; then
            info "FM Network already enabled in $MMDVM_CONF"
        else
            sed -i '/^\[FM Network\]/,/^\[/ s/^Enable=.*/Enable=1/' "$MMDVM_CONF"
            info "Enabled FM Network in $MMDVM_CONF"
        fi
    else
        # Append [FM Network] section
        cat >> "$MMDVM_CONF" <<'FMNET'

[FM Network]
Enable=1
LocalAddress=127.0.0.1
LocalPort=3810
GatewayAddress=127.0.0.1
GatewayPort=4810
Protocol=RAW
SampleRate=8000
ModeHang=20
FMNET
        info "Added [FM Network] section to $MMDVM_CONF"
    fi

    # Ensure [FM] section exists with Enable=1
    if grep -q '^\[FM\]' "$MMDVM_CONF" 2>/dev/null; then
        if ! grep -A 5 '^\[FM\]' "$MMDVM_CONF" | grep -q '^Enable=1'; then
            sed -i '/^\[FM\]/,/^\[/ s/^Enable=.*/Enable=1/' "$MMDVM_CONF"
            info "Enabled FM mode in $MMDVM_CONF"
        fi
    else
        cat >> "$MMDVM_CONF" <<'FMSECT'

[FM]
Enable=1
FMSECT
        info "Added [FM] section to $MMDVM_CONF"
    fi

    info "MMDVMHost FM Network configured (UDP ports 3810/4810)"
}

# ── Install: Step 7 - Sudoers ────────────────────────────────────────
install_sudoers() {
    info "Step 7/7: Configuring sudoers for web control..."

    cat > "$SUDOERS_FILE" <<'SUDOERS'
# Allow www-data to control SVXLink via the dashboard
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/svxlink_ctrl
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl start svxlink
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop svxlink
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart svxlink
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl status svxlink
SUDOERS

    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE" || error "Sudoers syntax check failed"
    info "Sudoers configured"
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║      Pi-Star SVXLink Installer                  ║"
    echo "║      Adds SVXLink FM gateway support            ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    check_root
    check_pistar
    check_rw
    check_disk_space

    if [ "$UNINSTALL" -eq 1 ]; then
        do_uninstall
    fi

    # Make filesystem writable (Pi-Star uses read-only root)
    mount -o remount,rw / 2>/dev/null || true
    mount -o remount,rw /boot 2>/dev/null || true

    install_svxlink_package
    install_dashboard
    install_ctrl_script
    install_hosts_file
    install_svxlink_config
    install_mmdvmhost_fm_network
    install_sudoers

    # Enable and start services
    systemctl enable svxlink 2>/dev/null || true
    systemctl restart mmdvmhost 2>/dev/null || true
    systemctl start svxlink 2>/dev/null || true

    echo ""
    info "═══════════════════════════════════════════════════"
    info "SVXLink support installed successfully!"
    info ""
    info "Next steps:"
    info "  1. Set AUTH_KEY via web: /admin/expert/edit_svxlink.php"
    info "  2. Add reflector hosts via web: /admin/expert/fulledit_svxlinkhosts.php"
    info "  3. Use the SVXLink Manager in the admin dashboard"
    info ""
    info "To uninstall: sudo $0 --uninstall"
    info "═══════════════════════════════════════════════════"
}

main "$@"
