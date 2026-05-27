#!/bin/bash
# Paqet Quick Installer
# Usage: bash <(curl -fsSL http://YOUR_SERVER:8080/install.sh)
#    or: curl -fsSL http://YOUR_SERVER:8080/install.sh | bash
#
# This script downloads the paqet binary and deployment script from your server,
# installs them, and launches the interactive setup wizard.

set -e

# ─── Configuration ───────────────────────────────────────────────────────────
# The server URL is auto-detected from where this script was downloaded.
# If running locally, set PAQET_SERVER manually:
#   export PAQET_SERVER="http://1.2.3.4:8080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ICON_OK="✅"
ICON_ERR="❌"
ICON_WARN="⚠️"
ICON_INFO="ℹ️"

print_success() { echo -e "${GREEN}${ICON_OK}  $1${NC}"; }
print_error()   { echo -e "${RED}${ICON_ERR}  $1${NC}"; }
print_warning() { echo -e "${YELLOW}${ICON_WARN}  $1${NC}"; }
print_info()    { echo -e "${BLUE}${ICON_INFO}  $1${NC}"; }

# ─── Detect server URL ───────────────────────────────────────────────────────
detect_server_url() {
    if [ -n "$PAQET_SERVER" ]; then
        echo "$PAQET_SERVER"
        return
    fi

    # Try to detect from /proc if piped from curl
    local url=""
    if [ -f /proc/$PPID/cmdline ]; then
        url=$(tr '\0' ' ' < /proc/$PPID/cmdline 2>/dev/null | grep -oP 'https?://[^\s/]+' | head -1)
    fi

    if [ -n "$url" ]; then
        echo "$url"
        return
    fi

    # Fallback: ask user
    echo ""
}

# ─── Pre-flight checks ──────────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_deps() {
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        print_error "curl or wget is required"
        exit 1
    fi
}

# ─── Download helper ─────────────────────────────────────────────────────────
download() {
    local url="$1"
    local dest="$2"

    if command -v curl &>/dev/null; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    fi
}

# ─── Detect architecture ────────────────────────────────────────────────────
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armhf)   echo "arm32" ;;
        mips)           echo "mips" ;;
        mipsel|mipsle)  echo "mipsle" ;;
        mips64)         echo "mips64" ;;
        mips64el|mips64le) echo "mips64le" ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        Paqet Tunnel - Quick Installer${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""

    check_root
    check_deps

    local server_url
    server_url=$(detect_server_url)

    if [ -z "$server_url" ]; then
        echo -e -n "${YELLOW}Enter your paqet server URL (e.g. http://1.2.3.4:8080): ${NC}"
        read -r server_url
        server_url=$(echo "$server_url" | tr -d '[:space:]')
        server_url="${server_url%/}"
    fi

    if [ -z "$server_url" ]; then
        print_error "Server URL is required"
        exit 1
    fi

    print_info "Server: $server_url"

    local arch
    arch=$(detect_arch)
    print_info "Architecture: linux-$arch"

    # ─── Download paqet binary ───────────────────────────────────────────
    local binary_url="${server_url}/bin/paqet-linux-${arch}"
    local install_path="/usr/local/bin/paqet-core"

    print_info "Downloading paqet binary..."
    local tmp_bin
    tmp_bin=$(mktemp)

    if ! download "$binary_url" "$tmp_bin"; then
        print_error "Failed to download binary from: $binary_url"
        print_info "Make sure the binary for your architecture is available on the server"
        rm -f "$tmp_bin"
        exit 1
    fi

    # Verify it's not an error page
    if file "$tmp_bin" 2>/dev/null | grep -qi "text"; then
        print_error "Downloaded file is not a valid binary (got text/HTML)"
        print_info "Check that $binary_url exists on the server"
        rm -f "$tmp_bin"
        exit 1
    fi

    mv "$tmp_bin" "$install_path"
    chmod +x "$install_path"
    print_success "Binary installed: $install_path"

    # ─── Download deploy script ──────────────────────────────────────────
    local script_url="${server_url}/deploy-tunnel.sh"
    local script_path="/usr/local/bin/paqet"

    print_info "Downloading deployment script..."
    local tmp_script
    tmp_script=$(mktemp)

    if ! download "$script_url" "$tmp_script"; then
        print_error "Failed to download deploy script from: $script_url"
        rm -f "$tmp_script"
        exit 1
    fi

    mv "$tmp_script" "$script_path"
    chmod +x "$script_path"
    print_success "Deploy script installed: $script_path"

    # ─── Summary ─────────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    print_success "Installation complete!"
    echo ""
    print_info "Binary:  $install_path"
    print_info "Script:  $script_path"
    echo ""
    echo -e "${YELLOW}To set up a tunnel, run:${NC}"
    echo -e "  ${GREEN}sudo paqet${NC}"
    echo ""
    echo -e "${YELLOW}Other commands:${NC}"
    echo -e "  ${GREEN}sudo paqet --status${NC}       Show tunnel status"
    echo -e "  ${GREEN}sudo paqet --manage${NC}       Management menu"
    echo -e "  ${GREEN}sudo paqet --update-core${NC}  Update binary from server"
    echo -e "  ${GREEN}sudo paqet --help${NC}         Show all options"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""

    # ─── Launch wizard ───────────────────────────────────────────────────
    local response=""
    echo -e -n "${YELLOW}Launch tunnel setup wizard now? (yes/no, default: yes): ${NC}"
    read -r response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    if [ -z "$response" ] || [ "$response" = "yes" ] || [ "$response" = "y" ]; then
        exec "$script_path"
    fi
}

main "$@"
