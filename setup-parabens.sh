#!/usr/bin/env bash
# =============================================================================
#  setup-parabens.sh — instala tudo numa instância Amazon Linux 2023 e sobe o
#  site de parabéns do repo pablinrlq/pratica-site-instancia (só rodar).
#
#    Internet :80 ─► Nginx ─┬─► app Node em 127.0.0.1:3000       (APP_TYPE=node)
#                           └─► arquivos do build (Vite/React)   (APP_TYPE=static)
#
#  Uso (na instância, como ec2-user):
#    sudo bash setup-parabens.sh                        # instala tudo e sobe o site
#    sudo REPO_URL=https://github.com/usuario/api.git bash setup-parabens.sh
#    sudo REPO_URL=https://github.com/usuario/front.git APP_TYPE=static bash setup-parabens.sh
#
#  Idempotente: pode rodar de novo pra mudar a config ou reaplicar tudo.
#  Depois do setup, deploy novo é só: appctl deploy   (comandos: appctl help)
# =============================================================================
set -Eeuo pipefail

# ---------------------------------- CONFIG -----------------------------------
# Tudo pode vir por variável de ambiente: sudo APP_TYPE=static bash setup-parabens.sh
APP_NAME="${APP_NAME:-webapp}"       # nome do serviço, do usuário e das pastas
APP_TYPE="${APP_TYPE:-static}"       # node | static (aqui: site estático)
REPO_URL="${REPO_URL:-https://github.com/pablinrlq/pratica-site-instancia.git}"  # repo público do site de parabéns
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_PORT="${APP_PORT:-3000}"         # porta interna da app (só localhost, nunca exposta)
START_CMD="${START_CMD:-npm start}"  # como iniciar a app (modo node)
BUILD_DIR="${BUILD_DIR:-dist}"       # pasta gerada pelo build (modo static)
HEALTH_PATH="${HEALTH_PATH:-/}"      # rota testada depois de cada deploy
NODE_MAJOR="${NODE_MAJOR:-24}"       # 24 = LTS empacotado no AL2023 (recebe patch via dnf)
SERVER_NAME="${SERVER_NAME:-_}"      # seu domínio, ou "_" = qualquer host/IP
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
SWAP_MB="${SWAP_MB:-2048}"           # 0 = não cria swap
KEEP_RELEASES="${KEEP_RELEASES:-3}"  # releases antigos guardados pra rollback
# -----------------------------------------------------------------------------

APP_USER="$APP_NAME"
APP_HOME="/var/lib/$APP_NAME"
APP_DIR="/var/www/$APP_NAME"
ENV_FILE="/etc/$APP_NAME/app.env"
LOG_FILE="/var/log/$APP_NAME-setup.log"
DEPLOY_OK=1
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m  ✖ %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------- PRÉ-CHECAGENS -------------------------------
[[ $EUID -eq 0 ]] || die "Rode como root: sudo bash $0"
# shellcheck disable=SC1091,SC2154
[[ "$(. /etc/os-release && echo "$ID-$VERSION_ID")" == "amzn-2023" ]] || die "Esse script é pra Amazon Linux 2023."
[[ "$APP_TYPE" =~ ^(node|static)$ ]]        || die "APP_TYPE precisa ser node ou static."
[[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "APP_NAME inválido (minúsculas, números e hífen)."
[[ "$APP_PORT" =~ ^[0-9]+$ ]]               || die "APP_PORT precisa ser numérica."

exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc=$?
  printf '\033[0;31m✖ Falhou na linha %s (exit %s): %s\033[0m\n' "$1" "$rc" "$BASH_COMMAND" >&2
  exit "$rc"
}
trap 'on_error $LINENO' ERR
echo "Setup iniciado em $(date '+%F %T') — log completo em $LOG_FILE"

# ================================ 1. SISTEMA =================================
log "1/10 Atualizando o sistema e instalando pacotes"
# O AL2023 trava o repo na versão da AMI ("deterministic upgrades"). Apontar pra
# "latest" faz o dnf (e o dnf-automatic) enxergar os patches publicados depois.
install -d /etc/dnf/vars
echo latest > /etc/dnf/vars/releasever
dnf -y upgrade --refresh
dnf -y install git nginx jq tar gzip unzip gcc-c++ make dnf-plugins-core
dnf -y install --setopt=strict=0 nano htop || true   # opcionais
ok "Sistema atualizado"

# ============================== 2. AJUSTES DO SO =============================
log "2/10 Timezone, swap, kernel e logs"
timedatectl set-timezone "$TIMEZONE"

# Swap evita OOM no npm install/build em instância pequena (t3.micro etc.)
if (( SWAP_MB > 0 )) && [[ -z "$(swapon --show --noheadings)" ]]; then
  dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
  ok "Swap de ${SWAP_MB}MB ativa"
fi

cat > /etc/sysctl.d/90-webserver.conf <<'SYSCTL'
vm.swappiness = 10
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
SYSCTL
sysctl -q -p /etc/sysctl.d/90-webserver.conf

# Limita o journal pra não lotar o disco (EBS padrão é 8 GB)
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-limits.conf <<'JOURNAL'
[Journal]
SystemMaxUse=500M
MaxRetentionSec=1month
JOURNAL
systemctl restart systemd-journald
ok "Timezone $TIMEZONE, sysctl e limite do journal aplicados"

# ===================== 3. PATCHES DE SEGURANÇA AUTOMÁTICOS ===================
log "3/10 Updates de segurança automáticos"
if dnf -y install dnf-automatic; then
  sed -i -E 's/^\s*upgrade_type\s*=.*/upgrade_type = security/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic-install.timer
  ok "dnf-automatic instalando updates de segurança todo dia"
else
  warn "dnf-automatic indisponível — pulei essa etapa"
fi

# ============================== 4. HARDENING SSH =============================
log "4/10 Hardening do SSH"
# Prefixo 01- porque no sshd vale o PRIMEIRO valor lido entre os drop-ins
SSHD_DROPIN=/etc/ssh/sshd_config.d/01-hardening.conf
cat > "$SSHD_DROPIN" <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD
if sshd -t; then
  systemctl reload sshd
  ok "SSH só por chave e sem login de root"
else
  rm -f "$SSHD_DROPIN"
  warn "sshd recusou a config — mantive o padrão da AMI"
fi

# ================================= 5. NODE.JS ================================
log "5/10 Node.js ${NODE_MAJOR}"

install_node_tarball() {   # fallback: binário oficial do nodejs.org, SHA256 conferido
  local arch tmp tarball base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
  case "$(uname -m)" in
    x86_64)  arch=x64 ;;
    aarch64) arch=arm64 ;;
    *) die "Arquitetura não suportada: $(uname -m)" ;;
  esac
  tmp=$(mktemp -d)
  curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  tarball=$(grep -m1 -oE "node-v[0-9.]+-linux-${arch}\.tar\.gz" "$tmp/SHASUMS256.txt") \
    || die "Node ${NODE_MAJOR} não encontrado em nodejs.org"
  curl -fsSL "$base/$tarball" -o "$tmp/$tarball"
  (cd "$tmp" && grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c --quiet -) \
    || die "SHA256 do Node não confere — abortando"
  tar -xzf "$tmp/$tarball" -C /opt --no-same-owner
  ln -sfn "/opt/${tarball%.tar.gz}" /opt/nodejs
  for bin in node npm npx; do ln -sfn "/opt/nodejs/bin/$bin" "/usr/local/bin/$bin"; done
  rm -rf "$tmp"
}

if dnf -q list "nodejs${NODE_MAJOR}" &>/dev/null; then
  dnf -y install "nodejs${NODE_MAJOR}" "nodejs${NODE_MAJOR}-npm"
  alternatives --set node "/usr/bin/node-${NODE_MAJOR}" 2>/dev/null || true
else
  warn "nodejs${NODE_MAJOR} não está no repo do AL2023 — usando o binário oficial do nodejs.org"
  install_node_tarball
fi
hash -r
NODE_VERSION=$(node -v) || die "node não ficou disponível no PATH"
NPM_VERSION=$(npm -v)   || die "npm não ficou disponível no PATH"
ok "Node $NODE_VERSION / npm $NPM_VERSION"

# ========================== 6. USUÁRIO E DIRETÓRIOS ==========================
log "6/10 Usuário e diretórios da app"
id -u "$APP_USER" &>/dev/null || useradd --system --create-home --home-dir "$APP_HOME" --shell /sbin/nologin "$APP_USER"
install -d -m 755 -o "$APP_USER" -g "$APP_USER" "$APP_DIR" "$APP_DIR/releases"
install -d -m 750 -o root -g "$APP_USER" "/etc/$APP_NAME"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<ENVFILE
# Variáveis da app — formato KEY=valor (sem "export"). Editar: appctl env
NODE_ENV=production
PORT=$APP_PORT
HOST=127.0.0.1
# DATABASE_URL=
# VITE_SUPABASE_URL=
ENVFILE
fi
chown root:"$APP_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok "Usuário '$APP_USER' (sem shell), código em $APP_DIR, variáveis em $ENV_FILE"

# =========================== 7. APPCTL (DEPLOY) ==============================
log "7/10 Ferramenta de deploy (appctl)"
{
  echo "# Gerado por setup-parabens.sh"
  for v in APP_NAME APP_TYPE APP_USER APP_HOME APP_DIR ENV_FILE REPO_URL REPO_BRANCH \
           APP_PORT BUILD_DIR HEALTH_PATH KEEP_RELEASES; do
    printf '%s=%q\n' "$v" "${!v}"
  done
} > /etc/appctl.conf
chmod 600 /etc/appctl.conf   # pode conter token do repo

cat > /usr/local/bin/appctl <<'APPCTL'
#!/usr/bin/env bash
# appctl — deploy, rollback e status da app (gerado pelo setup-parabens.sh)
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo -- "$(readlink -f "$0")" "$@"
# shellcheck source=/dev/null
source /etc/appctl.conf
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
RELEASES="$APP_DIR/releases"
CURRENT="$APP_DIR/current"

# Roda um script como o usuário da app, com ambiente limpo (npm nunca roda como root)
as_app() {
  local script=$1; shift
  runuser -u "$APP_USER" -- env -i HOME="$APP_HOME" PATH="$PATH" LANG=C.UTF-8 \
    GIT_TERMINAL_PROMPT=0 HUSKY=0 NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false \
    bash -c "umask 022; set -Eeuo pipefail; $script" _ "$@"
}

switch_to() {   # troca o symlink "current" de forma atômica
  ln -sfn "$1" "$APP_DIR/.current.tmp"
  mv -Tf "$APP_DIR/.current.tmp" "$CURRENT"
}

restart_app() {
  if [[ "$APP_TYPE" == node ]]; then systemctl restart "$APP_NAME"
  else systemctl reload-or-restart nginx; fi
}

lock() {   # impede dois deploys/rollbacks ao mesmo tempo (ex.: duas sessões SSH)
  exec 9>/run/appctl.lock
  flock -n 9 || { echo "✖ Já existe um deploy/rollback em andamento." >&2; exit 1; }
}

healthy() {
  local url="http://127.0.0.1${HEALTH_PATH}" code
  if [[ "$APP_TYPE" == node ]]; then url="http://127.0.0.1:${APP_PORT}${HEALTH_PATH}"; fi
  code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 \
              --retry 60 --retry-delay 1 --retry-connrefused "$url") || true
  [[ "$code" =~ ^[234][0-9][0-9]$ ]]
}

write_sample() {   # app de exemplo, usada quando não há REPO_URL
  local dir=$1
  if [[ "$APP_TYPE" == node ]]; then
    cat > "$dir/package.json" <<'JSON'
{ "name": "sample-app", "private": true, "scripts": { "start": "node server.js" } }
JSON
    cat > "$dir/server.js" <<'JS'
const http = require('node:http');
const port = Number(process.env.PORT) || 3000;
const host = process.env.HOST || '127.0.0.1';
http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(`<h1>Servidor pronto ✅</h1><p>Node ${process.version} rodando atrás do Nginx.</p>`);
}).listen(port, host, () => console.log(`ouvindo em http://${host}:${port}`));
JS
  else
    mkdir -p "$dir/$BUILD_DIR"
    cat > "$dir/$BUILD_DIR/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Servidor pronto</title>
<h1>Servidor pronto ✅</h1><p>Nginx servindo o build estático.</p>
HTML
  fi
  chown -R "$APP_USER:$APP_USER" "$dir"
}

cleanup_releases() {   # mantém os últimos KEEP_RELEASES (nunca apaga o atual)
  local cur; cur=$(readlink -f "$CURRENT")
  find "$RELEASES" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +"$((KEEP_RELEASES + 1))" |
    while read -r dir; do [[ "$dir" == "$cur" ]] || rm -rf -- "$dir"; done
}

cmd_deploy() {
  local branch="${1:-$REPO_BRANCH}" rel prev=""
  lock
  rel="$RELEASES/$(date +%Y%m%d-%H%M%S)"
  while [[ -e "$rel" ]]; do sleep 1; rel="$RELEASES/$(date +%Y%m%d-%H%M%S)"; done
  if [[ -L "$CURRENT" ]]; then prev=$(readlink -f "$CURRENT"); fi
  # Qualquer falha antes da troca descarta o release: o que está no ar não muda
  trap 'rm -rf -- "$rel"; echo "✖ Deploy abortado — produção continua no release anterior." >&2' ERR

  if [[ -n "$REPO_URL" ]]; then
    echo "==> Clonando ${REPO_URL##*@} (branch $branch)"
    # shellcheck disable=SC2016  # $1..$3 expandem dentro do bash -c do as_app
    as_app 'git clone --quiet --depth 1 --branch "$2" -- "$1" "$3"' "$REPO_URL" "$branch" "$rel"
  else
    echo "==> Sem REPO_URL: publicando a app de exemplo"
    install -d -o "$APP_USER" -g "$APP_USER" "$rel"
    write_sample "$rel"
  fi

  echo "==> Instalando dependências e buildando ($(basename "$rel"))"
  # shellcheck disable=SC2016  # $1/$2 expandem dentro do bash -c do as_app
  as_app '
    cd "$1"
    if [ -r "$2" ]; then set -a; . "$2"; set +a; fi   # vars disponíveis no build (VITE_* etc.)
    if [ -f package-lock.json ]; then npm ci --include=dev
    elif [ -f package.json ]; then npm install --include=dev; fi
    if [ -f package.json ]; then npm run build --if-present; fi
    if [ -d .git ]; then git rev-parse --short HEAD > REVISION; rm -rf .git; fi
  ' "$rel" "$ENV_FILE"

  if [[ "$APP_TYPE" == static && ! -f "$rel/$BUILD_DIR/index.html" ]]; then
    echo "✖ $BUILD_DIR/index.html não existe depois do build (confira BUILD_DIR)" >&2
    false
  fi
  trap - ERR

  switch_to "$rel"
  restart_app
  if ! healthy; then
    echo "✖ Health check falhou em ${HEALTH_PATH}" >&2
    if [[ "$APP_TYPE" == node ]]; then journalctl -u "$APP_NAME" -n 30 --no-pager >&2 || true; fi
    if [[ -n "$prev" && -d "$prev" ]]; then
      switch_to "$prev"; restart_app; rm -rf -- "$rel"
      echo "↩ Rollback automático para $(basename "$prev")" >&2
    fi
    exit 1
  fi
  cleanup_releases
  echo "✔ No ar: $(basename "$rel") $(cat "$rel/REVISION" 2>/dev/null || true)"
}

cmd_rollback() {
  local cur prev
  lock
  cur=$(readlink -f "$CURRENT")
  prev=$(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d | sort |
         awk -v c="$cur" '$0 == c { print p } { p = $0 }')
  [[ -n "$prev" ]] || { echo "Não existe release anterior pra voltar." >&2; exit 1; }
  switch_to "$prev"
  restart_app
  echo "↩ Rollback: $(basename "$cur") → $(basename "$prev")"
}

cmd_status() {
  echo "App ......... $APP_NAME ($APP_TYPE)"
  echo "No ar ....... $(basename "$(readlink -f "$CURRENT")") $(cat "$CURRENT/REVISION" 2>/dev/null || true)"
  echo "Releases .... $(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | paste -sd' ')"
  echo
  systemctl --no-pager --lines=0 status nginx || true
  if [[ "$APP_TYPE" == node ]]; then systemctl --no-pager --lines=10 status "$APP_NAME" || true; fi
}

cmd_logs() {
  if [[ "$APP_TYPE" == node ]]; then journalctl -u "$APP_NAME" -n 100 -f
  else tail -n 100 -F /var/log/nginx/access.log /var/log/nginx/error.log; fi
}

cmd_env() {
  "$(command -v nano || command -v vi)" "$ENV_FILE"
  echo "Pra aplicar: 'appctl restart' (vars de runtime) ou 'appctl deploy' (vars de build, ex.: VITE_*)."
}

usage() {
  cat <<'USAGE'
Uso: appctl <comando>
  deploy [branch]  clona, builda e publica um release novo (rollback automático se falhar)
  rollback         volta pro release anterior
  restart          reinicia a app
  status           release no ar e status dos serviços
  logs             acompanha os logs em tempo real
  env              edita as variáveis de ambiente da app
USAGE
}

case "${1:-help}" in
  deploy)   shift; cmd_deploy "$@" ;;
  rollback) cmd_rollback ;;
  restart)  restart_app && echo "✔ Reiniciado" ;;
  status)   cmd_status ;;
  logs)     cmd_logs ;;
  env)      cmd_env ;;
  *)        usage ;;
esac
APPCTL
chmod 755 /usr/local/bin/appctl
ok "appctl instalado (deploy / rollback / status / logs / env)"

# ============================ 8. SERVIÇO SYSTEMD =============================
log "8/10 Serviço systemd"
UNIT_FILE="/etc/systemd/system/$APP_NAME.service"
if [[ "$APP_TYPE" == node ]]; then
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=$APP_NAME (Node.js)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR/current
EnvironmentFile=$ENV_FILE
Environment=PATH=/usr/local/bin:/usr/bin
ExecStart=/usr/bin/bash -c 'exec $START_CMD'
Restart=always
RestartSec=3
TimeoutStopSec=20
LimitNOFILE=65535

# Sandbox: a app só enxerga e escreve o que precisa
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --quiet "$APP_NAME"
  ok "Serviço $APP_NAME.service (sobe no boot, reinicia se cair)"
else
  if [[ -f "$UNIT_FILE" ]]; then
    systemctl disable --now --quiet "$APP_NAME" || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
  fi
  ok "Modo static: o Nginx serve os arquivos direto, sem processo Node"
fi

# ================================= 9. NGINX ==================================
log "9/10 Nginx na porta 80"
[[ -f /etc/nginx/nginx.conf.orig ]] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig

cat > /etc/nginx/nginx.conf <<'NGINX_MAIN'
# Gerado por setup-parabens.sh — original em /etc/nginx/nginx.conf.orig
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 4096;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
                    'rt=$request_time urt=$upstream_response_time';
    access_log /var/log/nginx/access.log main;

    sendfile             on;
    tcp_nopush           on;
    keepalive_timeout    65;
    types_hash_max_size  4096;
    server_tokens        off;
    client_max_body_size 25m;

    gzip            on;
    gzip_vary       on;
    gzip_proxied    any;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/xml application/rss+xml image/svg+xml;

    # IP real do cliente se um dia a instância ficar atrás de um ALB (tráfego da VPC)
    set_real_ip_from  10.0.0.0/8;
    set_real_ip_from  172.16.0.0/12;
    set_real_ip_from  192.168.0.0/16;
    real_ip_header    X-Forwarded-For;
    real_ip_recursive on;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_MAIN

install -d /etc/nginx/snippets
cat > /etc/nginx/snippets/security-headers.conf <<'HEADERS'
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
HEADERS

SITE_CONF="/etc/nginx/conf.d/$APP_NAME.conf"
if [[ "$APP_TYPE" == node ]]; then
  cat > "$SITE_CONF" <<'SITE_NODE'
upstream app_backend {
    server 127.0.0.1:__APP_PORT__;
    keepalive 32;
}

# WebSocket + keepalive com o upstream
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}

# Respeita o protocolo original quando vier de um ALB com HTTPS
map $http_x_forwarded_proto $forwarded_proto {
    default $http_x_forwarded_proto;
    ''      $scheme;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name __SERVER_NAME__;

    include /etc/nginx/snippets/security-headers.conf;

    location = /nginx-health {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    # Bloqueia .env, .git e afins (libera .well-known)
    location ~ /\.(?!well-known) {
        deny all;
    }

    location / {
        proxy_pass http://app_backend;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $forwarded_proto;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_connect_timeout 5s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }
}
SITE_NODE
else
  cat > "$SITE_CONF" <<'SITE_STATIC'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name __SERVER_NAME__;

    root  __WEB_ROOT__;
    index index.html;

    include /etc/nginx/snippets/security-headers.conf;

    location = /nginx-health {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    # Bloqueia .env, .git e afins (libera .well-known)
    location ~ /\.(?!well-known) {
        deny all;
    }

    # Arquivos com hash do Vite: cache de 1 ano
    location /assets/ {
        try_files $uri =404;
        add_header Cache-Control "public, max-age=31536000, immutable";
        include /etc/nginx/snippets/security-headers.conf;
    }

    # SPA: qualquer rota desconhecida cai no index.html
    location / {
        try_files $uri $uri/ /index.html;
    }

    location = /index.html {
        add_header Cache-Control "no-cache";
        include /etc/nginx/snippets/security-headers.conf;
    }
}
SITE_STATIC
fi
sed -i -e "s|__APP_PORT__|$APP_PORT|g" \
       -e "s|__SERVER_NAME__|$SERVER_NAME|g" \
       -e "s|__WEB_ROOT__|$APP_DIR/current/$BUILD_DIR|g" "$SITE_CONF"
# Kernel sem IPv6 (ex.: AMI hardened com ipv6.disable=1): tira o listen [::]
[[ -e /proc/net/if_inet6 ]] || sed -i '/listen \[::\]:80/d' "$SITE_CONF"

# SELinux vem permissive no AL2023; isso deixa tudo certo se um dia virar enforcing
if command -v selinuxenabled &>/dev/null && selinuxenabled; then
  setsebool -P httpd_can_network_connect 1
  restorecon -R /var/www
fi

nginx -t
systemctl enable --now --quiet nginx
systemctl reload nginx
ok "Nginx ativo ($(nginx -v 2>&1 | cut -d/ -f2))"

# ================================ 10. DEPLOY =================================
log "10/10 Deploy"
/usr/local/bin/appctl deploy || DEPLOY_OK=0

# ================================== RESUMO ===================================
imds() {   # metadata da instância via IMDSv2
  local token
  token=$(curl -s --noproxy '*' -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
          --max-time 2 http://169.254.169.254/latest/api/token) || return 1
  curl -sf --noproxy '*' -H "X-aws-ec2-metadata-token: $token" --max-time 2 \
       "http://169.254.169.254/latest/meta-data/$1"
}
HOST_IP=$(imds public-ipv4 || imds local-ipv4 || echo "IP-DA-INSTANCIA")
HTTP_CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/) || true

printf '\n\033[1;32m%s\033[0m\n' "════════════════════════ PRONTO ════════════════════════"
cat <<SUMMARY
  Acesse ........ http://$HOST_IP/   (teste local na porta 80: HTTP $HTTP_CODE)
  App ........... $APP_NAME ($APP_TYPE) → $APP_DIR/current
  Node / Nginx .. $NODE_VERSION / $(nginx -v 2>&1 | cut -d/ -f2)
  Variáveis ..... $ENV_FILE   (editar: appctl env)
  Log do setup .. $LOG_FILE

  appctl deploy [branch]   novo deploy (rollback automático se falhar)
  appctl rollback          volta pro release anterior
  appctl status | logs | restart | env
SUMMARY
if (( ! DEPLOY_OK )); then
  warn "O deploy falhou (o ambiente está pronto) — veja o erro acima, corrija e rode: appctl deploy"
fi
if ! dnf -q needs-restarting -r &>/dev/null; then
  warn "Kernel/bibliotecas atualizados: rode 'sudo reboot' quando puder (tudo sobe sozinho)."
fi
