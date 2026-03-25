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
        cd "$DASHBOARD_DIR"
        CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
        if [ "$CURRENT_REMOTE" != "$DASHBOARD_REPO_DEFAULT" ]; then
            git remote set-url origin "$DASHBOARD_REPO_DEFAULT"
            git fetch origin
            git reset --hard origin/master
            info "Dashboard restored to upstream: $DASHBOARD_REPO_DEFAULT"
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
    info "Step 1/6: Installing svxlink-server package..."

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
    info "Step 2/6: Updating dashboard with SVXLink support..."

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
    info "Step 3/6: Installing svxlink_ctrl helper script..."

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
    info "Step 4/6: Installing SVXLink hosts file..."

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
    info "Step 5/6: Configuring SVXLink..."

    mkdir -p "$SVXLINK_CONF_DIR" 2>/dev/null || true
    # Log dir may exist as a symlink from the svxlink package
    if [ ! -d "$SVXLINK_LOG_DIR" ]; then
        mkdir -p "$SVXLINK_LOG_DIR" 2>/dev/null || true
    fi

    if [ -f "$SVXLINK_CONF" ]; then
        info "SVXLink config already exists at $SVXLINK_CONF, keeping existing"
        return
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

    cat > "$SVXLINK_CONF" <<CONF
[GLOBAL]
LOGICS=SimplexLogic
CALLSIGN=${CALLSIGN}
TIMESTAMP_FORMAT="%c"
CARD_SAMPLE_RATE=48000
CARD_CHANNELS=1
LOCATION_INFO=LocationInfo

[SimplexLogic]
TYPE=Simplex
RX=Rx1
TX=Tx1
MODULES=
CALLSIGN=${CALLSIGN}
SHORT_IDENT_INTERVAL=10
LONG_IDENT_INTERVAL=60
IDENT_NAG_TIMEOUT=20
IDENT_NAG_MIN_TIME=2000
FX_GAIN_NORMAL=0
FX_GAIN_LOW=-12
RGR_SOUND_DELAY=0

[Rx1]
TYPE=Local
AUDIO_DEV=alsa:plughw:0
AUDIO_CHANNEL=0
SQL_DET=VOX
SQL_START_DELAY=0
SQL_DELAY=0
SQL_HANGTIME=2000
VOX_FILTER_DEPTH=300
VOX_THRESH=1000

[Tx1]
TYPE=Local
AUDIO_DEV=alsa:plughw:0
AUDIO_CHANNEL=0
PTT_TYPE=NONE
TIMEOUT=300

[ReflectorLogic]
TYPE=Reflector
HOST=
TG=
AUTH_KEY=
CALLSIGN=${CALLSIGN}
JITTER_BUFFER_DELAY=0

[LocationInfo]
BEACON_INTERVAL=15
TX_FREQUENCY=0
RX_FREQUENCY=0
TX_POWER=1
ANTENNA_HEIGHT=10
ANTENNA_GAIN=0
ANTENNA_DIR=-1
PATH=
COMMENT=Pi-Star SVXLink
CONF

    chmod 644 "$SVXLINK_CONF"
    info "Created default SVXLink config at $SVXLINK_CONF"
    warn "You must edit $SVXLINK_CONF to configure audio devices and reflector settings"
}

# ── Install: Step 6 - Sudoers ────────────────────────────────────────
install_sudoers() {
    info "Step 6/6: Configuring sudoers for web control..."

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
    install_sudoers

    # Enable SVXLink service (but don't start it - needs config first)
    systemctl enable svxlink 2>/dev/null || true

    echo ""
    info "═══════════════════════════════════════════════════"
    info "SVXLink support installed successfully!"
    info ""
    info "Next steps:"
    info "  1. Edit $SVXLINK_CONF to configure audio devices"
    info "  2. Edit $SVXLINK_HOSTS to add reflector hosts"
    info "  3. Enable FM mode in MMDVMHost (/admin/configure.php)"
    info "  4. Start SVXLink: sudo systemctl start svxlink"
    info "  5. Use the SVXLink Manager in the admin dashboard"
    info ""
    info "To uninstall: sudo $0 --uninstall"
    info "═══════════════════════════════════════════════════"
}

main "$@"
