#!/usr/bin/env bash
#
# install-server.sh — ai-memory na VPS (Ubuntu) + Cloudflare Tunnel + hardening.
#
# Distribuição:
#   curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-server.sh | bash
#
# Idempotente: rodar de novo não quebra (checa existência antes de instalar/gravar).
# Hardening seguro: gera chave, adiciona ao authorized_keys, TESTA login por chave
# e SÓ DEPOIS desliga senha. Se o teste falhar, não desliga senha (evita lockout).
#
# Flags:
#   --yes       não-interativo (usa variáveis de ambiente já definidas)
#   --dry-run   imprime o plano de ações sem executar nada
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/akitaonrails/ai-memory.git"
APP_DIR="/opt/ai-memory"
ENV_FILE="${APP_DIR}/docker/.env.production"
COMPOSE_FILE="${APP_DIR}/docker/compose.tls.cloudflared.yml"
WRAPPER_URL="https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-wrapper"
TOKEN_FILE="/root/.ai-memory-token"

DRY_RUN=0
ASSUME_YES=0
HARDEN=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  # ask <prompt> <default> -> echoes answer
  local prompt="$1" default="$2" ans
  if [ "$ASSUME_YES" = 1 ]; then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "$(printf '\033[1;36m[?]\033[0m %s [%s]: ' "$prompt" "$default")" ans
  printf '%s\n' "${ans:-$default}"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (sudo)"

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      ubuntu|debian) : ;;
      *) warn "OS '$ID' não é Ubuntu/Debian — script testado em Ubuntu 22.04/24.04." ;;
    esac
  fi

  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
  curl -fsSL -o /dev/null https://github.com >/dev/null 2>&1 || die "sem acesso à internet"
}

detect_state() {
  log "Estado detectado:"
  printf '  %-28s %s\n' "docker:"      "$(command -v docker     >/dev/null 2>&1 && echo instalado || echo ausente)"
  printf '  %-28s %s\n' "cloudflared:" "$(command -v cloudflared >/dev/null 2>&1 && echo instalado || echo ausente)"
  printf '  %-28s %s\n' "wrapper ai-memory:" "$(command -v ai-memory >/dev/null 2>&1 && echo instalado || echo ausente)"
  printf '  %-28s %s\n' "repo clonado:" "$([ -d "$APP_DIR/.git" ] && echo sim || echo nao)"
  printf '  %-28s %s\n' "chave ed25519:" "$([ -f "$HOME/.ssh/id_ed25519" ] && echo existe || echo ausente)"
  printf '  %-28s %s\n' "token gerado:" "$([ -f "$TOKEN_FILE" ] && echo existe || echo ausente)"
  echo
}

print_plan() {
  log "Plano de ações (dry-run):"
  cat <<'EOF'
  1. Instalar Docker (get.docker.com)          [pula se já existe]
  2. Instalar cloudflared (pkg.cloudflare.com) [pula se já existe]
  3. Instalar wrapper ai-memory -> /usr/local/bin
  4. Clonar/atualizar repo em /opt/ai-memory
  5. Gerar token de auth -> /root/.ai-memory-token (600)
  6. Escrever docker/.env.production (token, allowed hosts, tunnel token)
  7. docker compose -f compose.tls.cloudflared.yml up -d (projeto ai-memory-cloudflared)
  8. (hardening) gerar chave -> authorized_keys -> TESTAR login por chave
  9. (hardening) drop-in 00-hardening.conf -> senha off -> reload ssh
 10. (hardening) UFW (deny in, allow 22) + fail2ban (jail sshd)
 11. Imprimir resumo: URL, token, comando do client
EOF
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
prompt_inputs() {
  HOSTNAME_VAL="$(ask 'hostname do túnel (ex: memory.seualuno.com)' "${AI_MEMORY_HOSTNAME:-}")"
  TUNNEL_TOKEN="$(ask 'Cloudflare Tunnel token (remote-managed, do dashboard)' "${CLOUDFLARE_TUNNEL_TOKEN:-}")"
  [ -n "$HOSTNAME_VAL" ] || die "hostname vazio"
  [ -n "$TUNNEL_TOKEN" ] || die "tunnel token vazio"

  local h
  h="$(ask 'aplicar hardening (chave SSH + senha off + UFW + fail2ban)? [s/N]' 's')"
  case "$h" in s|S|sim|yes|y|1) HARDEN=1 ;; *) HARDEN=0 ;; esac
}

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then log "docker já instalado"; return; fi
  log "instalando Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then log "cloudflared já instalado"; return; fi
  log "instalando cloudflared..."
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y -qq cloudflared
}

install_wrapper() {
  if command -v ai-memory >/dev/null 2>&1; then log "wrapper ai-memory já instalado"; return; fi
  log "instalando wrapper ai-memory..."
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$WRAPPER_URL" -o "$tmp/ai-memory-wrapper"
  install -m 0755 "$tmp/ai-memory-wrapper" /usr/local/bin/ai-memory
  rm -rf "$tmp"
}

clone_repo() {
  if [ -d "$APP_DIR/.git" ]; then
    log "repo já existe, atualizando..."
    git -C "$APP_DIR" pull --ff-only || warn "git pull falhou (continua com versão atual)"
  else
    log "clonando ai-memory..."
    mkdir -p "$(dirname "$APP_DIR")"
    git clone --depth 1 "$REPO_URL" "$APP_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Token + env
# ---------------------------------------------------------------------------
generate_token() {
  if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
    log "token já existe em $TOKEN_FILE (reutilizando)"
    TOKEN="$(cat "$TOKEN_FILE")"
    return
  fi
  log "gerando token de auth..."
  TOKEN="$(ai-memory generate-auth-token)"
  printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
}

write_env() {
  log "escrevendo $ENV_FILE ..."
  cat > "$ENV_FILE" <<EOF
# Gerado por install-server.sh — não commitar.
AI_MEMORY_AUTH_TOKEN=${TOKEN}
AI_MEMORY_ALLOWED_HOSTS=${HOSTNAME_VAL},localhost,127.0.0.1
CLOUDFLARE_TUNNEL_TOKEN=${TUNNEL_TOKEN}
EOF
  chmod 600 "$ENV_FILE"
}

compose_up() {
  log "subindo stack (projeto ai-memory-cloudflared)..."
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
}

verify_local() {
  log "aguardando healthcheck..."
  for _ in $(seq 1 20); do
    if docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps 2>/dev/null | grep -q 'healthy'; then
      log "container ai-memory saudável."
      return
    fi
    sleep 5
  done
  warn "healthcheck não passou em 100s — veja: docker compose -f $COMPOSE_FILE logs"
}

# ---------------------------------------------------------------------------
# Hardening
# ---------------------------------------------------------------------------
harden_ssh() {
  log "hardening SSH..."
  if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "ai-memory-installer" -q
  fi
  local pub
  pub="$(cat "$HOME/.ssh/id_ed25519.pub")"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 700 "$HOME/.ssh"
  chmod 600 "$HOME/.ssh/authorized_keys"
  grep -qxF "$pub" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$pub" >> "$HOME/.ssh/authorized_keys"

  log "testando login por chave ANTES de desligar senha..."
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 -i "$HOME/.ssh/id_ed25519" root@127.0.0.1 true 2>/dev/null; then
    log "login por chave OK."
  else
    warn "login por chave FALHOU — NÃO vou desligar senha (evita lockout)."
    warn "Verifique sua chave e rode o hardening manualmente."
    return
  fi

  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
EOF
  sshd -t && systemctl reload ssh
  log "senha off, root key-only."
}

harden_firewall() {
  log "UFW + fail2ban..."
  apt-get install -y -qq ufw fail2ban
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp
  ufw --force enable >/dev/null

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
summary() {
  cat <<EOF

============================================================
  ai-memory instalado.
============================================================
  URL web:     https://${HOSTNAME_VAL}/web
  MCP:         https://${HOSTNAME_VAL}/mcp
  Token:       ${TOKEN}

  Ação manual no dashboard Cloudflare (Zero Trust):
    Public hostname -> ${HOSTNAME_VAL}  service -> http://ai-memory:49374

  Na máquina do aluno:
    curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-client.sh | bash
    (ou instale o wrapper e rode: ai-memory install-mcp/install-hooks)

  Ver status:   docker compose -f ${COMPOSE_FILE} logs
============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes)     ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      *) die "flag desconhecida: $1" ;;
    esac
    shift
  done

  preflight

  if [ "$DRY_RUN" = 1 ]; then
    detect_state
    print_plan
    exit 0
  fi

  prompt_inputs
  install_docker
  install_cloudflared
  install_wrapper
  clone_repo
  generate_token
  write_env
  compose_up
  verify_local
  if [ "$HARDEN" = 1 ]; then
    harden_ssh
    harden_firewall
  else
    warn "hardening pulado (você escolheu N)."
  fi
  summary
}

main "$@"
