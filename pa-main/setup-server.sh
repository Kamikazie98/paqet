#!/bin/bash
# Paqet Distribution Server Setup
# This script sets up a lightweight HTTP server to serve paqet binaries and installer.
#
# After running this, clients can install paqet with:
#   bash <(curl -fsSL http://YOUR_IP:8080/install.sh)
#
# Directory structure served:
#   /srv/paqet/
#   ├── install.sh              <- Quick installer (this is what clients curl)
#   ├── deploy-tunnel.sh        <- Full deployment/management script
#   └── bin/
#       ├── paqet-linux-amd64   <- Pre-built binaries per architecture
#       ├── paqet-linux-arm64
#       └── ...

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ICON_OK="✅"
ICON_ERR="❌"
ICON_INFO="ℹ️"

print_success() { echo -e "${GREEN}${ICON_OK}  $1${NC}"; }
print_error()   { echo -e "${RED}${ICON_ERR}  $1${NC}"; }
print_info()    { echo -e "${BLUE}${ICON_INFO}  $1${NC}"; }

SERVE_DIR="/srv/paqet"
SERVE_PORT="${PAQET_SERVE_PORT:-8080}"
SERVICE_NAME="paqet-dist"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Run as root: sudo $0"
        exit 1
    fi
}

# ─── Create directory structure ──────────────────────────────────────────────
setup_directories() {
    print_info "Creating directory structure at $SERVE_DIR"
    mkdir -p "$SERVE_DIR/bin"

    # Copy install.sh if present in same directory as this script
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    if [ -f "$script_dir/install.sh" ]; then
        cp "$script_dir/install.sh" "$SERVE_DIR/install.sh"
        chmod 644 "$SERVE_DIR/install.sh"
        print_success "Copied install.sh"
    else
        print_error "install.sh not found in $script_dir"
        print_info "Place install.sh next to this script and re-run"
        exit 1
    fi

    if [ -f "$script_dir/../deploy-tunnel.sh" ]; then
        cp "$script_dir/../deploy-tunnel.sh" "$SERVE_DIR/deploy-tunnel.sh"
        chmod 644 "$SERVE_DIR/deploy-tunnel.sh"
        print_success "Copied deploy-tunnel.sh"
    elif [ -f "$script_dir/deploy-tunnel.sh" ]; then
        cp "$script_dir/deploy-tunnel.sh" "$SERVE_DIR/deploy-tunnel.sh"
        chmod 644 "$SERVE_DIR/deploy-tunnel.sh"
        print_success "Copied deploy-tunnel.sh"
    else
        print_error "deploy-tunnel.sh not found"
        print_info "Place deploy-tunnel.sh in the parent directory or same directory"
        exit 1
    fi

    print_success "Directory structure ready"
}

# ─── Copy binaries ──────────────────────────────────────────────────────────
copy_binaries() {
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local bin_src=""

    # Look for binaries in common locations
    for dir in "$script_dir/bin" "$script_dir/../bin" "$script_dir/binaries" "$script_dir/../binaries"; do
        if [ -d "$dir" ] && ls "$dir"/paqet-linux-* &>/dev/null 2>&1; then
            bin_src="$dir"
            break
        fi
    done

    if [ -n "$bin_src" ]; then
        print_info "Copying binaries from $bin_src"
        cp "$bin_src"/paqet-linux-* "$SERVE_DIR/bin/" 2>/dev/null || true
        chmod 644 "$SERVE_DIR/bin/"* 2>/dev/null || true
        print_success "Binaries copied"
    else
        echo ""
        print_info "No pre-built binaries found."
        print_info "Place your compiled binaries in: $SERVE_DIR/bin/"
        print_info "Expected naming: paqet-linux-amd64, paqet-linux-arm64, etc."
        echo ""
    fi

    # Show what's available
    echo ""
    print_info "Current binary inventory:"
    if ls "$SERVE_DIR/bin/"paqet-linux-* &>/dev/null 2>&1; then
        for f in "$SERVE_DIR/bin/"paqet-linux-*; do
            local size
            size=$(du -h "$f" | cut -f1)
            echo "    $(basename "$f")  ($size)"
        done
    else
        echo "    (none - add binaries to $SERVE_DIR/bin/)"
    fi
    echo ""
}

# ─── Setup HTTP server ───────────────────────────────────────────────────────
setup_http_server() {
    print_info "Setting up HTTP file server on port $SERVE_PORT"

    # Prefer caddy > nginx > python as the file server
    if command -v caddy &>/dev/null; then
        setup_caddy
    elif command -v nginx &>/dev/null; then
        setup_nginx
    else
        setup_python_fallback
    fi
}

setup_caddy() {
    print_info "Using Caddy as file server"

    cat > /etc/caddy/Caddyfile <<EOF
:${SERVE_PORT} {
    root * ${SERVE_DIR}
    file_server browse
    header Content-Type text/plain
}
EOF

    systemctl restart caddy
    systemctl enable caddy
    print_success "Caddy configured and running on port $SERVE_PORT"
}

setup_nginx() {
    print_info "Using Nginx as file server"

    cat > /etc/nginx/sites-available/paqet-dist <<EOF
server {
    listen ${SERVE_PORT};
    server_name _;

    root ${SERVE_DIR};
    autoindex on;

    location / {
        default_type application/octet-stream;
    }

    location ~ \\.sh$ {
        default_type text/plain;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/paqet-dist /etc/nginx/sites-enabled/paqet-dist
    nginx -t && systemctl restart nginx && systemctl enable nginx
    print_success "Nginx configured and running on port $SERVE_PORT"
}

setup_python_fallback() {
    print_info "No caddy/nginx found, setting up Python HTTP server as systemd service"

    if ! command -v python3 &>/dev/null; then
        print_error "python3 is required (install: apt install python3)"
        exit 1
    fi

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Paqet Distribution File Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${SERVE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SERVE_PORT} --bind 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME}
    print_success "Python HTTP server running on port $SERVE_PORT"
}

# ─── Firewall ────────────────────────────────────────────────────────────────
open_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "$SERVE_PORT"/tcp &>/dev/null 2>&1 || true
        print_info "UFW: port $SERVE_PORT opened"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${SERVE_PORT}/tcp" &>/dev/null 2>&1 || true
        firewall-cmd --reload &>/dev/null 2>&1 || true
        print_info "firewalld: port $SERVE_PORT opened"
    fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="YOUR_SERVER_IP"

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    print_success "Paqet distribution server is ready!"
    echo ""
    echo -e "${YELLOW}Clients can install paqet with:${NC}"
    echo ""
    echo -e "  ${GREEN}bash <(curl -fsSL http://${ip}:${SERVE_PORT}/install.sh)${NC}"
    echo ""
    echo -e "${YELLOW}Or:${NC}"
    echo ""
    echo -e "  ${GREEN}curl -fsSL http://${ip}:${SERVE_PORT}/install.sh | sudo bash${NC}"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Files served from:${NC} $SERVE_DIR"
    echo -e "${YELLOW}Port:${NC} $SERVE_PORT"
    echo ""
    echo -e "${YELLOW}To add/update binaries:${NC}"
    echo -e "  cp paqet-linux-amd64 $SERVE_DIR/bin/"
    echo -e "  cp paqet-linux-arm64 $SERVE_DIR/bin/"
    echo ""
    echo -e "${YELLOW}To update the deploy script:${NC}"
    echo -e "  cp deploy-tunnel.sh $SERVE_DIR/deploy-tunnel.sh"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}     Paqet Distribution Server Setup${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    check_root
    setup_directories
    copy_binaries
    setup_http_server
    open_firewall
    print_summary
}

main "$@"
