# Prompt de agente — reapontar instalação local pro remoto

Cole este prompt num agente (Claude Code, Codex, etc.) **na máquina que já tem o
ai-memory instalado e rodando local** (Docker Desktop). Antes de colar, substitua:

- `{{URL}}` pela URL do servidor remoto (ex: `https://memory.seualuno.com`)
- `{{TOKEN}}` pelo token de auth gerado no servidor

Não cole este arquivo com valores reais em lugar público.

---

```
Você está numa máquina que já tem o ai-memory (akitaonrails/ai-memory) instalado
e rodando localmente, provavelmente via Docker Desktop. Preciso reapontar essa
instalação para um servidor ai-memory REMOTO, em vez do local.

Faça, nesta ordem:

1. LOCALIZE o repositório do Akita nesta máquina. Procure por um clone git de
   akitaonrails/ai-memory (ex: ~/ai-memory, ~/src/ai-memory, ~/akitaonrails/ai-memory,
   /opt/ai-memory). Identifique o caminho real.

2. ANALISE se o repo local está atualizado. Rode `git -C <caminho> status` e
   `git -C <caminho> fetch --dry-run` (ou `git remote -v` + `git log -1`) e reporte:
   - a branch atual e o último commit local;
   - se está atrás do remoto (commits pendentes).

3. ATUALIZE o repo local: `git -C <caminho> pull --ff-only`. Se falhar por mudanças
   locais não commitadas, liste-as e avise (não force).

4. ATUALIZE o wrapper `ai-memory` para o último release do projeto Akita
   (release `latest` → asset `ai-memory-wrapper`). Se já existir um binário
   `ai-memory` no PATH, sobrescreva-o; senão instale em `~/.local/bin` e garanta
   que está no PATH.

5. REAPONTE cada agente para o servidor remoto. Para cada agente presente na
   máquina (claude-code, grok, codex, cursor, gemini-cli, opencode), rode com estas
   variáveis de ambiente definidas:

       AI_MEMORY_SERVER_URL="{{URL}}"
       AI_MEMORY_AUTH_TOKEN="{{TOKEN}}"

   e então:

       ai-memory install-mcp   --client <agente> --apply
       ai-memory install-hooks --agent  <agente> --apply

6. VERIFIQUE com `ai-memory status`. Deve reportar conexão OK com "{{URL}}".

7. AVISE sobre o Docker local: se houver container ai-memory rodando no Docker
   Desktop, me diga o nome do container e avise que ele deve ser parado (para não
   manter duas memórias separadas). NÃO pare sem eu confirmar.

Reporte no final: caminho do repo encontrado, se estava atrás do remoto, agentes
reapontados, e o resultado de `ai-memory status`.

Não exponha o token em logs nem em resumo — refira-se a ele como <TOKEN>.
```
