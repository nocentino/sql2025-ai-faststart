# Connect AI agents to the database (MCP)

Once the stack is up, two MCP servers are available:

```
http://localhost:5001/mcp     # stackoverflow — Data API builder: semantic search + catalog
http://localhost:3001/mcp     # sql-dba       — read-only DBA monitoring (~30 tools)
```

Point any MCP-capable agent at them. After configuring, run the prompts in
[../demos/agent-demo.md](../demos/agent-demo.md).

> First verify both are healthy:
> `curl http://localhost:5001/health` and `curl http://localhost:3001/health`

---

## Claude in VS Code (Claude Code) — already wired up

**Nothing to configure.** This repo ships a project-scoped
[`.mcp.json`](../.mcp.json) at its root with **both** servers:

```json
{
  "mcpServers": {
    "stackoverflow": { "type": "http", "url": "http://localhost:5001/mcp" },
    "sql-dba":       { "type": "http", "url": "http://localhost:3001/mcp" }
  }
}
```

When you open this folder in VS Code, Claude discovers both servers
automatically. The first time, Claude asks you to **approve** each project MCP
server (project-scoped servers are trust-gated) — approve them, or run `/mcp` to
check status and approve. Then ask:

```
Use the stackoverflow tools to find questions about cleaning up a messy git history.
```

Run `/mcp` any time to see the connections and the tools Claude can see. The same
`.mcp.json` works for the Claude Code CLI in this directory — no extra setup.

---

## VS Code + GitHub Copilot

Add the servers to your MCP config. User-level file:

- macOS: `~/Library/Application Support/Code/User/mcp.json`
- Windows: `%APPDATA%\Code\User\mcp.json`
- Linux: `~/.config/Code/User/mcp.json`

```json
{
  "servers": {
    "stackoverflow": { "type": "http", "url": "http://localhost:5001/mcp" },
    "sql-dba":       { "type": "http", "url": "http://localhost:3001/mcp" }
  }
}
```

(Or commit a workspace config at `.vscode/mcp.json` with the same contents so
your team gets it automatically.)

Then: `⇧⌘P` → **Developer: Reload Window**, open Copilot Chat, switch to **Agent**
mode, and confirm the tools are listed. Try:

```
@stackoverflow find questions about how javascript closures work
```

---

## Claude Desktop

Edit the config file:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

Claude Desktop launches MCP servers over stdio, so bridge to the HTTP endpoints
with [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) (needs Node.js):

```json
{
  "mcpServers": {
    "stackoverflow": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:5001/mcp"]
    },
    "sql-dba": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:3001/mcp"]
    }
  }
}
```

Restart Claude Desktop. The tools appear in the tools menu (the slider/plug icon).

---

## What tools the agents see

**`stackoverflow`** (Data API builder):

| Tool | Backed by | What it does |
|---|---|---|
| `find_similar_questions` | `dbo.find_similar_questions` proc | **Semantic search** — embeds a natural-language prompt and vector-searches the questions |
| `Questions` (read) | `dbo.vQuestions` view | Filter questions by tag, score, view count, or date |
| `Users` (read) | `dbo.Users` | Look up who asked a question (reputation, location) |
| `describe_entities`, `read_records`, `aggregate_records`, `execute_entity` | DAB built-ins | Generic discovery / read / aggregate over the entities above |

The agent reads the `description` on each entity (from `dab-config.json`) to
decide which tool to use — `find_similar_questions` for fuzzy "find questions
like…" requests, `Questions` for exact lookups and structured filters.

**`sql-dba`** (read-only monitoring) — ~30 tools, including:

| Tool | What it does |
|---|---|
| `list_instances` | Which SQL Server instances are registered (here: `sql1`) |
| `get_wait_stats` | What the engine is waiting on |
| `get_top_queries` | Most expensive queries by CPU / reads / duration |
| `get_blocking_chains`, `get_active_sessions` | Who's blocking whom; what's running now |
| `get_missing_indexes`, `get_index_usage_stats` | Index recommendations and usage |
| `get_database_info`, `get_database_files`, `get_backup_status` | Database size, files, backup history |

All read-only (`dba_monitor` has `VIEW SERVER STATE` only). Most tools take an
optional `instance_name` (defaults across all registered instances).

## Troubleshooting

- **No tools show up** — re-check the `/health` endpoints, then reload/restart
  the client. MCP servers are discovered at client startup.
- **`find_similar_questions` errors** — the proc calls Ollama. Make sure
  `sql-init` exited 0 (`docker compose logs sql-init`), the host Ollama is
  running, and `model-web` is up (`docker compose ps`).
- **`sql-dba` tools error** — confirm `curl http://localhost:3001/health` and that
  `sql-init` created `dba_monitor` (it runs at startup).
- **Want to see the raw API?** `curl http://localhost:5001/api/Questions` (REST)
  or POST to `http://localhost:5001/graphql` (GraphQL) — same data, same
  permissions, no agent required.
