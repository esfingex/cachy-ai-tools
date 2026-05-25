# 🛸 cachy-ai-tools

AI developer tools, token-reduction frameworks, and persistent cross-agent memory layers for Arch Linux / CachyOS.

Isolated from core system tweaks → lightweight, clean, reproducible.

> **v2.0 (2026-05)**: Now ships with a self-hosted CaveMem stack in [`cavemem-stack/`](cavemem-stack/) — local Express + `better-sqlite3` + `@huggingface/transformers` v3, with EJS dashboard, REST API, edit modal, and pagination. Replaces the external npm `cavemem` package; cross-platform parity with the Windows `ia-tools-win` project.

---

## 🛠️ Included Components

1. **[`setup.sh`](setup.sh) — Automated Bootstrapper**
   - Installs NodeJS LTS via `pacman` (with v25+ downgrade handling for native bindings).
   - Installs the local CaveMem stack (`cavemem-stack/`) via [`scripts/cavemem-install.sh`](scripts/cavemem-install.sh).
   - Symlinks `cavemem` CLI to `~/.local/bin/cavemem` (or `/usr/local/bin/cavemem`).
   - Wires CaveMem as an MCP server in `~/.gemini/config/mcp_config.json`.
   - Optional: prompts for GitHub MCP setup, installs `caveman` skills for Antigravity.

2. **[`cavemem-stack/`](cavemem-stack/) — Local Node app**
   - `server.js` — Express REST API + EJS dashboard (binds `127.0.0.1:3000` by default).
   - `db.js` — `better-sqlite3` with WAL, indexes, `updated_at` trigger, JSON tags.
   - `search-engine.js` — `@huggingface/transformers` v3 (MiniLM-L6-v2, 384-dim).
   - `views/index.ejs` — Dashboard with semantic search, edit modal, paginator, category filter.

3. **[`scripts/cavemem.sh`](scripts/cavemem.sh) — Linux CLI** (same UX as Windows `cavemem.ps1`)
   - Auto-starts the local server in the background on first command.
   - Subcommands: `add`, `edit`, `query`/`search`, `list`, `status`, `delete`, `web`, `stop`.

4. **[`scripts/cavemem-sync.sh`](scripts/cavemem-sync.sh) — LAN sync**
   - Auto-detects v2 (sync entire `cavemem-stack/dbs/`) vs legacy (single `data.db`) layout.
   - WAL-checkpoints before/after rsync to guarantee consistent snapshots.

5. **[`prompts/ai-rules.md`](prompts/ai-rules.md) — Token-reduction system prompt**
   - Strips pleasantries, adverbs, filler. ~70% token reduction with full technical substance preserved.

---

## 🚀 Getting Started

```bash
git clone https://github.com/YOUR_USERNAME/cachy-ai-tools.git ~/Github/cachy-ai-tools
cd ~/Github/cachy-ai-tools
chmod +x setup.sh scripts/*.sh
sudo ./setup.sh
```

After install, open a new shell so `~/.local/bin/cavemem` is on `PATH`, then:

```bash
cavemem status        # auto-starts server, downloads model on first run (~80 MB)
cavemem web           # open http://127.0.0.1:3000 in browser
```

---

## ⚡ Usage Reference

### 1. Cross-Session Persistent Memory (`cavemem`)

The project context is auto-derived from the current directory name. Each project gets its own SQLite DB under `cavemem-stack/dbs/<project>.db`.

```bash
# Record a fact
cavemem add gotcha "Firebird requires ISO8859_1 encoding in JNDI" -t firebird,encoding

# Edit an existing memory
cavemem edit 12 -c rule -t firebird,db "Updated content here"

# Semantic vector search (cosine similarity, threshold default 0.25)
cavemem query "firebird connection" -l 5 -T 0.3

# Paginated list with category filter
cavemem list -l 50 -o 0 -c gotcha

# Project stats
cavemem status

# Delete by id
cavemem delete 7

# Open the web dashboard for the active project
cavemem web

# Stop the background server
cavemem stop
```

#### Maintenance commands

```bash
# Scan for near-duplicate pairs (cosine similarity)
cavemem dedup -T 0.92

# Merge two memories (keeps the first, drops the second, merges tags)
cavemem merge 12 38              # keep 12, drop 38
cavemem merge 12 38 --append     # also concatenate content with '---' separator

# Auto-merge ALL duplicates above threshold (dry-run first!)
cavemem autodedup -T 0.92 --dry  # preview
cavemem autodedup -T 0.92        # execute

# Recompute all vectors with current model (needed after CAVEMEM_MODEL change)
cavemem reembed                  # uses default dim check
cavemem reembed --force          # accept new dim (when switching to a model with different dim)
```

**Env overrides**: `CAVEMEM_SERVER_URL`, `CAVEMEM_STACK_DIR`, `CAVEMEM_HOST`, `CAVEMEM_CORS_ORIGIN`, `CAVEMEM_DBS_DIR`, `CAVEMEM_SCORE_THRESHOLD`, `CAVEMEM_DEDUP_THRESHOLD`, `CAVEMEM_MODEL`, `CAVEMEM_EMBEDDING_DIM`, `CAVEMEM_OFFLINE`, `CAVEMEM_PAGE_SIZE`.

#### Swapping the embedding model

Default: `Xenova/all-MiniLM-L6-v2` (80 MB, 384-dim, English-optimized).

Recommended alternatives:

| Model | Size | Dim | Notes |
|-------|------|-----|-------|
| `Xenova/all-MiniLM-L6-v2` (default) | 80 MB | 384 | Fast, English-optimized |
| `Xenova/multilingual-e5-small` | 470 MB | 384 | Multilingual (Spanish, French, etc.) — better recall on non-English memories |
| `Xenova/bge-small-en-v1.5` | 130 MB | 384 | Higher quality than MiniLM, same dim |
| `Xenova/all-mpnet-base-v2` | 420 MB | 768 | Highest quality, slower, **different dim** (set `CAVEMEM_EMBEDDING_DIM=768`) |

Switching procedure:

```bash
# 1. Stop the server
cavemem stop

# 2. Set the new model (and dim if different from 384)
export CAVEMEM_MODEL="Xenova/multilingual-e5-small"
# export CAVEMEM_EMBEDDING_DIM=768   # only if model dim ≠ 384

# 3. Restart and re-embed all existing memories
cavemem status                  # auto-starts server with new model
cavemem reembed --force         # recompute all vectors for the active project

# Repeat 'cavemem reembed --force' inside every project dir that has data.
```

### 2. REST API (for editor / agent integrations)

```
GET    /api/health
GET    /api/categories
GET    /api/projects
GET    /api/status?project=<p>
GET    /api/memories?project=<p>&limit=24&offset=0&category=<cat>
GET    /api/memories/:id?project=<p>
POST   /api/memories            { project, category, content, tags }
PUT    /api/memories/:id        { project, category?, content?, tags? }
DELETE /api/memories/:id?project=<p>
GET    /api/search?project=<p>&q=<text>&limit=5&threshold=0.25

GET    /api/dedup?project=<p>&threshold=0.92&category=<cat>
POST   /api/dedup/merge         { project, keepId, dropId, appendContent? }
POST   /api/dedup/auto          { project, threshold?, dryRun? }
POST   /api/reembed             { project, force? }
```

### 3. Network Sync Utility (`cavemem-sync`)

```bash
./scripts/cavemem-sync.sh setup   # SSH connection details
./scripts/cavemem-sync.sh status  # newest DB timestamp comparison
./scripts/cavemem-sync.sh push    # local → remote
./scripts/cavemem-sync.sh pull    # remote → local
```

Auto-detects layout: with `cavemem-stack/` it syncs the **whole `dbs/` directory** (all project DBs); without it falls back to the legacy single `.cavemem/data.db`.

### 4. Output Token Compressor (`caveman`)

```bash
npx skills add JuliusBrussee/caveman
```

Plus the rules in [`prompts/ai-rules.md`](prompts/ai-rules.md) for your agent's system config.

---

## 🤖 AI Assistant Integration (.cursorrules / .clinerules)

To enable any modern AI coding assistant (such as **Cursor Agent**, **Cline**, **Roo-Code**, or **Windsurf**) to automatically search and feed your CaveMem stack in your Linux workspace, follow these steps:

1. Locate the **`.cursorrules.template`** file in the root of this `cachy-ai-tools` folder.
2. Copy this file into your active development project's root folder (e.g. `~/Github/my-project`).
3. Rename the file to:
   * **`.cursorrules`** if you are using Cursor.
   * **`.clinerules`** if you are using Cline or Roo-Code.
4. That's it! Your AI assistant will now read these rules automatically at startup, learn that it has the "CaveMem superpower," and query/save project memories autonomously using your global `cavemem` CLI or API endpoints!

---

## 🔐 Security Defaults

- Server binds `127.0.0.1` only (override with `CAVEMEM_HOST`).
- CORS restricted to `localhost:PORT` and `127.0.0.1:PORT` (override with `CAVEMEM_CORS_ORIGIN`).
- Category validated server-side (enum: `gotcha`, `rule`, `flow`, `config`, `dependency`).
- Body limit 1 MB. Vector dim check (384) on every insert/update.
- All EJS output escaped; client-side `escapeHtml` for dynamic search renders.

---

## 🪟 Cross-Platform Note

The exact same `cavemem-stack/` runs on Windows via the sibling project at `ia-tools-win` (uses `cavemem.ps1`). DBs created on Linux are bit-identical and can be `rsync`-ed to a Windows host (and vice versa).

---

## 📄 License

MIT — see [LICENSE](LICENSE).
