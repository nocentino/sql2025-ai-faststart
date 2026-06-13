# SQL Server 2025 AI FastStart

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
> Docker Desktop or OrbStack both work.

---

## The 30-minute run of show

This repo is the demo. Here's how I pace it for a room that knows AI but not SQL
Server. Everything is pre-built at startup, so nothing makes you wait live.

| Time | What you do | The point you're making |
|---|---|---|
| 0–3 min | Architecture slide + `docker compose ps` | One database does it all — no separate vector DB, no app tier to glue it together. |
| 3–8 min | **Step 2** in `demos/vector-demos.sql`: create the EXTERNAL MODEL, run the single-embedding `SELECT` | "An embedding is a SQL function call. The model is just a named pointer — Ollama today, Azure OpenAI tomorrow, same query." |
| 8–14 min | **Steps 3–5**: show the `VECTOR(768)` column + the kNN search with `VECTOR_DISTANCE` | Semantic search over business data, in T-SQL. Note it never matches the literal words. |
| 14–19 min | **Step 6**: the DiskANN `CREATE VECTOR INDEX` + `VECTOR_SEARCH`, compare the IO stats | This is how it scales — the same DiskANN tech Microsoft runs at billions of vectors. |
| 19–22 min | **Step 7**: the `find_similar_products` proc + the least-privilege `dab_app` login | "Now I'll hand this to an agent — but only what I choose, and only what this login can touch." |
| 22–29 min | Switch to your AI client. Run the prompts in `demos/agent-demo.md` against the **DAB MCP** endpoint | The payoff: the agent does semantic search and answers data questions with **zero SQL**, governed by DAB. |
| 29–30 min | Recap the two-feature story | SQL Server 2025 = AI *in* the database. DAB MCP = AI agents *onto* the database. |

---

## Architecture

```
                          docker compose network
  ┌───────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │   ┌──────────┐     pull      ┌──────────────┐                           │
  │   │  ollama  │◄──────────────│ model-puller │  (nomic-embed-text)       │
  │   │  :11434  │               └──────────────┘                           │
  │   └────┬─────┘                                                          │
  │        │ http                                                           │
  │   ┌────▼─────┐   HTTPS (TLS)   ┌──────────────────────────────────┐     │
  │   │ model-web│◄────────────────│  SQL Server 2025   (sql1 :1433)  │     │
  │   │ (nginx)  │  AI_GENERATE_   │  AdventureWorksLT                │     │
  │   │  :443    │  EMBEDDINGS     │  • VECTOR(768) column            │     │
  │   └──────────┘                 │  • DiskANN vector index          │     │
  │                                │  • find_similar_products proc    │     │
  │                                └───────────────┬──────────────────┘     │
  │                                                │ SELECT / EXECUTE        │
  │                                                │ (as least-priv dab_app) │
  │                                ┌───────────────▼──────────────────┐     │
  │   AI agent  ───── MCP ────────►│  Data API builder   (dab :5001)  │     │
  │  (Claude / Copilot)            │  REST  •  GraphQL  •  MCP        │     │
  │                                └──────────────────────────────────┘     │
  └───────────────────────────────────────────────────────────────────────┘
```

| Service | Purpose | Host port |
|---|---|---|
| `ollama` | Serves the `nomic-embed-text` embedding model locally | 11434 |
| `model-web` | NGINX, terminates TLS in front of Ollama (SQL Server requires HTTPS) | 443 |
| `sql1` | SQL Server 2025 — AdventureWorksLT, vectors, the search proc | 1433 |
| `sql-init` | One-shot: restores the DB and runs `vector-demos.sql`, then exits | — |
| `dab` | Data API builder — exposes the DB over REST, GraphQL, and **MCP** | 5001 |
| `config` / `model-puller` | One-shot helpers (cert generation, model pull) | — |

---

## Prerequisites

- Docker Desktop or OrbStack (Apple Silicon and x86 both fine)
- ~8 GB free RAM for the containers
- A SQL client: [Azure Data Studio](https://learn.microsoft.com/en-us/azure-data-studio/),
  SSMS, or the [VS Code mssql extension](https://marketplace.visualstudio.com/items?itemName=ms-mssql.mssql)
- An MCP-capable AI client (VS Code + GitHub Copilot, or Claude Desktop) for the finale

## Quick start

```bash
git clone <your-fork-url> sql2025-ai-faststart
cd sql2025-ai-faststart
./start.sh
```

That's it. The first run pulls images, restores AdventureWorksLT, and embeds the
whole product catalog with Ollama — a few minutes. Watch it finish:

```bash
docker compose logs -f sql-init      # this container exits 0 when setup is done
docker compose ps                    # sql1 + dab should be healthy
curl http://localhost:5001/health    # Data API builder
```

Connect your SQL client to `localhost,1433` as `sa` / `S0methingS@Str0ng!` and
open [demos/vector-demos.sql](demos/vector-demos.sql).

## The walkthrough

[demos/vector-demos.sql](demos/vector-demos.sql) is the whole story in one
idempotent script. The `sql-init` container runs it for you at startup, and you
re-run the interesting parts live:

| Step | What it shows |
|---|---|
| 0–1 | Enable outbound HTTPS; restore AdventureWorksLT *(setup only — skip live)* |
| 2 | `CREATE EXTERNAL MODEL` pointing at Ollama; generate one embedding to see what it is |
| 3 | The native `VECTOR(768)` column |
| 4 | `AI_GENERATE_EMBEDDINGS` over the catalog in a single `INSERT…SELECT` |
| 5 | Exact semantic search (kNN) with `VECTOR_DISTANCE` — watch the table scan |
| 6 | DiskANN `CREATE VECTOR INDEX` + `VECTOR_SEARCH` (ANN) — watch it get cheap |
| 7 | Wrap the search in a stored proc + create the least-privilege `dab_app` login |

## The payoff — connect an AI agent over MCP

This is the part the AI audience cares about. Data API builder reads
[dab-config.json](dab-config.json) and stands up an MCP server at
`http://localhost:5001/mcp`. Two kinds of tools show up automatically:

- **Data tools** over `Products`, `ProductCategories`, `Customers`,
  `SalesOrders`, and `SalesOrderDetails` (read-only here) — the agent can browse
  and filter the catalog and orders without writing SQL.
- **`FindSimilarProducts`** — our semantic-search proc, registered as a *named*
  MCP custom tool (`mcp.custom-tool: true`, new in DAB 2.0). When the user
  describes what they want in plain language, the agent calls this tool; DAB
  executes the proc; SQL Server embeds the query with Ollama and runs vector
  search. The agent gets ranked results and never sees a line of SQL.

Wire up your client with [docs/mcp-client-setup.md](docs/mcp-client-setup.md),
then run the scripted prompts in [demos/agent-demo.md](demos/agent-demo.md).

### What this looks like in practice

> **You:** "I want a comfortable bike for long weekend rides, nothing too pricey.
> What do you suggest?"

```
Agent → FindSimilarProducts(prompt: "comfortable bike for long rides, affordable", top: 5)
      ← [ { Name: "Touring-3000 Blue, 58",  ListPrice: 742.35, distance: 0.21 },
          { Name: "Touring-1000 Yellow, 60", ListPrice: 2384.07, distance: 0.24 },
          ... ]

Agent: "For comfortable long-distance riding the Touring series is your best fit.
        The Touring-3000 is the value pick at $742 — built for endurance rather
        than speed. If budget is flexible, the Touring-1000 is lighter..."
```

Notice the user never said "Touring," and the agent never wrote SQL. The match
came from the *meaning* of the request, computed by vector search inside SQL
Server and handed back through one MCP tool call.

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

For the Data API builder side:

| Feature | What it is |
|---|---|
| Built-in MCP server | One config exposes REST, GraphQL, **and** an MCP endpoint at the same time |
| `mcp.custom-tool` | Register a stored procedure as a named MCP tool (used here for `FindSimilarProducts`) |
| `object-description` / `description` | Human-readable hints surfaced to the agent during MCP tool discovery |
| Per-entity permissions | The agent only gets the entities and actions you list — governance lives in DAB, not the prompt |

## A note on security

The whole point of the DAB layer is **controlled** agentic access:

- DAB connects as `dab_app`, a login with `SELECT` on a handful of catalog
  objects and `EXECUTE` on one proc. No server-level rights, no DDL, nothing
  else. The agent cannot reach what `dab_app` can't.
- The entities are read-only in this demo. Flip an action in `dab-config.json`
  to allow writes — the guardrails are in config, version-controlled.
- The passwords here (`S0methingS@Str0ng!`, `DabP@ss123!`) are throwaway demo
  values. Change them before this leaves your laptop. The self-signed TLS certs
  are generated fresh on every start and are git-ignored.

## Project layout

```
├── docker-compose.yml          # the whole stack, in dependency order
├── dockerfile.ssl              # tiny image that generates the NGINX cert
├── dab-config.json             # Data API builder entities + MCP config  ← the new part
├── backups/
│   └── AdventureWorks2025_FULL.bak
├── certs/                      # openssl config + generate script (certs are git-ignored)
├── config/
│   └── nginx.conf              # TLS reverse proxy in front of Ollama
├── demos/
│   ├── vector-demos.sql        # the canonical, idempotent walkthrough (Steps 0–7)
│   └── agent-demo.md           # natural-language prompts to run against the agent
├── docs/
│   └── mcp-client-setup.md     # wire VS Code / Claude Desktop to the DAB MCP endpoint
├── start.sh / stop.sh
└── README.md
```

## Stop / reset

```bash
./stop.sh            # stop, keep data
./stop.sh --wipe     # stop and delete SQL data + Ollama models (clean reset)
```

## Wrapping up

Two ideas, one stack. SQL Server 2025 pulls AI *into* the database: embeddings
and vector search are just data types and functions next to your business data.
Data API builder puts your agents *onto* the database: one config file turns a
schema into governed MCP tools. Put them together and an AI agent can do semantic
search over your operational data without you building a vector store, an
embedding pipeline, or an API tier.

Clone it, run it, and start poking. Swap `nomic-embed-text` for another model,
point the EXTERNAL MODEL at Azure OpenAI, expose your own tables in
`dab-config.json`. It's a sandbox — break it and `./stop.sh --wipe` puts it back.
