# Agent demo — the natural-language finale

Run these in your AI client (Copilot agent mode or Claude Desktop) once the
`adventureworks` MCP server is wired up (see
[../docs/mcp-client-setup.md](../docs/mcp-client-setup.md)). They go from "look,
no SQL" to "the agent reasons over my data," and they're ordered to build the
story for an audience that knows AI but not SQL Server.

For each prompt: read it out, let the agent run, then point at **which tool it
chose** and note that it never wrote SQL.

---

### 1. Semantic search (the headline)

> Find me a comfortable bike for long weekend rides — nothing too expensive.

The agent should call **`FindSimilarProducts`**. Make the point: the user said
"comfortable," "long rides," "not expensive" — none of which are columns or
keywords. The match comes from *meaning*, computed by vector search inside SQL
Server. Ask a follow-up to show it's conversational:

> Of those, which is the best value, and why?

---

### 2. Semantic vs. exact — let the agent pick the right tool

> List every product in the "Road Bikes" category and their prices.

This is a structured filter, so the agent should use **`Products`**, not
`FindSimilarProducts`. Contrast it with prompt 1: same database, two different
tools, and the agent decides based on the tool descriptions you wrote in
`dab-config.json`.

> Now find me something *like* a road bike but better for rough trails.

Back to **`FindSimilarProducts`** — "like… but for…" is a meaning question.

---

### 3. Multi-step reasoning across tools

> What product categories do we sell, and roughly how is the catalog split
> across them?

The agent uses **`ProductCategories`** (and maybe `Products`) and summarizes.

> A customer wants a gift under $50 for someone who likes cycling. Suggest a few
> options and explain each.

Watch it combine **`FindSimilarProducts`** (semantic) with a price constraint and
synthesize a recommendation — the kind of thing that normally takes an
embedding pipeline, a vector store, and an API. Here it's one MCP server.

---

### 4. Order data (shows it's a whole database, not just a search box)

> Show me the most recent sales orders and their totals.

Uses **`SalesOrders`**.

> For the largest of those orders, what was actually in it?

Uses **`SalesOrderDetails`** joined to **`Products`** — the agent chains tool
calls to answer a question that spans tables.

---

### 5. The governance point (great closer)

> Delete all discontinued products.

The agent will report it **can't** — the entities are read-only in
`dab-config.json` and `dab_app` has no such rights anyway. This is the line to
land on: *the guardrails live in Data API builder and a least-privilege SQL
login, not in hoping the model behaves.* Open `dab-config.json` and show the
`permissions` blocks; the agent's reach is exactly what's listed there and
nothing more.

---

## The takeaway to say out loud

> "I didn't build a vector database. I didn't build an embedding service. I
> didn't build an API. SQL Server 2025 generated the embeddings and did the
> vector search, and Data API builder turned the database into MCP tools from one
> config file — with the agent boxed into exactly what I chose to expose."
