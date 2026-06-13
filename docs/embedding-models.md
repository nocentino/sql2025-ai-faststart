# Choosing an embedding model

The demo embeds StackOverflow **question text (title + tags)** and searches it
semantically. This note records a head-to-head benchmark of Ollama embedding
models **on this exact data**, so the model choice is evidence-based rather than
leaderboard-based. Run on 2026-06-13.

**TL;DR:** the demo ships with **`nomic-embed-text`** — it's the fastest and,
on this data, within a hair of the best. **`mxbai-embed-large`** is the most
accurate (a clear win on ambiguous queries) at a small speed cost and a larger
vector; switch to it if you want maximum quality. **`embeddinggemma`** was both
the slowest and the weakest here — skip it.

## How it was tested

- **Engine / path:** SQL Server 2025 (CU5 container) → NGINX(TLS) → **host Ollama**
  (GPU-accelerated). Each model registered as a `CREATE EXTERNAL MODEL` and called
  with `AI_GENERATE_EMBEDDINGS`.
- **Corpus:** the same top **1,000** questions by score (title + cleaned tags),
  embedded separately by each model.
- **Speed:** average wall-clock of 20 warm single embeds (the live-query path),
  plus a 1,000-row bulk `INSERT…SELECT` (the startup path).
- **Accuracy:** representative natural-language queries; for each, the nearest
  question per model by `VECTOR_DISTANCE('cosine', …)`. Lower distance = closer
  match; the title shows whether it's actually relevant.

## Candidates

| Model | Dims | Size | Notes |
|---|---|---|---|
| `nomic-embed-text` *(current default)* | 768 | 274 MB | Fast, popular general-purpose retriever |
| `mxbai-embed-large` | 1024 | 669 MB | Strong English retrieval |
| `embeddinggemma` | 768 | 621 MB | Google, 2025; strong-for-size reputation |
| `qwen3-embedding` *(not tested)* | 1024+ | 0.6B–8B | SOTA on MTEB, but larger/slower — overkill for a demo |

## Speed (host GPU)

| Model | Single embed (warm) | Bulk 1,000 rows |
|---|---|---|
| `nomic-embed-text` | **~20 ms** | ~7 s |
| `mxbai-embed-large` | ~28 ms | ~13 s |
| `embeddinggemma` | ~74 ms | ~12 s |

All are fast enough for the demo; single-embed latency matters most for the live
query path. `embeddinggemma` is ~3.7× slower per call than nomic.

## Accuracy (same 1,000-question corpus)

Lower cosine distance = closer. ✓ = relevant top hit, ✗ = off-target. **Bold** =
best result for that query.

| Query | `nomic` (768) | `mxbai` (1024) | `embeddinggemma` (768) |
|---|---|---|---|
| how do I undo a git commit | undo recent commits `0.112` | **undo recent commits `0.128`** | undo `--amend` `0.149` |
| how do javascript closures work | ✓ `0.143` | **✓ `0.083`** | ✓ `0.112` |
| get a box in the middle of the page | ✓ `0.374` | **✓ `0.278`** | ✓ `0.433` |
| iterate over a dictionary in python | ✓ `0.180` | **✓ `0.137`** | ✓ `0.275` |
| why is my code throwing a null reference error | ✓ "Avoiding != null" `0.306` | **✓ "Avoiding != null" `0.238`** | ✗ "pass by reference" `0.359` |
| read a file line by line | ✗ "line count" `0.335` | **✓ "looping through a file" `0.305`** | ✗ "line count" `0.343` |
| prevent SQL injection in my queries | ✓ `0.138` | ✓ `0.138` | ✓ `0.177` |

## Verdict

- **`mxbai-embed-large` — best accuracy.** Same-or-better top hit on every query,
  consistently tighter distances (more confident separation), and the only model
  that got the two "trap" queries right: *null reference* (gemma was fooled by the
  word "reference") and *read a file line by line* (only mxbai found the actual
  line-by-line answer instead of "line count"). Cost: ~40% slower per embed (still
  fast) and **1024-dim** → ~33% larger vector column + index.
- **`nomic-embed-text` — best speed, and very close on quality.** The shipped
  default. Keeps the schema at `VECTOR(768)`.
- **`embeddinggemma` — skip for this data.** Slowest *and* weakest here.
- **`qwen3-embedding` — if you want to chase max accuracy** (multilingual, SOTA),
  but it's larger/slower; not needed for English developer Q&A.

The demo keeps **`nomic-embed-text`**: fastest, 768-dim (no schema change), and the
quality gap to mxbai is small on this data.

## Switching to `mxbai-embed-large`

If you want the accuracy win, it's a small change:

1. `start.sh` — pull it on the host: `ollama pull mxbai-embed-large`.
2. `demos/vector-demos.sql`:
   - Step 2: `CREATE EXTERNAL MODEL ollama … MODEL = 'mxbai-embed-large'`.
   - Step 3: `embeddings VECTOR(768)` → `VECTOR(1024)`.
   - Step 7: the proc's `DECLARE @qv VECTOR(768)` → `VECTOR(1024)`.
3. Re-run `sql-init` (re-embeds and rebuilds `vec_idx` at the new dimension).

The `VECTOR(n)` dimension must match the model's output exactly (768 for nomic /
embeddinggemma, 1024 for mxbai), or `AI_GENERATE_EMBEDDINGS` assignment fails.

## Reproducing the benchmark

Register a model and embed the same corpus into a scratch table:

```sql
CREATE EXTERNAL MODEL emb_mxbai
WITH (LOCATION = 'https://model-web:443/api/embed', API_FORMAT = 'Ollama',
      MODEL_TYPE = EMBEDDINGS, MODEL = 'mxbai-embed-large');
GO
CREATE TABLE dbo.qe_mxbai (PostId INT PRIMARY KEY, embeddings VECTOR(1024));
;WITH t AS (
    SELECT TOP (1000) p.Id,
        p.Title + N' ' + REPLACE(REPLACE(REPLACE(ISNULL(p.Tags,N''),N'><',N' '),N'<',N''),N'>',N'') AS chunk
    FROM dbo.Posts p WHERE p.PostTypeId = 1 AND p.Title IS NOT NULL ORDER BY p.Score DESC)
INSERT dbo.qe_mxbai (PostId, embeddings)
SELECT t.Id, AI_GENERATE_EMBEDDINGS(t.chunk USE MODEL emb_mxbai) FROM t;
```

Then compare the nearest match for a query:

```sql
DECLARE @qv VECTOR(1024) = AI_GENERATE_EMBEDDINGS(N'how do I undo a git commit' USE MODEL emb_mxbai);
SELECT TOP (3) p.Title, VECTOR_DISTANCE('cosine', @qv, e.embeddings) AS distance
FROM dbo.qe_mxbai e JOIN dbo.Posts p ON e.PostId = p.Id
ORDER BY distance;
```

(Scratch `qe_*` tables and `emb_*` models live in the `StackOverflow` database, so
re-running `sql-init` — which drops and restores it — cleans them up.)

## Sources

- [DiskANN vector index improvements (Azure SQL devblog)](https://devblogs.microsoft.com/azure-sql/diskann-vector-index-improvements/)
- [Best Ollama Embedding Models 2026 (MTEB / VRAM / dims)](https://www.morphllm.com/ollama-embedding-models)
- [Best Embedding Model for RAG 2026 — Milvus](https://milvus.io/blog/choose-embedding-model-rag-2026.md)
- [Qwen3 Embedding (arXiv)](https://arxiv.org/pdf/2506.05176)
