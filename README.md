# SQL Server 2025 AI FastStart

> **AI _inside_ the database, and AI agents _onto_ it — safely.** SQL Server 2025
> native vector search and `AI_GENERATE_EMBEDDINGS` over the StackOverflow dataset,
> exposed to AI agents through Data API builder's built-in MCP server. No separate
> vector database, no embedding service, no API tier.

This is a container-based playground that tells one story end to end: **your
relational database can do AI itself, and your AI agents can talk to it safely.**

It brings together two things I've been demoing separately:

- **[ollama-sql-faststart](https://github.com/nocentino/ollama-sql-faststart)** — SQL
  Server 2025's native vector type, `AI_GENERATE_EMBEDDINGS`, and DiskANN vector
  search, with a local Ollama model so there are no cloud keys to manage.
- **[Data API builder](https://learn.microsoft.com/en-us/azure/data-api-builder/)
  (DAB) and its new MCP support** — point it at a database and it exposes REST,
  GraphQL, **and** a Model Context Protocol (MCP) server with zero code, so an AI
  agent like Claude or GitHub Copilot can query your data as a set of tools.

The data is the **StackOverflow** public dataset — real developer questions — so
semantic search lands for an AI audience: you search by *meaning*, over text
everyone in the room recognizes. As a bonus second act, a small **SQL DBA MCP
server** gives the agent ~30 read-only fleet-monitoring tools, so it can also
reason about the *health* of the server, not just its data.

If you live in the AI world but SQL Server isn't your daily driver, here's the
one-sentence bridge: **everything you already know about embeddings, vector
search, and RAG works here — except the vectors live right next to the business
data in regular tables, the embedding call is a SQL function, and exposing it to
an agent is a config file, not a service you have to build.**

> **Running on an Apple Silicon Mac?** The SQL Server image is amd64 and runs
> under Rosetta. You need **SQL Server 2025 CU1 or later** (the `2025-latest` tag
> in this repo includes it) — CU1 fixed the AVX issue that used to break vector
> operations under emulation. Background:
> [SQL Server 2025 CU1 fixes the Docker Desktop AVX issue](https://www.nocentino.com/posts/2026-02-02-sql-server-2025-cu1-fixes-avx-issue/).

---

## The 30-minute run of show

This repo is the demo. Here's how I pace it for a room that knows AI but not SQL
Server. Everything is pre-built at startup, so nothing makes you wait live.

| Time | What you do | The point you're making |
|---|---|---|
| 0–3 min | Architecture slide + `docker compose ps` | One database does it all — no separate vector DB, no app tier to glue it together. |
| 3–8 min | **Step 2** in `demos/vector-demos.sql`: create the EXTERNAL MODEL, run the single-embedding `SELECT` | "An embedding is a SQL function call. The model is just a named pointer — Ollama today, Azure OpenAI tomorrow, same query." |
| 8–14 min | **Steps 3–5**: the `VECTOR(768)` column, then the OLD keyword/`LIKE` search (watch it whiff on the user's own words), then the kNN search with `VECTOR_DISTANCE` | Show *why* string matching is brittle first, then the same question answered by *meaning* — semantic search over real questions, in T-SQL, matching with zero shared keywords. |
| 14–19 min | **Step 6**: the DiskANN `CREATE VECTOR INDEX` + `VECTOR_SEARCH`, compare the IO stats | This is how it scales — the same DiskANN tech Microsoft runs at billions of vectors. |
| 19–22 min | **Step 7**: the `find_similar_questions` proc + the least-privilege `dab_app` login | "Now I'll hand this to an agent — but only what I choose, and only what this login can touch." |
| 22–29 min | Switch to your AI client. Run the prompts in `demos/agent-demo.md` — semantic search via **DAB MCP**, then the **SQL DBA MCP** bonus act | The payoff: the agent does semantic search *and* DBA triage with **zero SQL**, governed by config + least-privilege logins. |
| 29–30 min | Recap the story | SQL Server 2025 = AI *in* the database. MCP = AI agents *onto* the database — for both its data and its operations. |

---

## Architecture

Ollama runs on the **host** (GPU-accelerated). NGINX adds the TLS that SQL
Server 2025 requires and reverse-proxies to it.

```
   ┌──────────────────────────────────┐
   │  Host Ollama  :11434  (GPU)      │   nomic-embed-text
   └─────────────────▲────────────────┘
                     │ http  (host.docker.internal)
─ docker compose ────┼────────────────────────────────────────────────────────
 │   ┌──────────┐    │ HTTPS (TLS)   ┌───────────────────────────────────┐    │
 │   │ model-web│◄───┴───────────────│  SQL Server 2025   (sql1 :1433)   │    │
 │   │ (nginx)  │   AI_GENERATE_     │  StackOverflow                    │    │
 │   │  :443    │   EMBEDDINGS       │  • VECTOR(768) column             │    │
 │   └──────────┘                    │  • DiskANN vector index           │    │
 │                                   │  • find_similar_questions proc    │    │
 │                                   └──────┬────────────────────┬───────┘    │
 │                     dab_app: SELECT/EXEC │      dba_monitor: VIEW          │
 │                                          │      SERVER STATE  │            │
 │   AI agent  ┌────────────────────────────▼───┐    ┌───────────▼──────────┐ │
 │  ──── MCP ─►│ Data API builder      (dab:5001)│   │ SQL DBA MCP (:3001)  │ │
 │ (Claude/    │ REST · GraphQL · MCP            │   │ ~30 read-only tools  │ │
 │  Copilot)   │ semantic search + catalog       │   │ waits, blocking, …   │ │
 │             └─────────────────────────────────┘   └──────────────────────┘ │
 └────────────────────────────────────────────────────────────────────────────
```

| Service | Purpose | Host port |
|---|---|---|
| `model-web` | NGINX, terminates TLS in front of host Ollama (SQL Server requires HTTPS) | 443 |
| `sql1` | SQL Server 2025 — StackOverflow, vectors, the search proc | 1433 |
| `sql-init` | One-shot: restores the DB and runs `vector-demos.sql`, then exits | — |
| `dab` | Data API builder — exposes the DB over REST, GraphQL, and **MCP** | 5001 |
| `sql-dba-mcp` | Bonus: read-only DBA monitoring MCP server (~30 tools) | 3001 |
| `config` | One-shot helper that generates the NGINX TLS cert | — |

Ollama itself is **not** a container here — it runs on your host so it's
GPU-accelerated and you don't re-download the model into a volume.

---

## Prerequisites

- Docker Desktop or OrbStack (Apple Silicon and x86 both fine)
- **[Ollama](https://ollama.com) installed and running on the host.** `start.sh`
  pulls `nomic-embed-text` for you if it's missing.
- ~8 GB free RAM for the containers
- A SQL client: SSMS, or the [VS Code mssql extension](https://marketplace.visualstudio.com/items?itemName=ms-mssql.mssql)
- An MCP-capable AI client (Claude in VS Code, GitHub Copilot, or Claude Desktop) for the finale

## Quick start

```bash
git clone <your-fork-url> sql2025-ai-faststart
cd sql2025-ai-faststart
./start.sh
```

`start.sh` checks host Ollama, downloads the StackOverflow sample database
(~759 MB, **one time** — too big to commit), then brings up the stack. The first
run restores StackOverflow and embeds a curated set of questions via Ollama — a
couple of minutes. Watch it finish:

```bash
docker compose logs -f sql-init      # this container exits 0 when setup is done
docker compose ps                    # sql1, dab, sql-dba-mcp should be healthy
curl http://localhost:5001/health    # Data API builder
curl http://localhost:3001/health    # SQL DBA MCP server
```

Connect your SQL client to `localhost,1433` as `sa` / `S0methingS@Str0ng!` and
open [demos/vector-demos.sql](demos/vector-demos.sql).

> **Containers can't reach host Ollama?** On Docker Desktop this just works
> (`host.docker.internal` proxies to the host's localhost). On other runtimes,
> make Ollama listen on all interfaces — `launchctl setenv OLLAMA_HOST "0.0.0.0"`
> then restart Ollama — and re-run `./start.sh`.

## The walkthrough

[demos/vector-demos.sql](demos/vector-demos.sql) is the whole story in one
idempotent script. The `sql-init` container runs it for you at startup, and you
re-run the interesting parts live:

| Step | What it shows |
|---|---|
| 0–1 | Enable outbound HTTPS; restore StackOverflow *(setup only — skip live)* |
| 2 | `CREATE EXTERNAL MODEL` pointing at host Ollama; generate one embedding to see what it is |
| 3 | The native `VECTOR(768)` column, on its own dedicated `EMBEDDINGS` filegroup + data file |
| 4 | `AI_GENERATE_EMBEDDINGS` over the top-scored questions in a single `INSERT…SELECT` |
| 5 | First the **old way** — keyword/`LIKE` search and why it's brittle — then exact semantic search (kNN) with `VECTOR_DISTANCE`; watch the table scan |
| 6 | DiskANN `CREATE VECTOR INDEX` + `VECTOR_SEARCH` (ANN) — watch it get cheap |
| 7 | Wrap the search in a stored proc + create the `dab_app` and `dba_monitor` least-privilege logins |

## The payoff — connect AI agents over MCP

This is the part the AI audience cares about. Two MCP servers come up, and this
repo's project-scoped [`.mcp.json`](.mcp.json) pre-wires both for Claude in VS Code:

**`stackoverflow`** — Data API builder reads [dab-config.json](dab-config.json)
and stands up an MCP server at `http://localhost:5001/mcp`:

- **Data tools** over `Questions` (the catalog view) and `Users` (read-only) — the
  agent can filter questions by tag/score/date, then chain from a question's
  `OwnerUserId` to look up who asked it and what their reputation is.
- **`find_similar_questions`** — our semantic-search proc, registered as a *named*
  MCP custom tool (`mcp.custom-tool: true`, new in DAB 2.0). When the user describes
  a problem in plain language, the agent calls this tool; DAB executes the proc;
  SQL Server embeds the query with Ollama and runs vector search. Ranked results,
  zero SQL.

**`sql-dba`** — the SQL DBA MCP server at `http://localhost:3001/mcp` exposes ~30
read-only monitoring tools (wait stats, blocking chains, top queries, missing
indexes, backup/AG health, deadlocks, …) as `dba_monitor`. The agent can triage
"why is this server slow?" the way a DBA would.

If you use **Claude in VS Code**, both servers are already wired — opening the
folder is enough (approve them when Claude prompts, or run `/mcp`). For GitHub
Copilot or Claude Desktop, see [docs/mcp-client-setup.md](docs/mcp-client-setup.md).
Then run the scripted prompts in [demos/agent-demo.md](demos/agent-demo.md).

### What this looks like in practice

> **You:** "I need to get a box dead-center on the page, both horizontally and
> vertically. Any relevant questions?"

```
Agent → find_similar_questions(prompt: "center a box in the middle of the page, both directions", top: 5)
      ← [ { Title: "Best way to center a <div> on a page vertically and horizontally?", Score:  428, distance: 0.34 },
          { Title: "How to horizontally center a <div> in another <div>?",             Score: 3549, distance: 0.34 },
          { Title: "How to align a <div> to the middle of the page",                   Score:  680, distance: 0.35 },
          ... ]

Agent: "The closest match is 'Best way to center a <div> vertically and horizontally?'
        For modern browsers the flexbox approach is simplest — set the parent to
        display:flex with justify-content and align-items both centered..."
```

Notice the user never said "div" or "center," and the agent never wrote SQL. The
match came from the *meaning* of the request, computed by vector search inside
SQL Server and handed back through one MCP tool call.

---

## The new features, at a glance

For the SQL Server 2025 side (all GA except the vector index, which is preview):

| Feature | What it is |
|---|---|
| `VECTOR(n)` data type | A first-class column type for embeddings, stored in optimized binary, exposed as a JSON array |
| `CREATE EXTERNAL MODEL` | A named, swappable pointer to an embedding endpoint (Ollama, Azure OpenAI, OpenAI, local ONNX) |
| `AI_GENERATE_EMBEDDINGS` | A T-SQL function that turns text into a vector inline — no app code |
| `VECTOR_DISTANCE` | Exact (kNN) similarity between two vectors (cosine, euclidean, dot) |
| `CREATE VECTOR INDEX` + `VECTOR_SEARCH` | DiskANN approximate (ANN) search that scales to millions/billions of vectors *(preview)* |

> **What's next for DiskANN (and what differs on Azure SQL):** the vector index has a
> newer "latest-version" form that is GA on **Azure SQL Database / Fabric** (not yet
> in the SQL Server 2025 box). It drops the read-only-after-index limitation (full
> `INSERT`/`UPDATE`/`DELETE`/`MERGE` with live maintenance), applies `WHERE` filters
> *during* the search (iterative filtering), adds `sys.dm_db_vector_indexes` for
> staleness monitoring, and changes the query syntax: `SELECT TOP (N) WITH APPROXIMATE`
> with **no** `TOP_N` (using `TOP_N` against a latest-version index errors with Msg 42274).
> This repo runs on the SQL Server 2025 container, so Step 6 uses the current `TOP_N`
> syntax; `demos/vector-demos.sql` shows the GA form in a comment. See
> [DiskANN vector index improvements](https://devblogs.microsoft.com/azure-sql/diskann-vector-index-improvements/)
> and the [VECTOR_SEARCH docs](https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-search-transact-sql).

For the Data API builder side:

| Feature | What it is |
|---|---|
| Built-in MCP server | One config exposes REST, GraphQL, **and** an MCP endpoint at the same time |
| `mcp.custom-tool` | Register a stored procedure as a named MCP tool (used here for `find_similar_questions`) |
| `description` | Human-readable hints surfaced to the agent during MCP tool discovery |
| Per-entity permissions | The agent only gets the entities and actions you list — governance lives in DAB, not the prompt |

## A note on security

The whole point of the MCP layer is **controlled** agentic access:

- DAB connects as `dab_app`: `SELECT` on a couple of objects and `EXECUTE` on one
  proc. The DBA server connects as `dba_monitor`: `VIEW SERVER STATE` only — it
  reads DMVs, it can't read your data or change anything.
- Every entity is read-only and every DBA tool is read-only. Neither login can
  perform DDL or writes. The agent's reach is exactly what's in `dab-config.json`
  and what the logins are granted — not what the model decides to try.
- The passwords here (`S0methingS@Str0ng!`, `DabP@ss123!`, `MonitorP@ss123!`) are
  throwaway demo values. Change them before this leaves your laptop. The self-signed
  TLS cert is generated once and reused (so NGINX and SQL Server always agree on
  it); it's git-ignored — delete `certs/nginx.crt` + `certs/nginx.key` to mint a
  fresh one.

## Project layout

```
├── docker-compose.yml          # the whole stack, in dependency order
├── dockerfile.ssl              # tiny image that generates the NGINX cert
├── dab-config.json             # Data API builder entities + MCP config  ← the new part
├── .mcp.json                   # pre-wires Claude in VS Code to BOTH MCP servers
├── backups/                    # StackOverflow .bak lands here (downloaded by start.sh, git-ignored)
├── certs/                      # openssl config + generate script (certs are git-ignored)
├── config/
│   └── nginx.conf              # TLS reverse proxy in front of host Ollama
├── demos/
│   ├── vector-demos.sql        # the canonical, idempotent walkthrough (Steps 0–7)
│   └── agent-demo.md           # natural-language prompts to run against the agents
├── docs/
│   ├── mcp-client-setup.md     # wire VS Code / Claude Desktop to the MCP endpoints
│   └── embedding-models.md     # benchmark: why nomic-embed-text, and how to switch
├── sql-dba-mcp/                # the bonus read-only DBA monitoring MCP server (TypeScript)
├── start.sh / stop.sh
└── README.md
```

## Stop / reset

```bash
./stop.sh            # stop, keep data
./stop.sh --wipe     # stop and delete the SQL data volume (clean reset)
```

Host Ollama and the downloaded `.bak` are left alone, so a reset is quick.

## Wrapping up

Two ideas, one stack. SQL Server 2025 pulls AI *into* the database: embeddings
and vector search are just data types and functions next to your business data.
MCP puts your agents *onto* the database: Data API builder turns a schema into
governed semantic-search tools from one config file, and a small DBA server turns
the DMVs into governed monitoring tools. Put them together and an AI agent can do
semantic search over your data *and* triage the server's health — without you
building a vector store, an embedding pipeline, or an API tier.

Clone it, run it, and start poking. Swap `nomic-embed-text` for another model
([docs/embedding-models.md](docs/embedding-models.md) benchmarks the options on
this data), point the EXTERNAL MODEL at Azure OpenAI, expose your own tables in
`dab-config.json`. It's a sandbox — break it and `./stop.sh --wipe` puts it back.

---

## Credits & acknowledgments

- **Data** — the [Stack Exchange / StackOverflow public data dump](https://archive.org/details/stackexchange),
  with content licensed **CC BY-SA**. This repo restores a trimmed *StackOverflowMini* sample for a fast startup.
- **Embeddings** — [Ollama](https://ollama.com) serving [`nomic-embed-text`](https://ollama.com/library/nomic-embed-text)
  (the default), with [`mxbai-embed-large`](https://ollama.com/library/mxbai-embed-large) as the higher-accuracy option.
- **In the database** — SQL Server 2025's native `VECTOR` type, `AI_GENERATE_EMBEDDINGS`, and the DiskANN `VECTOR_SEARCH` index.
- **The agent layer** — [Data API builder](https://learn.microsoft.com/azure/data-api-builder/) and its built-in MCP server.
- Grown from two earlier demos: [ollama-sql-faststart](https://github.com/nocentino/ollama-sql-faststart) and the SQL DBA MCP server.
- Built and maintained by [Anthony E. Nocentino](https://www.nocentino.com) ([@nocentino](https://github.com/nocentino)).

**Topics:** `sql-server` · `sql-server-2025` · `vector-search` · `embeddings` · `diskann` · `semantic-search` · `mcp` · `model-context-protocol` · `data-api-builder` · `ollama` · `rag` · `ai-agents` · `t-sql` · `docker`
