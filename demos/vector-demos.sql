/* =============================================================================
   SQL Server 2025 AI FastStart — the whole story in one script
   =============================================================================

   This single script is run automatically when the stack starts (the `sql-init`
   container executes it), and it is ALSO the script you walk through live during
   the talk. It is idempotent, so re-running any section is safe.

   The data is the StackOverflow public dataset — real developer questions, which
   makes semantic search land for an AI audience: searching by *meaning*, not
   keywords, over text everyone in the room recognizes.

   The arc, for an audience that knows AI but not SQL Server:

       Step 0-1  Get a normal relational database (StackOverflow) online.
       Step 2    Point SQL Server at a local embedding model (host Ollama).
       Step 3-4  Turn question text into vectors and store them IN the database.
       Step 5    Semantic search with a SQL function (exact / kNN).
       Step 6    Make it fast at scale with a DiskANN vector index (ANN).
       Step 7    Hand the database to AI agents over MCP (Data API builder + the
                 SQL DBA MCP server).

   Connect with SSMS / the VS Code mssql extension:
       Server:   localhost,1433
       Login:    sa
       Password: S0methingS@Str0ng!     (demo only)

   LIVE-DEMO TIP: Steps 0, 1 and the bulk generation in Step 4 already ran at
   startup. During the talk, SKIP Step 1 (it disconnects everything to restore)
   and focus on Steps 2, 4 (single embedding), 5, 6, and 7 — those are the ones
   the audience wants to see.
   ============================================================================= */

-- Required for CREATE VECTOR INDEX (Step 6) and so the stored procedure (Step 7)
-- is compiled with the right settings. SSMS set these ON by
-- default, but sqlcmd (which runs this script at startup) defaults QUOTED_IDENTIFIER
-- OFF — without this the DiskANN index creation fails with Msg 1934.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/* -----------------------------------------------------------------------------
   STEP 0  —  Let SQL Server make outbound HTTPS calls   [SETUP — runs once]
   -----------------------------------------------------------------------------
   SQL Server 2025 can call an external AI model to generate embeddings. That is
   an outbound REST call, so we enable it at the server level. (Done for you at
   startup; shown here so you can see the switch.)
----------------------------------------------------------------------------- */
EXEC sp_configure 'external rest endpoint enabled', 1;
GO
RECONFIGURE WITH OVERRIDE;
GO


/* -----------------------------------------------------------------------------
   STEP 1  —  Restore StackOverflow   [SETUP — SKIP during a live demo]
   -----------------------------------------------------------------------------
   The StackOverflowMini sample database: ~400K questions, ~1.16M answers, plus
   Users, Comments, Votes, Badges. The point of the whole demo is that you do NOT
   need a separate vector database — your operational data and its embeddings live
   side by side in the same tables.

   WARNING: SET SINGLE_USER disconnects everyone (Data API builder, the DBA MCP
   server). Only run this to reset to a clean state.
----------------------------------------------------------------------------- */
USE [master];
GO
IF DB_ID('StackOverflow') IS NOT NULL
    ALTER DATABASE [StackOverflow] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
RESTORE DATABASE [StackOverflow]
FROM DISK = '/var/opt/mssql/backups/StackOverflowMini.bak'
WITH
    MOVE 'StackOverflowMini'     TO '/var/opt/mssql/data/StackOverflow.mdf',
    MOVE 'StackOverflowMini_log' TO '/var/opt/mssql/data/StackOverflow_log.ldf',
    REPLACE,
    NOUNLOAD,
    STATS = 25;
GO
ALTER DATABASE [StackOverflow] SET MULTI_USER;
GO


/* -----------------------------------------------------------------------------
   STEP 2  —  Register the local embedding model   [run this live]
   -----------------------------------------------------------------------------
   An EXTERNAL MODEL is a named pointer to an embedding endpoint. Here it points
   at Ollama running on your HOST (GPU-accelerated), serving `nomic-embed-text`
   (768-dimension vectors).

   The LOCATION is HTTPS because SQL Server 2025 only calls embedding endpoints
   over TLS — that is why there is an NGINX proxy in front of Ollama, and why we
   mounted its certificate into SQL Server's trusted store. NGINX terminates TLS
   and forwards to host Ollama at host.docker.internal:11434.

   Swap this one object for Azure OpenAI or OpenAI and every query below keeps
   working unchanged — the model is an implementation detail.
----------------------------------------------------------------------------- */
USE [StackOverflow];
GO
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'ollama')
    DROP EXTERNAL MODEL ollama;
GO
CREATE EXTERNAL MODEL ollama
WITH (
    LOCATION   = 'https://model-web:443/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'nomic-embed-text'
);
GO

-- Smoke test: turn a string into a vector. This calls Ollama and returns a
-- 768-number array. THIS is an embedding.
SELECT AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit' USE MODEL ollama) AS sample_embedding;
GO


/* -----------------------------------------------------------------------------
   STEP 3  —  A place to store the vectors   [SETUP — safe to re-run]
   -----------------------------------------------------------------------------
   VECTOR(768) is a native SQL Server 2025 data type — not a string, not JSON, a
   first-class column type. `chunk` holds the human-readable text we embedded (the
   question title + its tags), so we can see what each vector actually represents.
----------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.QuestionEmbeddings', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.QuestionEmbeddings
    (
        PostId     INT PRIMARY KEY,
        embeddings VECTOR(768),
        chunk      NVARCHAR(4000)
    );
END
GO


/* -----------------------------------------------------------------------------
   STEP 4  —  Generate the embeddings   [bulk insert is SETUP; single call is live]
   -----------------------------------------------------------------------------
   StackOverflow has ~400K questions — far more than we need for a demo, so we
   embed the top 2,000 by Score (the questions everyone recognizes). For each one
   we build a short "chunk" from its title + tags, then call AI_GENERATE_EMBEDDINGS
   to turn that text into a vector — all in one INSERT...SELECT. No app code, no
   ETL pipeline, no separate vector store. SQL Server does the AI call inline.

   Guarded so the bulk generation only runs once (at startup). To watch it run
   live, TRUNCATE dbo.QuestionEmbeddings first.
----------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.QuestionEmbeddings)
BEGIN
    ;WITH top_questions AS (
        SELECT TOP (2000)
            p.Id,
            -- Title + cleaned tags, e.g. "How do JavaScript closures work? javascript function scope"
            p.Title + N' ' +
                REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'') AS chunk
        FROM dbo.Posts p
        WHERE p.PostTypeId = 1          -- questions only
          AND p.Title IS NOT NULL
        ORDER BY p.Score DESC
    )
    INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
    SELECT
        q.Id,
        q.chunk,
        AI_GENERATE_EMBEDDINGS(q.chunk USE MODEL ollama) AS embeddings
    FROM top_questions q;
END
GO

-- Look at what we built: the text, and the vector stored alongside it.
SELECT TOP (5) qe.PostId, p.Title, qe.chunk, qe.embeddings
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id;
GO


/* -----------------------------------------------------------------------------
   STEP 5  —  Semantic search, the exact way (kNN)   [run this live]
   -----------------------------------------------------------------------------
   Embed the user's natural-language question, then rank every stored question by
   how close its vector is to the query's vector. VECTOR_DISTANCE('cosine', ...)
   does the math. "Closer" means "more semantically similar" — notice the results
   come back even when they share NO keywords with the query.

   Turn on statistics so you can SEE this is a full scan of the table — fine for
   2,000 rows, but it would not scale to millions. That sets up Step 6.
----------------------------------------------------------------------------- */
SET STATISTICS TIME ON;
SET STATISTICS IO ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess, how do I clean it up?';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

SELECT TOP (5)
    p.Id,
    p.Title,
    p.Score,
    p.AnswerCount,
    VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
ORDER BY distance;     -- smallest distance = best match
GO
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO


/* -----------------------------------------------------------------------------
   STEP 6  —  Make it scale with a DiskANN vector index (ANN)   [run this live]
   -----------------------------------------------------------------------------
   Approximate Nearest Neighbor search trades a tiny bit of accuracy for a huge
   speed win. SQL Server 2025 builds the index with DiskANN — the same algorithm
   Microsoft uses at massive scale. Vector indexes are a preview feature, so we
   opt in at the database level first.
----------------------------------------------------------------------------- */
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'vec_idx' AND object_id = OBJECT_ID('dbo.QuestionEmbeddings'))
    DROP INDEX vec_idx ON dbo.QuestionEmbeddings;
GO
CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann', maxdop = 8);
GO

-- Same question as Step 5, but now through VECTOR_SEARCH, which uses the index.
-- Compare the IO/time against Step 5: an index seek instead of a full scan.
SET STATISTICS TIME ON;
SET STATISTICS IO ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess, how do I clean it up?';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

SELECT t.PostId, p.Title, s.distance, p.Score
FROM VECTOR_SEARCH(
        TABLE      = dbo.QuestionEmbeddings AS t,
        COLUMN     = [embeddings],
        SIMILAR_TO = @search_vector,
        METRIC     = 'cosine',
        TOP_N      = 10
     ) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
GO
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO


/* =============================================================================
   STEP 7  —  Hand the database to AI agents   [SETUP — the payoff]
   =============================================================================
   Everything above is SQL. Now we expose it so AI agents (Claude, GitHub Copilot,
   anything that speaks MCP) can use it WITHOUT writing any SQL. Two MCP surfaces:

     (a) Data API builder — a clean question view + a semantic-search stored
         procedure, so the agent gets semantic search as a single callable tool.
     (b) A least-privilege login (dab_app) that Data API builder connects as. It
         can read a few objects and EXECUTE the search proc — and nothing else.

   We also create dba_monitor, the read-only login the SQL DBA MCP server uses to
   expose fleet-monitoring tools (wait stats, blocking, top queries, …).
   ============================================================================= */

-- (a1) A tidy, agent-friendly question view — only useful columns, tags cleaned up.
USE [StackOverflow];
GO
CREATE OR ALTER VIEW dbo.vQuestions AS
SELECT
    p.Id,
    p.Title,
    REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), '><', ', '), '<', ''), '>', '') AS Tags,
    p.Score,
    p.ViewCount,
    p.AnswerCount,
    p.CreationDate
FROM dbo.Posts p
WHERE p.PostTypeId = 1;
GO

-- (a2) Semantic search as a stored procedure. This is the kNN query from Step 5,
--      parameterized. It returns only scalar columns (no VECTOR column), which
--      keeps it clean for Data API builder to expose. Exact search is plenty fast
--      for this set and avoids a preview-feature dependency in the agent path.
CREATE OR ALTER PROCEDURE dbo.find_similar_questions
    @prompt NVARCHAR(MAX),
    @top    INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(@prompt USE MODEL ollama);

    SELECT TOP (@top)
        p.Id,
        p.Title,
        REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), '><', ', '), '<', ''), '>', '') AS Tags,
        p.Score,
        p.ViewCount,
        p.AnswerCount,
        VECTOR_DISTANCE('cosine', @qv, qe.embeddings) AS distance
    FROM dbo.QuestionEmbeddings qe
    JOIN dbo.Posts p ON qe.PostId = p.Id
    ORDER BY distance;
END
GO

-- Try the proc directly, the same way Data API builder will call it for the agent:
EXEC dbo.find_similar_questions @prompt = N'how do I center a div in css', @top = 5;
GO

-- (b) Least-privilege login for Data API builder.
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'dab_app')
    CREATE LOGIN dab_app WITH PASSWORD = 'DabP@ss123!',   -- demo only
        CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF;
GO
USE [StackOverflow];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'dab_app')
    CREATE USER dab_app FOR LOGIN dab_app;
GO
-- Read access to the objects we expose, EXECUTE on the search proc, and EXECUTE on
-- the external model (so the proc can generate the query embedding). Nothing else.
GRANT SELECT  ON dbo.vQuestions             TO dab_app;
GRANT SELECT  ON dbo.Posts                  TO dab_app;  -- joined inside the proc
GRANT SELECT  ON dbo.Users                  TO dab_app;
GRANT SELECT  ON dbo.QuestionEmbeddings     TO dab_app;  -- read inside the proc
GRANT EXECUTE ON dbo.find_similar_questions TO dab_app;
GRANT EXECUTE ON EXTERNAL MODEL::ollama     TO dab_app;
GO

-- (c) Read-only monitoring login for the SQL DBA MCP server. VIEW SERVER STATE is
--     the standard "let a DBA tool read the DMVs" grant — no data access, no DDL.
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'dba_monitor')
    CREATE LOGIN dba_monitor WITH PASSWORD = 'MonitorP@ss123!',   -- demo only
        CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF;
GO
GRANT VIEW SERVER STATE   TO dba_monitor;   -- the DMVs (waits, sessions, IO, memory, …)
GRANT VIEW ANY DATABASE   TO dba_monitor;   -- sys.master_files and cross-DB queries
GRANT VIEW ANY DEFINITION TO dba_monitor;   -- sys.databases, sys.indexes, plans, …
GO
USE [StackOverflow];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'dba_monitor')
    CREATE USER dba_monitor FOR LOGIN dba_monitor;
GO
GRANT VIEW DATABASE STATE TO dba_monitor;
GRANT VIEW DEFINITION     TO dba_monitor;
GO
-- msdb access so the backup-status / job-status tools can read history.
USE [msdb];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'dba_monitor')
    CREATE USER dba_monitor FOR LOGIN dba_monitor;
GO
ALTER ROLE db_datareader ADD MEMBER dba_monitor;
GO

PRINT 'Setup complete. StackOverflow is vectorized and exposed to Data API builder + the SQL DBA MCP server.';
GO
