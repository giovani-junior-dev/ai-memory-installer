#!/usr/bin/env bash
#
# install-client.sh — conecta a máquina do aluno ao servidor ai-memory remoto.
#
# Distribuição:
#   curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-client.sh | bash
#
# Faz:
#   1. Instala o wrapper ai-memory em ~/.local/bin
#   2. Persiste AI_MEMORY_SERVER_URL + AI_MEMORY_AUTH_TOKEN no shell rc
#   3. Roda install-mcp + install-hooks para cada agente escolhido
#
# Flags:
#   --yes              não-interativo (usa env vars AI_MEMORY_SERVER_URL/AI_MEMORY_AUTH_TOKEN/AGENTS)
#   --agents a,b,c     lista de agentes (ex: claude-code,grok,codex)
#   --dry-run          imprime o plano sem executar
#
set -euo pipefail

WRAPPER_URL="https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-wrapper"
BIN_DIR="$HOME/.local/bin"

DRY_RUN=0
ASSUME_YES=0
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

detect_os() {
  case "$(uname -s)" in
    Linux|Darwin)   : ;;
    MINGW*|MSYS*|CYGWIN*) warn "Git Bash no Windows: script parcial — use WSL ou Linux/macOS para o wrapper." ;;
    *) warn "OS não reconhecido: $(uname -s)" ;;
  esac
}

install_wrapper() {
  if command -v ai-memory >/dev/null 2>&1; then
    log "wrapper ai-memory já no PATH."
    return
  fi
  log "instalando wrapper em $BIN_DIR ..."
  mkdir -p "$BIN_DIR"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$WRAPPER_URL" -o "$tmp/ai-memory-wrapper"
  install -m 0755 "$tmp/ai-memory-wrapper" "$BIN_DIR/ai-memory"
  rm -rf "$tmp"
  # garante PATH
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) export PATH="$BIN_DIR:$PATH" ;;
  esac
}

persist_env() {
  local server="$1" token="$2" rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -q 'AI_MEMORY_SERVER_URL=' "$rc" || echo "export AI_MEMORY_SERVER_URL=\"$server\"" >> "$rc"
    grep -q 'AI_MEMORY_AUTH_TOKEN=' "$rc" || echo "export AI_MEMORY_AUTH_TOKEN=\"$token\"" >> "$rc"
  done
  log "env vars persistidas (bashrc/zshrc, se existirem)."
}

connect_agents() {
  local server="$1"
  export AI_MEMORY_SERVER_URL="$server"
  export AI_MEMORY_AUTH_TOKEN="${AI_MEMORY_AUTH_TOKEN:-$2}"

  local list="$AGENTS"
  if [ -z "$list" ]; then
    list="$(ask 'agentes (lista separada por vírgula): claude-code,grok,codex,cursor,gemini-cli,opencode' 'claude-code')"
  fi

  local agent
  IFS=',' read -ra arr <<< "$list"
  for agent in "${arr[@]}"; do
    agent="$(printf '%s' "$agent" | xargs)"   # trim
    [ -z "$agent" ] && continue
    log "conectando agente: $agent"
    if [ "$DRY_RUN" = 0 ]; then
      ai-memory install-mcp   --client "$agent" --apply || warn "install-mcp $agent falhou"
      ai-memory install-hooks --agent  "$agent" --apply || warn "install-hooks $agent falhou"
    else
      printf '  [dry] ai-memory install-mcp --client %s --apply\n' "$agent"
      printf '  [dry] ai-memory install-hooks --agent %s --apply\n' "$agent"
    fi
  done
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes)     ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --agents)  AGENTS="$2"; shift ;;
      *) die "flag desconhecida: $1" ;;
    esac
    shift
  done

  detect_os

  local server token
  server="$(ask 'URL do servidor (ex: https://memory.seualuno.com)' "${AI_MEMORY_SERVER_URL:-}")"
  token="$(ask 'auth token (do resumo do install-server.sh)' "${AI_MEMORY_AUTH_TOKEN:-}")"
  [ -n "$server" ] || die "URL vazia"
  [ -n "$token" ]  || die "token vazio"

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: nada será instalado."
    printf '  instalaria wrapper em %s\n' "$BIN_DIR"
    printf '  export AI_MEMORY_SERVER_URL="%s"\n' "$server"
    printf '  export AI_MEMORY_AUTH_TOKEN="***"\n'
    connect_agents "$server" "$token"
    exit 0
  fi

  install_wrapper
  persist_env "$server" "$token"
  connect_agents "$server" "$token"

  cat <<'EOF'

============================================================
  Próximo: abra um terminal novo e teste:
    ai-memory status
  Deve reportar conexão OK com o servidor remoto.
============================================================
EOF
}

main "$@"
