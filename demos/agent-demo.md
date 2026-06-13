# Agent demo — the natural-language finale

Run these in your AI client (Claude in VS Code, Copilot agent mode, or Claude
Desktop) once the MCP servers are wired up (see
[../docs/mcp-client-setup.md](../docs/mcp-client-setup.md)). This repo ships a
project-scoped `.mcp.json` with two servers:

- **`stackoverflow`** — Data API builder: semantic search + the question catalog.
- **`sql-dba`** — the SQL DBA MCP server: read-only fleet monitoring.

The prompts go from "look, no SQL" to "the agent reasons over my data" to "the
agent does DBA work," ordered to build the story for an audience that knows AI
but not SQL Server. For each prompt: read it out, let the agent run, then point
at **which tool it chose** and note that it never wrote SQL.

---

### 1. Semantic search (the headline)

> I'm trying to clean up a messy git history. Got any relevant questions?

The agent should call **`find_similar_questions`**. Make the point: the user said
"messy," "clean up" — not keywords in any title. The match comes from *meaning*,
computed by vector search inside SQL Server. Try a few more live — these all
return spot-on matches with no shared keywords:

> How do JavaScript closures actually work?

> What's the difference between declaring a variable with let versus var?

> How do I get a box to sit in the middle of the page, both directions?

That last one returns *"How to vertically center a div for all browsers?"* —
"box" ≈ "div," "middle of the page" ≈ "center." That's the wow.

---

### 2. Semantic vs. exact — let the agent pick the right tool

> Show me the top 10 highest-scored questions tagged with python.

This is a structured filter, so the agent should use **`Questions`** (the view),
not `find_similar_questions`. Contrast it with prompt 1: same database, two
different tools, and the agent decides based on the tool descriptions you wrote
in `dab-config.json`.

> Now find me questions *similar in spirit* to "how do I make my code run faster."

Back to **`find_similar_questions`** — "similar in spirit" is a meaning question.

---

### 3. Multi-step reasoning across tools

> Find a few popular questions about asynchronous programming, and tell me who
> asked them and what their reputation is.

Watch the agent combine **`find_similar_questions`** (semantic) → take the
`OwnerUserId` → look the author up via **`Users`**, then synthesize. That's the
kind of thing that normally takes an embedding pipeline, a vector store, and an
API. Here it's one MCP server over one database.

---

### 4. The bonus act — agents doing DBA work (`sql-dba` server)

Switch servers. Everything above was the *application* talking to its data; now
the agent is a junior DBA looking after the server itself — still no SQL written
by hand, still boxed into read-only.

> This SQL Server feels sluggish. What is it spending its time waiting on?

Calls **`get_wait_stats`** on the `sql1` instance and explains the top waits in
plain language.

> What are the most expensive queries running on it right now?

**`get_top_queries`**. Follow with:

> Is anything blocking anything else? And what sessions are currently active?

**`get_blocking_chains`** + **`get_active_sessions`**.

> Which databases live on this instance, how big are they, and are there any
> missing indexes worth looking at?

**`get_database_info`** / **`get_database_files`** / **`get_missing_indexes`** —
the agent chains several monitoring tools and writes you a short health summary.
(The server exposes ~30 read-only tools — wait stats, blocking, top queries,
file IO, memory, tempdb, deadlocks, backup/AG health, and more.)

---

### 5. The governance point (great closer)

> Drop the Posts table. Then delete the user with the highest reputation.

The agent will report it **can't** — the `stackoverflow` entities are read-only
in `dab-config.json`, the `sql-dba` server's tools are all read-only, and neither
login can write anything: `dab_app` has `SELECT`/`EXECUTE` only, and `dba_monitor`
has just `VIEW SERVER STATE`. This is the line to land on: *the guardrails live in
the MCP config and least-privilege SQL logins, not in hoping the model behaves.*
Open `dab-config.json` and show the `permissions` blocks; the agent's reach is
exactly what's listed there and nothing more.

---

## The takeaway to say out loud

> "I didn't build a vector database. I didn't build an embedding service. I
> didn't build an API. SQL Server 2025 generated the embeddings and did the
> vector search; Data API builder turned the database into MCP tools from one
> config file; and a tiny MCP server gave my agent read-only DBA superpowers —
> with both agents boxed into exactly what I chose to expose."
