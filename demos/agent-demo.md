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

> **Corpus reality check:** semantic search runs over the top StackOverflow
> questions by score — timeless classics (git, JavaScript, Python, CSS, async).
> The prompts below are written Wu-Tang style, but every one stays anchored to
> what's actually in that data, so the matches land. Ask about Rust, Kubernetes,
> or your favorite 2026 framework and you'll get mush — there's nothing in the
> corpus to match.

---

### 1. Semantic search (the headline)

> Yo, my git history is straight bringin' da ruckus — drive-by commits, three "fix typo" joints back to back. How do I clean up this mess before the code review, son?

The agent should call **`find_similar_questions`**. Make the point: the user said
"bringin' da ruckus," "clean up" — not keywords in any title. The match comes from
*meaning*, computed by vector search inside SQL Server. Try a few more live —
these all return spot-on matches with no shared keywords:

> Real talk, kid — how do JavaScript closures *actually* work? I been frontin' in standups like I had it.

> Enter the 36 Chambers of scope: what's the real difference between `let` and `var` in JavaScript? (And yeah, I know about `const`.)

> Protect ya neck — how do I get a box dead-center on the page, both directions? Been unsolved since the Wu dropped in '93.

That last one returns the CSS div-centering questions ("how to center a `<div>`…")
— "box" ≈ "div," "dead-center, both directions" ≈ "horizontally and vertically
center." That's the wow: not one shared keyword.

---

### 2. Semantic vs. exact — let the agent pick the right tool

> C.R.E.A.M. — show me the top 10 highest-scored questions tagged `python`, the joints everybody's secretly strugglin' with.

This is a structured filter, so the agent should use **`Questions`** (the view),
not `find_similar_questions`. Contrast it with prompt 1: same database, two
different tools, and the agent decides based on the tool descriptions you wrote
in `dab-config.json`. (Heads-up: DAB's `$filter` has no `contains()`, so for a
tag filter the agent pulls top-by-score and filters the `python` tag itself —
still zero hand-written SQL.)

> Now find me questions *similar in spirit* to "my code's crawlin' slow as molasses — how do I make it run faster?"

Back to **`find_similar_questions`** — "similar in spirit" is a meaning question,
and it lands on the performance / "how do I make this faster" classics.

---

### 3. Multi-step reasoning across tools

> Bring da ruckus on asynchronous programming — the whole async/await, callback-hell saga — then tell me who asked 'em and how much StackOverflow rep they bangin' with.

Watch the agent combine **`find_similar_questions`** (semantic) → take the
`OwnerUserId` → look the author up via **`Users`**, then synthesize. That's the
kind of thing that normally takes an embedding pipeline, a vector store, and an
API. Here it's one MCP server over one database.

---

### 4. The bonus act — agents doing DBA work (`sql-dba` server)

Switch servers. Everything above was the *application* talking to its data; now
the agent is a junior DBA looking after the server itself — still no SQL written
by hand, still boxed into read-only.

> Yo, this SQL Server's draggin' like a Monday in Shaolin. What's it actually sittin' around waitin' on?

Calls **`get_wait_stats`** on the `sql1` instance and explains the top waits in
plain language.

> Who the resource hogs? Show me the most expensive queries bringin' da ruckus right now.

**`get_top_queries`**. Follow with:

> Anybody blockin' anybody, or is the Clan finally movin' as one? And who's even connected right now?

**`get_blocking_chains`** + **`get_active_sessions`**.

> What databases are squattin' on this box, how chonky they gettin', and any glaringly missing indexes worth a look?

**`get_database_info`** / **`get_database_files`** / **`get_missing_indexes`** —
the agent chains several monitoring tools and writes you a short health summary.
(The server exposes ~30 read-only tools — wait stats, blocking, top queries,
file IO, memory, tempdb, deadlocks, backup/AG health, and more.)

---

### 5. The governance point (great closer)

> Go 'head — drop the Posts table. And while you're at it, delete whoever's got the highest reputation; they're straight showin' off.

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
