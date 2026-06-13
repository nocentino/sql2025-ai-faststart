# Connect an AI agent to the database (MCP)

Once the stack is up, Data API builder serves an MCP endpoint at:

```
http://localhost:5001/mcp
```

Point any MCP-capable agent at it. After configuring, run the prompts in
[../demos/agent-demo.md](../demos/agent-demo.md).

> First verify DAB is healthy: `curl http://localhost:5001/health`

---

## Claude in VS Code (Claude Code) — already wired up

**Nothing to configure.** This repo ships a project-scoped
[`.mcp.json`](../.mcp.json) at its root:

```json
{
  "mcpServers": {
    "adventureworks": {
      "type": "http",
      "url": "http://localhost:5001/mcp"
    }
  }
}
```

When you open this folder in VS Code, Claude discovers that server
automatically. The first time, Claude asks you to **approve** the project MCP
server (project-scoped servers are trust-gated) — approve it, or run
`/mcp` in Claude to check status and approve. Then ask:

```
Use the adventureworks tools to find me a comfortable bike for long rides under $1000.
```

Run `/mcp` any time to see the connection and the tools Claude can see. The same
`.mcp.json` works for the Claude Code CLI in this directory — no extra setup.

---

## VS Code + GitHub Copilot

Add the server to your MCP config. User-level file:

- macOS: `~/Library/Application Support/Code/User/mcp.json`
- Windows: `%APPDATA%\Code\User\mcp.json`
- Linux: `~/.config/Code/User/mcp.json`

```json
{
  "servers": {
    "adventureworks": {
      "type": "http",
      "url": "http://localhost:5001/mcp"
    }
  }
}
```

(Or commit a workspace config at `.vscode/mcp.json` with the same contents so
your team gets it automatically.)

Then: `⇧⌘P` → **Developer: Reload Window**, open Copilot Chat, switch to **Agent**
mode, and confirm the `adventureworks` tools are listed. Try:

```
@adventureworks find me a comfortable bike for long rides under $1000
```

---

## Claude Desktop

Edit the config file:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

Claude Desktop launches MCP servers over stdio, so bridge to the HTTP endpoint
with [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) (needs Node.js):

```json
{
  "mcpServers": {
    "adventureworks": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:5001/mcp"]
    }
  }
}
```

Restart Claude Desktop. The `adventureworks` tools appear in the tools menu (the
slider/plug icon).

---

## What tools the agent sees

| Tool | Backed by | What it does |
|---|---|---|
| `FindSimilarProducts` | `SalesLT.find_similar_products` proc | **Semantic search** — embeds a natural-language prompt and vector-searches the catalog |
| `Products` (read) | `SalesLT.vProductCatalog` view | Browse/filter the catalog by name, category, color, price |
| `ProductCategories` (read) | `SalesLT.ProductCategory` | The category hierarchy |
| `Customers` (read) | `SalesLT.Customer` | Customer records |
| `SalesOrders` (read) | `SalesLT.SalesOrderHeader` | Order headers |
| `SalesOrderDetails` (read) | `SalesLT.SalesOrderDetail` | Order line items |

The agent reads the `description` on each entity (from `dab-config.json`) to
decide which tool to use — so `FindSimilarProducts` for fuzzy "find me something
like…" requests, and `Products` for exact lookups and structured filters.

## Troubleshooting

- **No tools show up** — re-check `curl http://localhost:5001/health`, then
  reload/restart the client. MCP servers are discovered at client startup.
- **`FindSimilarProducts` errors** — the proc calls Ollama. Make sure the
  `sql-init` container exited 0 (`docker compose logs sql-init`) and Ollama is
  healthy (`docker compose ps`).
- **Want to see the raw API?** `curl http://localhost:5001/api/Products` (REST)
  or POST a query to `http://localhost:5001/graphql` (GraphQL) — same data, same
  permissions, no agent required.
