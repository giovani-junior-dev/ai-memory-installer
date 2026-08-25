#!/usr/bin/env bash
#
# repoint-to-remote.sh — reaponta uma máquina que JÁ tem ai-memory local
# (Docker Desktop ou só o wrapper) para um servidor ai-memory remoto.
#
# Distribuição:
#   curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/repoint-to-remote.sh | bash
#
# Faz:
#   1. Detecta estado: wrapper, clone local do repo Akita, container Docker local
#   2. Atualiza o wrapper para o último release
#   3. Atualiza o clone local do repo Akita (git pull --ff-only), se existir
#   4. Pede URL + token do servidor remoto
#   5. Reaponta cada agente (install-mcp + install-hooks) para o remoto
#   6. Oferece parar o container Docker local (--stop-local)
#
# Flags:
#   --yes              não-interativo (usa env vars AI_MEMORY_SERVER_URL/AI_MEMORY_AUTH_TOKEN/AGENTS)
#   --agents a,b,c     lista de agentes (ex: claude-code,grok,codex)
#   --stop-local       para o container ai-memory local, se estiver rodando
#   --dry-run          imprime o plano sem executar
#
set -euo pipefail

WRAPPER_URL="https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-wrapper"
BIN_DIR="$HOME/.local/bin"

DRY_RUN=0
ASSUME_YES=0
STOP_LOCAL=0
AGENTS="${AGENTS:-}"

log()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  local prompt="$1" default="$2" ans
  if [ "$ASSUME_YES" = 1 ]; then printf '%s\n' "$default"; return; fi
  read -r -p "$(printf '\033[1;36m[?]\033[0m %s [%s]: ' "$prompt" "$default")" ans
  printf '%s\n' "${ans:-$default}"
}

# ---------------------------------------------------------------------------
# Detecção de estado
# ---------------------------------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Linux|Darwin)   : ;;
    MINGW*|MSYS*|CYGWIN*) warn "Git Bash no Windows: script parcial — use WSL ou Linux/macOS para o wrapper." ;;
    *) warn "OS não reconhecido: $(uname -s)" ;;
  esac
}

detect_wrapper() {
  command -v ai-memory >/dev/null 2>&1 && echo "$(command -v ai-memory)" || echo ""
}

detect_repo() {
  local d
  for d in \
    "$HOME/ai-memory" \
    "$HOME/src/ai-memory" \
    "$HOME/repos/ai-memory" \
    "$HOME/akitaonrails/ai-memory" \
    "/opt/ai-memory"; do
    [ -d "$d/.git" ] && { echo "$d"; return; }
  done
  echo ""
}

detect_docker_running() {
  command -v docker >/dev/null 2>&1 || return 1
  [ -n "$(docker ps -q --filter name=ai-memory 2>/dev/null | head -1)" ]
}

print_state() {
  log "Estado detectado:"
  printf '  %-24s %s\n' "wrapper:" "$([ -n "$WRAPPER_PATH" ] && echo "$WRAPPER_PATH" || echo ausente)"
  printf '  %-24s %s\n' "repo local:" "$([ -n "$REPO_PATH" ] && echo "$REPO_PATH" || echo 'não achado')"
  printf '  %-24s %s\n' "docker local:" "$(detect_docker_running && echo rodando || echo parado/ausente)"
  echo
}

# ---------------------------------------------------------------------------
# Atualização
# ---------------------------------------------------------------------------
update_wrapper() {
  log "atualizando wrapper ai-memory..."
  local tmp
  tmp="$(mktemp -d)"
  if ! curl -fsSL "$WRAPPER_URL" -o "$tmp/ai-memory-wrapper"; then
    warn "falha ao baixar wrapper — continua com o instalado."
    rm -rf "$tmp"
    return
  fi
  if [ -n "$WRAPPER_PATH" ] && [ -w "$WRAPPER_PATH" ]; then
    install -m 0755 "$tmp/ai-memory-wrapper" "$WRAPPER_PATH"
    log "wrapper atualizado em $WRAPPER_PATH"
  else
    mkdir -p "$BIN_DIR"
    install -m 0755 "$tmp/ai-memory-wrapper" "$BIN_DIR/ai-memory"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) export PATH="$BIN_DIR:$PATH" ;; esac
    log "wrapper instalado em $BIN_DIR/ai-memory"
  fi
  rm -rf "$tmp"
}

update_repo() {
  [ -n "$REPO_PATH" ] || { log "sem clone local do repo Akita — pulando atualização."; return; }
  log "atualizando repo Akita em $REPO_PATH ..."
  git -C "$REPO_PATH" pull --ff-only || warn "git pull falhou (continua com versão local)"
}

# ---------------------------------------------------------------------------
# Reapontar
# ---------------------------------------------------------------------------
repoint() {
  export AI_MEMORY_SERVER_URL="$SERVER_URL"
  export AI_MEMORY_AUTH_TOKEN="$TOKEN"

  local list="$AGENTS"
  if [ -z "$list" ]; then
    list="$(ask 'agentes (lista separada por vírgula): claude-code,grok,codex,cursor,gemini-cli,opencode' 'claude-code')"
  fi

  local agent
  IFS=',' read -ra arr <<< "$list"
  for agent in "${arr[@]}"; do
    agent="$(printf '%s' "$agent" | xargs)"
    [ -z "$agent" ] && continue
    log "reapontando agente: $agent"
    if [ "$DRY_RUN" = 0 ]; then
      ai-memory install-mcp   --client "$agent" --apply || warn "install-mcp $agent falhou"
      ai-memory install-hooks --agent  "$agent" --apply || warn "install-hooks $agent falhou"
    else
      printf '  [dry] ai-memory install-mcp --client %s --apply\n' "$agent"
      printf '  [dry] ai-memory install-hooks --agent %s --apply\n' "$agent"
    fi
  done
}

stop_local_docker() {
  command -v docker >/dev/null 2>&1 || return
  local cid
  cid="$(docker ps -q --filter name=ai-memory 2>/dev/null | head -1)"
  [ -n "$cid" ] || { log "nenhum container ai-memory local rodando."; return; }
  if [ "$STOP_LOCAL" = 1 ]; then
    log "parando container ai-memory local ($cid)..."
    docker stop "$cid"
  else
    warn "container ai-memory local rodando ($cid). Use --stop-local pra parar, ou pare manualmente — evita duas memórias divergindo."
  fi
}

summary() {
  cat <<EOF

============================================================
  ai-memory reapontado para o remoto.
============================================================
  Servidor:    ${SERVER_URL}
  Agentes:     ${AGENTS:-$list}

  Próximo: abra um terminal novo e teste:
    ai-memory status
  Deve reportar conexão OK com o servidor remoto.

  Se o container Docker local ainda estiver rodando, pare-o
  pra não manter duas memórias separadas.
============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes)       ASSUME_YES=1 ;;
      --dry-run)   DRY_RUN=1 ;;
      --stop-local) STOP_LOCAL=1 ;;
      --agents)    AGENTS="$2"; shift ;;
      *) die "flag desconhecida: $1" ;;
    esac
    shift
  done

  detect_os

  WRAPPER_PATH="$(detect_wrapper)"
  REPO_PATH="$(detect_repo)"
  print_state

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: nada será instalado."
    printf '  atualizaria wrapper (%s)\n' "${WRAPPER_PATH:-$BIN_DIR/ai-memory}"
    printf '  atualizaria repo Akita (%s)\n' "${REPO_PATH:-não achado}"
    printf '  reapontaria agentes via install-mcp/install-hooks\n'
    printf '  %s container Docker local\n' "$([ "$STOP_LOCAL" = 1 ] && echo pararia || echo avisaria sobre)"
    exit 0
  fi

  local server token
  server="$(ask 'URL do servidor remoto (ex: https://memory.seualuno.com)' "${AI_MEMORY_SERVER_URL:-}")"
  token="$(ask 'auth token (do install-server.sh)' "${AI_MEMORY_AUTH_TOKEN:-}")"
  [ -n "$server" ] || die "URL vazia"
  [ -n "$token" ]  || die "token vazio"
  SERVER_URL="$server"
  TOKEN="$token"

  update_wrapper
  update_repo
  repoint
  stop_local_docker
  summary
}

main "$@"
