# ai-memory-installer

<p align="center">
  <img src="assets/logo.svg" alt="ai-memory-installer logo" width="128" />
</p>

Instalador CLI (bash) para distribuir o setup do [**ai-memory**](https://github.com/akitaonrails/ai-memory),
do [Akita](https://github.com/akitaonrails), num único servidor — VPS Ubuntu exposto via
**Cloudflare Tunnel**, com hardening de SSH/firewall — pronto para alunos ou qualquer pessoa
que queira uma memória de longo prazo centralizada para agentes
(Claude Code, Grok Build CLI, Codex, Cursor, etc.).

Dois scripts, idempotentes, `curl | bash`:

| Script | Onde roda | O que faz |
| --- | --- | --- |
| `install-server.sh` | VPS Ubuntu do aluno | Docker + cloudflared + wrapper, sobe ai-memory via compose oficial, hardening (chave SSH → senha off → UFW → fail2ban) |
| `install-client.sh` | Máquina do aluno | Wrapper + env vars + `install-mcp`/`install-hooks` por agente |

---

## Pré-requisitos (aluno)

1. **VPS Ubuntu 22.04/24.04** com acesso root.
2. **Conta Cloudflare** com um domínio já apontado pra ela (nameservers na Cloudflare).
3. Um **Tunnel token** criado no dashboard (Zero Trust → Networks → Tunnels → Create).
   Não precisa criar o public hostname agora — o script só recebe o token; o hostname
   você configura no dashboard depois (passo abaixo).

---

## Passo 1 — Subir o servidor

Na VPS, como root:

```bash
curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-server.sh | bash
```

O script pergunta:
- **hostname** do túnel (ex: `memory.seualuno.com`)
- **tunnel token** (cole do dashboard)
- **aplicar hardening?** (recomendado: `s`)

Se preferir não-interativo:

```bash
AI_MEMORY_HOSTNAME=memory.seualuno.com \
CLOUDFLARE_TUNNEL_TOKEN=<token> \
curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-server.sh | bash -s -- --yes
```

Quer só ver o que faria sem executar? `... | bash -s -- --dry-run`.

No final ele imprime URL, token e o comando do client. **Guarde o token.**

### Ação manual no dashboard (obrigatória)

O túnel é *remote-managed*: o destino do tráfego é definido no dashboard, não num
arquivo local. Depois do script:

1. Cloudflare **Zero Trust → Networks → Tunnels** → seu túnel → **Public Hostname**.
2. Adicione `memory.seualuno.com` com service **`http://ai-memory:49374`**.
3. Aguarde o DNS propagar (~1 min) e teste `https://memory.seualuno.com/web`.

---

## Passo 2 — Conectar cada máquina

Em cada máquina onde roda Claude Code / Grok / Codex etc.:

```bash
curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-client.sh | bash
```

Pede URL + token (os mesmos do resumo do servidor) e a lista de agentes.

Não-interativo:

```bash
AI_MEMORY_SERVER_URL=https://memory.seualuno.com \
AI_MEMORY_AUTH_TOKEN=<token> \
curl -fsSL https://raw.githubusercontent.com/giovani-junior-dev/ai-memory-installer/main/install-client.sh | bash -s -- --yes --agents claude-code,grok
```

Teste:

```bash
ai-memory status
```

---

## O que o hardening faz (e por que é seguro)

Ordem crítica, nesta ordem exata:

1. Gera chave `ed25519` (se não existe) e adiciona ao `authorized_keys`.
2. **Testa** login por chave (`ssh root@127.0.0.1`).
3. Só se o teste passar: drop-in `00-hardening.conf` → `PasswordAuthentication no` → reload ssh.
4. UFW (deny incoming, allow 22) + fail2ban (jail sshd).

Se o teste de chave falhar, o script **não desliga a senha** — você não fica trancado
fora. Para acessar depois: importe a chave privada `~/.ssh/id_ed25519` da VPS no seu
cliente SSH (ex: Bitvise).

---

## Notas

- **Zero-LLM por padrão**: sem API key, o servidor roda em modo FTS5 (busca + entidades +
  grafo). Para ligar consolidação/embeddings, adicione `AI_MEMORY_LLM_PROVIDER` + chave
  em `docker/.env.production` e `docker compose ... up -d` de novo.
- **Sem token de auth = sem proteção**: o script sempre gera um token. Não rode sem.
- **Versão**: fixe a versão do compose via `git -C /opt/ai-memory checkout <tag>` se
  quiser reproduzibilidade total (senão usa `latest`).
- **Backup**: fora do escopo deste installer. Para replicar off-site (B2/S3), veja o
  `ai-memory backup --to` + rclone no guia da Fase 1.

## Troubleshooting

| Sintoma | Causa provável | Fix |
| --- | --- | --- |
| `https://.../web` não abre | public hostname não configurado no dashboard, ou service errado | confirme service = `http://ai-memory:49374` |
| `ai-memory status` falha | token/URL errados | confira env vars, rode de novo |
| login SSH recusado após hardening | chave não testada/importada | importe `id_ed25519` no seu cliente SSH |
| container não fica healthy | `docker compose ... logs ai-memory` | veja o log do container |

---

## Baseado em

Este installer empacota o [**ai-memory**](https://github.com/akitaonrails/ai-memory) do
[Akita](https://github.com/akitaonrails) — o servidor de memória de longo prazo para agentes
(SQLite + wiki versionada em git, busca FTS5 + entidades + grafo). Este repo **não contém**
código do ai-memory: o instalador clona o repositório oficial e usa os templates de compose
oficiais (`docker/compose.tls.cloudflared.yml`, `docker/.env.production.example`).

- Repo oficial: <https://github.com/akitaonrails/ai-memory>
- Imagem Docker: `akitaonrails/ai-memory`

Toda a lógica do servidor é do projeto ai-memory do Akita; este repo só automatiza a
instalação e o hardening.

---

Licença: MIT.
