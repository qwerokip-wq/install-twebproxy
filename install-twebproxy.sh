#!/usr/bin/env bash
# ============================================================
#  Telegram Web Proxy — автоматическая установка
#  Caddy + tproxy-server relay + официальный MTProxy
#  Поддержка: Ubuntu 22.04+ / Debian 12+ (x86_64)
#
#  Примеры:
#    sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com
#    sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --secret 000102...
#    sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --site-dir ./my-site
#    sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --site-upstream http://127.0.0.1:3000
#    sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --site-dir ./game --site-csp "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'"
# ============================================================
set -Eeuo pipefail
umask 077

VERSION="V 1.0"
REPO_URL="https://github.com/telegramdesktop/tproxy-server.git"
REPO_DIR="/root/tproxy-server"
SITE_INPUT="/opt/tproxy-site"
SITE_TARGET="/srv/tproxy-site"
MANIFEST="/etc/tproxy-webproxy-install.manifest"

# --- параметры ---
DOMAIN=""
EMAIL=""
SECRET=""
MT_WORKERS=1
MT_MAX_CONNECTIONS=4096
SITE_DIR=""
SITE_UPSTREAM=""
SITE_CSP=""
SKIP_DNS_CHECK=0
REUSE_MT=0
REUSE_RELAY=0
REUSE_CADDY=0
FIREWALL_BACKEND="none"

usage() {
    cat <<EOF
Usage: sudo $0 --domain HOST --email ADDRESS [options]

Обязательные:
  --domain HOST          Имя хоста (A-запись указывает на этот VPS), напр. proxy.example.com
  --email ADDRESS        Контактный email для ACME (Let's Encrypt)

Опции:
  --secret HEX           Секрет клиента: 32 hex или dd+32 hex. Если не указан — генерируется сам.
  --workers N            Рабочих процессов MTProxy (default: 1, максимум 256)
  --max-connections N    Лимит соединений MTProxy на воркер (default: 4096)
  --site-dir DIR         Статический сайт оператора вместо встроенной заглушки
  --site-upstream URL    http://127.0.0.1:PORT локального веб-приложения вместо статики
  --site-csp STRING      Content-Security-Policy для сайта оператора (заменяет строгий
                         дефолт relay). Нужен для сайтов с eval()/inline-скриптами,
                         напр. HTML5-игр. Пример: "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'"
  --skip-dns-check       Не сверять DNS с публичным IP VPS (только проверить, что A-запись существует)
  -h, --help             Показать справку

Пример:
  sudo $0 --domain proxy.example.com --email admin@example.com
EOF
    exit 0
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

valid_domain() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] &&
        [[ "$1" == *.* ]] &&
        [[ "$1" != *..* ]]
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_secret() {
    [[ "$1" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]
}

port_is_listening() {
    local port="$1"
    ss -lnt | grep -Eq ":${port}\b"
}

port_has_expected_process() {
    local port="$1"
    local process="$2"
    ss -lntp 2>/dev/null |
        grep -Eq ":${port}\b.*users:\(\("${process}"\""
}

check_install_port() {
    local port="$1"
    local process="$2"

    if ! port_is_listening "$port"; then
        echo "      :${port} free"
        return 0
    fi
    if port_has_expected_process "$port" "$process"; then
        echo "      :${port} already used by ${process}; continuing."
        return 0
    fi
    ss -lntp | grep -E ":${port}\b" || true
    die "Port ${port} is occupied by an unexpected process."
}

# --- автоматическое открытие портов 80/443 в локальном файрволе ---
open_http_ports() {
    FIREWALL_BACKEND="none"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw reload
        FIREWALL_BACKEND="ufw"
        echo "      ufw: opened 80/tcp and 443/tcp"
    elif systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --reload
        FIREWALL_BACKEND="firewalld"
        echo "      firewalld: opened 80/tcp and 443/tcp"
    elif command -v iptables >/dev/null 2>&1 &&
        iptables -L INPUT -n 2>/dev/null | grep -qE "DROP|REJECT|policy DROP"; then
        iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
        install -d /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        FIREWALL_BACKEND="iptables"
        echo "      iptables: opened 80/tcp and 443/tcp"
    else
        echo "      no active local firewall; ports 80/443 open by default"
    fi
}

show_failure() {
    echo
    echo "============================================================"
    echo "                    INSTALLATION FAILED"
    echo "============================================================"
    echo
    echo "--- services ---"
    systemctl --no-pager --full status mtproxy tproxy-server caddy tproxy-firewall 2>/dev/null || true
    echo
    echo "--- MTProxy log ---"
    journalctl -u mtproxy -n 40 --no-pager 2>/dev/null || true
    echo
    echo "--- relay log ---"
    journalctl -u tproxy-server -n 40 --no-pager 2>/dev/null || true
    echo
    echo "--- site permissions ---"
    namei -l "$SITE_TARGET/index.html" 2>/dev/null || true
    echo
    echo "--- MTProxy permissions ---"
    namei -l /opt/MTProxy/objs/bin/mtproto-proxy 2>/dev/null || true
}

on_error() {
    local code=$?
    trap - ERR
    show_failure
    exit "$code"
}
trap on_error ERR

# --- парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain|--hostname) DOMAIN="$(trim "${2:-}")"; shift 2 ;;
        --email) EMAIL="$(trim "${2:-}")"; shift 2 ;;
        --secret) SECRET="$(trim "${2:-}")"; shift 2 ;;
        --workers) MT_WORKERS="${2:-1}"; shift 2 ;;
        --max-connections) MT_MAX_CONNECTIONS="${2:-4096}"; shift 2 ;;
        --site-dir) SITE_DIR="${2:-}"; shift 2 ;;
        --site-upstream) SITE_UPSTREAM="${2:-}"; shift 2 ;;
        --site-csp) SITE_CSP="${2:-}"; shift 2 ;;
        --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

clear 2>/dev/null || true

cat <<EOF
============================================================
   TELEGRAM WEB PROXY INSTALLER ${VERSION}
   Ubuntu 22.04+ / Debian 12+ / x86_64
============================================================

Автоматическая установка:
  Caddy (HTTPS) + tproxy-server relay + официальный MTProxy

Секрет генерируется автоматически (или передайте --secret).
============================================================
EOF

[[ $EUID -eq 0 ]] || die "Run this installer as root."
[[ "$(uname -m)" == "x86_64" ]] || die "x86_64 is required."

# --- проверка ОС: Ubuntu >= 22.04 или Debian >= 12 ---
. /etc/os-release
case "${ID:-}" in
    ubuntu)
        dpkg --compare-versions "${VERSION_ID:-0}" ge "22.04" ||
            die "Ubuntu 22.04 or newer is required (found ${VERSION_ID:-unknown})."
        ;;
    debian)
        dpkg --compare-versions "${VERSION_ID:-0}" ge "12" ||
            die "Debian 12 or newer is required (found ${VERSION_ID:-unknown})."
        ;;
    *)
        die "Only Ubuntu 22.04+ and Debian 12+ are supported (found ${ID:-unknown})."
        ;;
esac
echo "      ${ID} ${VERSION_ID} / x86_64"

# --- домен и email ---
[[ -n "$DOMAIN" ]] || die "Missing --domain (e.g. proxy.example.com)."
[[ -n "$EMAIL" ]] || die "Missing --email (ACME contact)."
DOMAIN="${DOMAIN,,}"
valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
valid_email "$EMAIL" || die "Invalid email: $EMAIL"
[[ "$MT_WORKERS" =~ ^[1-9][0-9]*$ ]] && (( MT_WORKERS <= 256 )) || die "workers must be 1..256"
[[ "$MT_MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || die "max-connections must be positive"
[[ -n "$SITE_DIR" && -n "$SITE_UPSTREAM" ]] && die "--site-dir and --site-upstream are mutually exclusive."

# --- секрет ---
if [[ -z "$SECRET" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends openssl >/dev/null
    SECRET="$(openssl rand -hex 16)"
    echo "      Secret generated automatically."
else
    SECRET="${SECRET,,}"
    valid_secret "$SECRET" || die "Secret must be 32 lowercase hex, optionally prefixed with dd."
fi
valid_secret "$SECRET" || die "Secret is invalid."

echo
echo "[1/10] Installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl nftables util-linux
# dnsutils (Debian) / bind9-dnsutils (новые Ubuntu) — оба имени
if ! command -v getent >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends dnsutils 2>/dev/null ||
        apt-get install -y --no-install-recommends bind9-dnsutils
fi
echo "      OK"

echo
echo "[2/10] Checking ports..."
check_install_port 80 caddy
check_install_port 443 caddy
check_install_port 2398 mtproto-proxy
check_install_port 8080 tproxy-server
check_install_port 8081 tproxy-server

EXISTING_CADDY_CONF="/etc/systemd/system/caddy.service.d/tproxy.conf"
EXISTING_DOMAIN=""
EXISTING_EMAIL=""
REUSE_EXISTING_HTTPS=0

if [[ "$REUSE_CADDY" == "1" && -f "$EXISTING_CADDY_CONF" ]]; then
    EXISTING_DOMAIN="$(sed -n 's/^Environment=TPROXY_HOSTNAME=//p' "$EXISTING_CADDY_CONF" | head -n1)"
    EXISTING_EMAIL="$(sed -n 's/^Environment=ACME_EMAIL=//p' "$EXISTING_CADDY_CONF" | head -n1)"

    if [[ -n "$EXISTING_DOMAIN" && "$EXISTING_DOMAIN" != "$DOMAIN" ]]; then
        die "Existing Web Proxy uses domain ${EXISTING_DOMAIN}. Use that domain or uninstall first."
    fi

    if [[ -n "$EXISTING_DOMAIN" ]] &&
        curl -fsSI --max-time 10 "https://${EXISTING_DOMAIN}/" >/dev/null 2>&1; then
        REUSE_EXISTING_HTTPS=1
        DOMAIN="$EXISTING_DOMAIN"
        [[ -n "$EXISTING_EMAIL" ]] && EMAIL="$EXISTING_EMAIL"
        echo "      Existing HTTPS already works; certificate/config will be reused."
    else
        echo "      Existing Caddy found, but HTTPS is not currently working."
        if [[ -n "$EXISTING_EMAIL" ]] && valid_email "$EXISTING_EMAIL"; then
            EMAIL="$EXISTING_EMAIL"
            echo "      Existing ACME email reused."
        fi
    fi
fi

echo
echo "[3/10] Opening firewall ports 80/443..."
open_http_ports

echo
echo "[4/10] Checking DNS..."
DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
[[ -n "$DNS_IP" ]] || die "No IPv4 A record found for $DOMAIN."

if [[ "$REUSE_EXISTING_HTTPS" == "1" ]]; then
    echo "      Existing HTTPS verified: $DOMAIN -> $DNS_IP"
elif [[ "$SKIP_DNS_CHECK" == "1" ]]; then
    echo "      DNS check skipped (--skip-dns-check): $DOMAIN -> $DNS_IP"
else
    VPS_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
    if [[ -n "$VPS_IP" && "$DNS_IP" != "$VPS_IP" ]]; then
        echo "      DNS: $DNS_IP"
        echo "      VPS: $VPS_IP"
        die "DNS does not point to this VPS. Use --skip-dns-check to override."
    fi
    echo "      $DOMAIN -> $DNS_IP"
fi

echo
echo "[5/10] Preparing public site..."
rm -rf "$SITE_INPUT"
mkdir -p "$SITE_INPUT"

if [[ -n "$SITE_DIR" ]]; then
    [[ -d "$SITE_DIR" ]] || die "Site directory does not exist: $SITE_DIR"
    [[ -r "$SITE_DIR/index.html" ]] || die "Site directory must contain a readable index.html."
    cp -a "$SITE_DIR/." "$SITE_INPUT/"
    echo "      Operator site copied from $SITE_DIR"
elif [[ -n "$SITE_UPSTREAM" ]]; then
    [[ "$SITE_UPSTREAM" =~ ^http://(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):[1-9][0-9]{0,4}$ ]] ||
        die "site-upstream must be http:// followed by a numeric loopback address and port."
    echo "      Using site upstream: $SITE_UPSTREAM"
else
    cat > "$SITE_INPUT/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Подключение</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         padding: 24px; background: #0a0d12; color: #f5f7fb;
         font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
  .card { width: min(100%, 480px); padding: 40px 28px; text-align: center;
          border: 1px solid #242c38; border-radius: 20px; background: #11161f; }
  h1 { margin: 0 0 10px; font-size: 26px; }
  p { color: #8f99a8; line-height: 1.6; }
  .bar { width: min(100%, 280px); height: 8px; margin: 26px auto 0; overflow: hidden;
         border-radius: 999px; background: #202733; }
  .bar::before { content: ""; display: block; width: 34%; height: 100%; background: #6ee7ff;
                 border-radius: inherit; animation: load 1.25s ease-in-out infinite; }
  @keyframes load { 0% { transform: translateX(-120%); }
                    50% { transform: translateX(190%); }
                    100% { transform: translateX(320%); } }
</style>
</head>
<body>
  <main class="card">
    <h1>Подключение</h1>
    <p>Пожалуйста, подождите.<br>Идёт установка защищённого соединения.</p>
    <div class="bar"></div>
  </main>
</body>
</html>
EOF
    echo "      Built-in placeholder site created."
fi

chmod 0755 "$SITE_INPUT"
chmod 0644 "$SITE_INPUT/index.html"

echo
echo "[6/10] Installing Web Proxy components..."

# --- исходники tproxy-server (официальные) ---
if [[ ! -d "$REPO_DIR/.git" ]]; then
    rm -rf "$REPO_DIR"
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
else
    echo "      Existing tproxy-server source tree detected; reusing it."
fi

# --- обнаружение уже установленных компонентов ---
if [[ -x /opt/MTProxy/objs/bin/mtproto-proxy ]] &&
    systemctl list-unit-files mtproxy.service >/dev/null 2>&1 &&
    port_has_expected_process 2398 mtproto-proxy; then
    REUSE_MT=1
    echo "      Existing MTProxy detected; reusing it."
fi

if [[ -x /usr/local/bin/tproxy-server ]] &&
    systemctl list-unit-files tproxy-server.service >/dev/null 2>&1 &&
    port_has_expected_process 8080 tproxy-server &&
    port_has_expected_process 8081 tproxy-server; then
    REUSE_RELAY=1
    echo "      Existing tproxy-server detected; reusing it."
fi

if [[ -x /usr/local/bin/caddy ]] &&
    systemctl list-unit-files caddy.service >/dev/null 2>&1 &&
    port_has_expected_process 80 caddy &&
    port_has_expected_process 443 caddy; then
    REUSE_CADDY=1
    echo "      Existing Caddy detected; reusing it."
fi

# --- Caddy (проверка контрольной суммы) ---
if [[ "$REUSE_CADDY" == "1" ]]; then
    echo "      Caddy already installed; reusing it."
else
    echo "      Installing Caddy..."
    caddy_version="2.11.4"
    caddy_sha512="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"

    caddy_archive="$(mktemp /tmp/caddy-linux-amd64.XXXXXX.tar.gz)"
    caddy_directory="$(mktemp -d /tmp/caddy-linux-amd64.XXXXXX)"

    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$caddy_archive" \
        "https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/caddy_${caddy_version}_linux_amd64.tar.gz"

    test "$(sha512sum "$caddy_archive" | awk '{print $1}')" = "$caddy_sha512" ||
        die "Caddy checksum verification failed."

    tar -C "$caddy_directory" -xzf "$caddy_archive"
    install -m 0755 "$caddy_directory/caddy" /usr/local/bin/caddy
    rm -f "$caddy_archive"
    rm -rf "$caddy_directory"

    if ! id caddy >/dev/null 2>&1; then
        useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
    fi
    install -d -o root -g caddy -m 0750 /etc/caddy
    install -d -o caddy -g caddy -m 0750 /var/lib/caddy
    install -d -o caddy -g caddy -m 0750 /etc/caddy/caddy
fi

# --- официальный MTProxy ---
echo "      Installing official MTProxy..."
if [[ "$REUSE_MT" != "1" ]]; then
    "$REPO_DIR/deploy/install-mtproxy.sh"
else
    echo "      MTProxy installation skipped; existing instance is already listening on :2398."
fi

if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
fi

fix_mtproxy_permissions() {
    chmod 0755 /opt/MTProxy
    chmod 0755 /opt/MTProxy/objs
    chmod 0755 /opt/MTProxy/objs/bin
    chmod 0755 /opt/MTProxy/objs/bin/mtproto-proxy
    runuser -u mtproxy -- test -x /opt/MTProxy/objs/bin/mtproto-proxy ||
        die "mtproxy user cannot execute mtproto-proxy."
}

# --- Go relay ---
echo "      Installing Go relay..."
go_binary=""
if command -v go >/dev/null 2>&1; then
    go_minor="$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "$go_minor" =~ ^[0-9]+$ ]] && [[ "$go_minor" -ge 20 ]]; then
        go_binary="$(command -v go)"
    fi
fi
if [[ -z "$go_binary" ]]; then
    go_version="1.26.5"
    go_sha256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
    if [[ -x "/opt/go${go_version}/bin/go" ]]; then
        go_binary="/opt/go${go_version}/bin/go"
    else
        go_archive="$(mktemp /tmp/go-linux-amd64.XXXXXX.tar.gz)"
        go_directory="$(mktemp -d /tmp/go-linux-amd64.XXXXXX)"

        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --output "$go_archive" \
            "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"

        test "$(sha256sum "$go_archive" | awk '{print $1}')" = "$go_sha256" ||
            die "Go checksum verification failed."

        tar -C "$go_directory" -xzf "$go_archive"
        mv "$go_directory/go" "/opt/go${go_version}"
        rm -f "$go_archive"
        rm -rf "$go_directory"
        go_binary="/opt/go${go_version}/bin/go"
    fi
fi

if [[ "$REUSE_RELAY" == "1" ]]; then
    echo "      Existing tproxy-server binary is already active; reusing it."
else
    echo "      Building relay..."
    (
        cd "$REPO_DIR"
        "$go_binary" build -trimpath -ldflags='-s -w' \
            -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
    )
    chown root:root /usr/local/bin/tproxy-server
    chmod 0755 /usr/local/bin/tproxy-server
fi

echo "      Preparing site..."
install -d -o root -g tproxy -m 0750 "$SITE_TARGET"
rm -rf "$SITE_TARGET"/*
cp -a "$SITE_INPUT/." "$SITE_TARGET/"
chown -R root:tproxy "$SITE_TARGET"
find "$SITE_TARGET" -type d -exec chmod 0750 {} +
find "$SITE_TARGET" -type f -exec chmod 0640 {} +

runuser -u tproxy -- test -x "$SITE_TARGET" ||
    die "tproxy user cannot traverse public site."
runuser -u tproxy -- test -r "$SITE_TARGET/index.html" ||
    die "tproxy user cannot read public site index.html."

echo "      Preparing configuration..."
install -d -o root -g tproxy -m 0750 /etc/tproxy-server

if [[ -n "$SITE_UPSTREAM" ]]; then
    public_source="  \"public_upstream\": \"$SITE_UPSTREAM\","
else
    public_source='  "public_dir": "/srv/tproxy-site",'
fi

if [[ -n "$SITE_CSP" ]]; then
    site_csp_line="  \"site_csp\": \"$SITE_CSP\","
else
    site_csp_line=""
fi

cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "$DOMAIN",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
$public_source
$site_csp_line
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF

cat > /etc/tproxy-server/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$SECRET","backend":"127.0.0.1:2398"}]}
EOF

chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
chmod 0640 /etc/tproxy-server/config.json
chmod 0400 /etc/tproxy-server/profiles.json

backend_secret="$SECRET"
if [[ "$backend_secret" == dd* ]] && [[ ${#backend_secret} -eq 34 ]]; then
    backend_secret="${backend_secret:2}"
fi

cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=$MT_WORKERS
MTPROXY_MAX_CONNECTIONS=$MT_MAX_CONNECTIONS
EOF

chown root:mtproxy /etc/mtproxy/mtproxy.env
chmod 0640 /etc/mtproxy/mtproxy.env

echo "      Installing service files..."
if [[ "$REUSE_CADDY" != "1" ]]; then
    install -m 0644 "$REPO_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile
    install -m 0644 "$REPO_DIR/deploy/caddy.service" /etc/systemd/system/caddy.service
else
    echo "      Preserving existing Caddyfile and Caddy service."
fi

install -d -m 0755 /etc/systemd/system/caddy.service.d
if [[ "$REUSE_EXISTING_HTTPS" == "1" ]]; then
    echo "      Preserving existing working Caddy environment."
else
    cat > /etc/systemd/system/caddy.service.d/tproxy.conf <<EOF
[Service]
Environment=TPROXY_HOSTNAME=$DOMAIN
Environment=TPROXY_SITE_ROOT=/srv/tproxy-site
Environment=ACME_EMAIL=$EMAIL
ReadWritePaths=/etc/caddy
EOF
fi

install -m 0644 "$REPO_DIR/deploy/tproxy-server.service" /etc/systemd/system/tproxy-server.service
install -m 0644 "$REPO_DIR/deploy/mtproxy.service" /etc/systemd/system/mtproxy.service
install -m 0644 "$REPO_DIR/deploy/tproxy-firewall.service" /etc/systemd/system/tproxy-firewall.service
install -m 0644 "$REPO_DIR/deploy/refresh-mtproxy-config.service" /etc/systemd/system/refresh-mtproxy-config.service
install -m 0644 "$REPO_DIR/deploy/refresh-mtproxy-config.timer" /etc/systemd/system/refresh-mtproxy-config.timer
install -m 0644 "$REPO_DIR/deploy/firewall.nft" /etc/tproxy-server/firewall.nft
install -m 0755 "$REPO_DIR/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config

echo "      Preflight validation..."
fix_mtproxy_permissions
runuser -u tproxy -- test -r "$SITE_TARGET/index.html" ||
    die "Public site is not readable by tproxy."

/usr/local/bin/tproxy-server \
    -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json \
    -check

TPROXY_HOSTNAME="$DOMAIN" \
TPROXY_SITE_ROOT=/srv/tproxy-site \
ACME_EMAIL="$EMAIL" \
/usr/local/bin/caddy validate \
    --config /etc/caddy/Caddyfile \
    --adapter caddyfile

systemctl daemon-reload

echo "      Starting firewall..."
systemctl enable --now tproxy-firewall.service

echo "      Starting MTProxy..."
fix_mtproxy_permissions
systemctl enable mtproxy.service
systemctl reset-failed mtproxy.service 2>/dev/null || true
systemctl restart mtproxy.service

MT_READY=0
for _ in $(seq 1 20); do
    if systemctl is-active --quiet mtproxy &&
        ss -lnt | grep -Eq ':(2398)\b'; then
        MT_READY=1
        break
    fi
    sleep 1
done
[[ "$MT_READY" == "1" ]] || die "MTProxy did not start on port 2398."
echo "      MTProxy :2398 OK"

echo "      Starting relay..."
runuser -u tproxy -- test -r "$SITE_TARGET/index.html" ||
    die "tproxy user cannot read site before relay start."

systemctl enable tproxy-server.service
systemctl reset-failed tproxy-server.service 2>/dev/null || true
systemctl restart tproxy-server.service

RELAY_READY=0
for _ in $(seq 1 30); do
    if systemctl is-active --quiet tproxy-server &&
        curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
        RELAY_READY=1
        break
    fi
    sleep 1
done

if [[ "$RELAY_READY" != "1" ]]; then
    echo "      Relay not ready; running automatic recovery..."
    fix_mtproxy_permissions
    chown -R root:tproxy "$SITE_TARGET"
    find "$SITE_TARGET" -type d -exec chmod 0750 {} +
    find "$SITE_TARGET" -type f -exec chmod 0640 {} +
    systemctl reset-failed mtproxy tproxy-server 2>/dev/null || true
    systemctl restart mtproxy.service
    sleep 2
    systemctl restart tproxy-server.service

    for _ in $(seq 1 20); do
        if systemctl is-active --quiet tproxy-server &&
            curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
            RELAY_READY=1
            break
        fi
        sleep 1
    done
fi

[[ "$RELAY_READY" == "1" ]] || die "tproxy-server did not become ready."
echo "      Relay /readyz OK"

echo "      Starting refresh timer..."
systemctl enable --now refresh-mtproxy-config.timer

echo "      Starting Caddy..."
systemctl enable caddy.service
systemctl restart caddy.service

echo
echo "[7/10] Running health checks..."
curl -fsS --max-time 5 http://127.0.0.1:8081/healthz >/dev/null ||
    die "tproxy-server healthz failed."
echo "      healthz OK"

HTTPS_READY=0
if [[ "$REUSE_EXISTING_HTTPS" == "1" ]]; then
    HTTPS_READY=1
    echo "      Existing HTTPS certificate/config already working."
else
    for _ in $(seq 1 90); do
        if curl -fsSI --max-time 5 "https://${DOMAIN}/" >/dev/null 2>&1; then
            HTTPS_READY=1
            break
        fi
        sleep 2
    done
fi

if [[ "$HTTPS_READY" != "1" ]]; then
    echo "      Caddy diagnostic:"
    journalctl -u caddy -n 60 --no-pager 2>/dev/null || true
    die "HTTPS did not become ready within 180 seconds. Check Caddy/ACME/DNS."
fi
echo "      HTTPS OK"

echo
echo "[8/10] Checking persistence and ports..."
for unit in mtproxy tproxy-server caddy; do
    systemctl is-active --quiet "$unit" || die "$unit is not active."
    systemctl is-enabled --quiet "$unit" || die "$unit is not enabled."
done
systemctl is-active --quiet tproxy-firewall || die "tproxy-firewall is not active."
systemctl is-enabled --quiet refresh-mtproxy-config.timer || die "refresh timer is not enabled."

runuser -u mtproxy -- test -x /opt/MTProxy/objs/bin/mtproto-proxy ||
    die "Final MTProxy permission check failed."
runuser -u tproxy -- test -r /srv/tproxy-site/index.html ||
    die "Final site permission check failed."

for p in 2398 8080 8081 80 443; do
    ss -lnt | grep -Eq ":(${p})\b" || die "Expected port ${p} is not listening."
done

echo "[9/10] Writing uninstall manifest..."
cat > "$MANIFEST" <<EOF
reused_caddy=$REUSE_CADDY
reused_mtproxy=$REUSE_MT
reused_relay=$REUSE_RELAY
firewall_backend=$FIREWALL_BACKEND
EOF
chmod 0600 "$MANIFEST"

echo "[10/10] Done."

TELEGRAM_SECRET="${SECRET#dd}"

echo
echo "============================================================"
echo "             TELEGRAM WEB PROXY IS READY"
echo "============================================================"
echo
echo "Domain:"
echo "  https://${DOMAIN}/"
echo
echo "Secret:"
echo "  ${SECRET}"
echo
echo "Telegram Web Proxy:"
echo "  https://t.me/webproxy?server=${DOMAIN}&secret=${TELEGRAM_SECRET}"
echo
echo "Status:"
echo "  HTTPS          OK"
echo "  MTProxy        ACTIVE"
echo "  Relay          READY"
echo "  Firewall       ACTIVE"
echo
echo "IMPORTANT: keep the secret private."
echo "Uninstall: sudo ./uninstall-twebproxy.sh"
echo "============================================================"
