#!/usr/bin/env bash
# ============================================================
#  Telegram Web Proxy — удаление
#  Полностью снимает установку, сделанную install-twebproxy.sh.
#  Аргументы:
#    --force / -y — без подтверждения
#    --help       — справка
# ============================================================
set -Eeuo pipefail
umask 077

MANIFEST="/etc/tproxy-webproxy-install.manifest"
FORCE=0

usage() {
    cat <<EOF
Usage: sudo $0 [--force|-y] [--help]

Удаляет Telegram Web Proxy и все связанные компоненты:
  - Caddy, tproxy-server relay, официальный MTProxy
  - systemd-юниты, конфиги, файлы сайта, пользователей
  - правила локального файрвола (порты 80/443)

Опции:
  --force, -y    Не запрашивать подтверждение
  --help         Показать справку
EOF
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-y) FORCE=1; shift ;;
        --help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run as root."

# --- чтение манифеста ---
REUSE_CADDY=0
REUSE_MT=0
REUSE_RELAY=0
FIREWALL_BACKEND="none"

if [[ -f "$MANIFEST" ]]; then
    echo "      Reading manifest from $MANIFEST"
    # shellcheck disable=SC1090
    . "$MANIFEST"
else
    echo "      Manifest not found; assuming conservative mode (reuse existing components)."
    REUSE_CADDY=1
    REUSE_MT=1
    REUSE_RELAY=1
fi

echo
echo "============================================================"
echo "           TELEGRAM WEB PROXY UNINSTALLER"
echo "============================================================"
echo
echo "Reuse flags from manifest:"
echo "  Caddy:   $REUSE_CADDY"
echo "  MTProxy: $REUSE_MT"
echo "  Relay:   $REUSE_RELAY"
echo "  Firewall: $FIREWALL_BACKEND"
echo

if [[ "$FORCE" != "1" ]]; then
    echo "WARNING: This will remove Telegram Web Proxy and its components."
    echo "Type REMOVE to confirm:"
    read -r confirm
    [[ "$confirm" == "REMOVE" ]] || die "Aborted."
fi

echo
echo "[1/6] Stopping and disabling systemd services..."
for unit in mtproxy tproxy-server caddy tproxy-firewall refresh-mtproxy-config.timer refresh-mtproxy-config.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done
echo "      OK"

echo "[2/6] Removing systemd unit files..."
for unit in mtproxy tproxy-server caddy tproxy-firewall refresh-mtproxy-config.timer refresh-mtproxy-config.service; do
    rm -f "/etc/systemd/system/${unit}"
done
rm -rf /etc/systemd/system/caddy.service.d
systemctl daemon-reload
echo "      OK"

echo "[3/6] Closing firewall ports..."
close_http_ports() {
    case "$FIREWALL_BACKEND" in
        ufw)
            ufw delete allow 80/tcp 2>/dev/null || true
            ufw delete allow 443/tcp 2>/dev/null || true
            ufw reload 2>/dev/null || true
            echo "      ufw: closed 80/tcp and 443/tcp"
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port=80/tcp 2>/dev/null || true
            firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            echo "      firewalld: closed 80/tcp and 443/tcp"
            ;;
        iptables)
            iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
            install -d /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            echo "      iptables: removed 80/tcp and 443/tcp accept rules"
            ;;
    esac
}
close_http_ports

# Удаляем nft таблицу (блокировка 2398/8888)
if command -v nft >/dev/null 2>&1; then
    nft delete table inet tproxy_backend 2>/dev/null || true
    echo "      nftables: removed tproxy_backend table"
fi
echo "      OK"

echo "[4/6] Removing binaries and files..."
if [[ "$REUSE_CADDY" != "1" ]]; then
    rm -f /usr/local/bin/caddy
    rm -rf /etc/caddy
    rm -rf /var/lib/caddy
    echo "      Caddy removed"
else
    echo "      Caddy preserved (reuse flag)"
fi

if [[ "$REUSE_MT" != "1" ]]; then
    rm -rf /opt/MTProxy
    rm -rf /etc/mtproxy
    echo "      MTProxy removed"
else
    echo "      MTProxy preserved (reuse flag)"
fi

if [[ "$REUSE_RELAY" != "1" ]]; then
    rm -f /usr/local/bin/tproxy-server
    echo "      Relay removed"
else
    echo "      Relay preserved (reuse flag)"
fi

rm -rf /etc/tproxy-server
rm -rf /srv/tproxy-site
rm -rf /opt/tproxy-site
rm -rf /root/tproxy-server
rm -f /usr/local/sbin/refresh-mtproxy-config
rm -f "$MANIFEST"
echo "      Configs, site, source, manifest removed"

echo "[5/6] Removing system users..."
remove_user_if_safe() {
    local user="$1" home="$2" shell="$3"
    local current_home
    current_home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    local current_shell
    current_shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || true)"
    if [[ "$current_home" == "$home" && "$current_shell" == "$shell" ]]; then
        userdel "$user" 2>/dev/null || true
        echo "      User $user removed"
    else
        echo "      User $user preserved (custom home/shell)"
    fi
}
remove_user_if_safe caddy  /var/lib/caddy  /usr/sbin/nologin
remove_user_if_safe mtproxy /nonexistent     /usr/sbin/nologin
remove_user_if_safe tproxy  /nonexistent     /usr/sbin/nologin

echo "[6/6] Done."
echo
echo "============================================================"
echo "             TELEGRAM WEB PROXY HAS BEEN REMOVED"
echo "============================================================"