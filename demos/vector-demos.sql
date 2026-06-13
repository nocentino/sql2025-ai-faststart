/* =============================================================================
   SQL Server 2025 AI FastStart — the whole story in one script
   =============================================================================

   This single script is run automatically when the stack starts (the `sql-init`
   container executes it), and it is ALSO the script you walk through live during
   the talk. It is idempotent, so re-running any section is safe.

   The arc, for an audience that knows AI but not SQL Server:

       Step 0-1  Get a normal relational database (AdventureWorksLT) online.
       Step 2    Point SQL Server at a local embedding model (Ollama).
       Step 3-4  Turn product text into vectors and store them IN the database.
       Step 5    Semantic search with a SQL function (exact / kNN).
       Step 6    Make it fast at scale with a DiskANN vector index (ANN).
       Step 7    Hand the database to an AI agent over MCP via Data API builder.

   Connect with SSMS / Azure Data Studio / the VS Code mssql extension:
       Server:   localhost,1433
       Login:    sa
       Password: S0methingS@Str0ng!     (demo only)

   LIVE-DEMO TIP: Steps 0, 1 and the bulk generation in Step 4 already ran at
   startup. During the talk, SKIP Step 1 (it disconnects everything to restore)
   and focus on Steps 2, 4 (single embedding), 5, 6, and 7 — those are the ones
   the audience wants to see.
   ============================================================================= */


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
   STEP 1  —  Restore AdventureWorksLT   [SETUP — SKIP during a live demo]
   -----------------------------------------------------------------------------
   A plain, boring relational sample database. The point of the whole demo is
   that you do NOT need a separate vector database — your operational data and
   its embeddings live side by side in the same tables.

   WARNING: SET SINGLE_USER disconnects everyone (including Data API builder).
   Only run this to reset to a clean state.
----------------------------------------------------------------------------- */
USE [master];
GO
IF DB_ID('AdventureWorksLT') IS NOT NULL
    ALTER DATABASE [AdventureWorksLT] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
RESTORE DATABASE [AdventureWorksLT]
FROM DISK = '/var/opt/mssql/backups/AdventureWorks2025_FULL.bak'
WITH
    MOVE 'AdventureWorksLT2022_Data' TO '/var/opt/mssql/data/AdventureWorksLT_Data.mdf',
    MOVE 'AdventureWorksLT2022_Log'  TO '/var/opt/mssql/data/AdventureWorksLT_log.ldf',
    FILE = 1,
    NOUNLOAD,
    STATS = 5,
    REPLACE;
GO
ALTER DATABASE [AdventureWorksLT] SET MULTI_USER;
GO


/* -----------------------------------------------------------------------------
   STEP 2  —  Register the local embedding model   [run this live]
   -----------------------------------------------------------------------------
   An EXTERNAL MODEL is a named pointer to an embedding endpoint. Here it points
   at Ollama, running in a container right next to SQL Server, serving the
   `nomic-embed-text` model (768-dimension vectors).

   The LOCATION is HTTPS because SQL Server 2025 only calls embedding endpoints
   over TLS — that is why there is an NGINX proxy in front of Ollama, and why we
   mounted its certificate into SQL Server's trusted store.

   Swap this one object for Azure OpenAI or OpenAI and every query below keeps
   working unchanged — the model is an implementation detail.
----------------------------------------------------------------------------- */
USE [AdventureWorksLT];
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
SELECT AI_GENERATE_EMBEDDINGS(N'a fast red road bike' USE MODEL ollama) AS sample_embedding;
GO


/* -----------------------------------------------------------------------------
   STEP 3  —  A place to store the vectors   [SETUP — safe to re-run]
   -----------------------------------------------------------------------------
   VECTOR(768) is a native SQL Server 2025 data type — not a string, not JSON, a
   first-class column type. `chunk` holds the human-readable text we embedded, so
   we can see what each vector actually represents.
----------------------------------------------------------------------------- */
IF OBJECT_ID('SalesLT.ProductEmbeddings', 'U') IS NULL
BEGIN
    CREATE TABLE SalesLT.ProductEmbeddings
    (
        ProductID  INT PRIMARY KEY,
        embeddings VECTOR(768),
        chunk      NVARCHAR(2000)
    );
END
GO


/* -----------------------------------------------------------------------------
   STEP 4  —  Generate the embeddings   [bulk insert is SETUP; single call is live]
   -----------------------------------------------------------------------------
   For each product we build a short text description ("chunk") from its name,
   color, category, model, and description, then call AI_GENERATE_EMBEDDINGS to
   turn that text into a vector — all in one INSERT...SELECT. No app code, no ETL
   pipeline, no separate vector store. SQL Server does the AI call inline.

   Guarded so the bulk generation only runs once (at startup). To watch it run
   live, TRUNCATE SalesLT.ProductEmbeddings first.
----------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM SalesLT.ProductEmbeddings)
BEGIN
    INSERT INTO SalesLT.ProductEmbeddings (ProductID, chunk, embeddings)
    SELECT
        p.ProductID,
        p.Name + ' ' + ISNULL(p.Color, 'No Color') + ' ' + c.Name + ' ' + m.Name + ' ' + ISNULL(d.Description, '') AS chunk,
        AI_GENERATE_EMBEDDINGS(
            p.Name + ' ' + ISNULL(p.Color, 'No Color') + ' ' + c.Name + ' ' + m.Name + ' ' + ISNULL(d.Description, '')
            USE MODEL ollama) AS embeddings
    FROM SalesLT.Product p
    JOIN SalesLT.ProductCategory c ON p.ProductCategoryID = c.ProductCategoryID
    JOIN SalesLT.ProductModel    m ON p.ProductModelID    = m.ProductModelID
    LEFT JOIN SalesLT.vProductAndDescription d ON p.ProductID = d.ProductID AND d.Culture = 'en';
END
GO

-- Look at what we built: the text, and the vector stored alongside it.
SELECT TOP (5) pe.ProductID, p.Name, pe.chunk, pe.embeddings
FROM SalesLT.ProductEmbeddings pe
JOIN SalesLT.Product p ON pe.ProductID = p.ProductID;
GO


/* -----------------------------------------------------------------------------
   STEP 5  —  Semantic search, the exact way (kNN)   [run this live]
   -----------------------------------------------------------------------------
   Embed the user's natural-language question, then rank every product by how
   close its vector is to the question's vector. VECTOR_DISTANCE('cosine', ...)
   does the math. "Closer" means "more semantically similar" — notice we never
   search for the literal words "red" or "bike".

   Turn on statistics so you can SEE this is a full scan of the table — fine for
   295 rows, but it would not scale to millions. That sets up Step 6.
----------------------------------------------------------------------------- */
SET STATISTICS TIME ON;
SET STATISTICS IO ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'I am looking for a red bike and I dont want to spend a lot';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

SELECT TOP (4)
    pe.ProductID,
    p.Name,
    p.ListPrice,
    pe.chunk,
    VECTOR_DISTANCE('cosine', @search_vector, pe.embeddings) AS distance
FROM SalesLT.ProductEmbeddings pe
JOIN SalesLT.Product p ON pe.ProductID = p.ProductID
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
           WHERE name = 'vec_idx' AND object_id = OBJECT_ID('SalesLT.ProductEmbeddings'))
    DROP INDEX vec_idx ON SalesLT.ProductEmbeddings;
GO
CREATE VECTOR INDEX vec_idx ON SalesLT.ProductEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann', maxdop = 8);
GO

-- Same question as Step 5, but now through VECTOR_SEARCH, which uses the index.
-- Compare the IO/time against Step 5: an index seek instead of a full scan.
SET STATISTICS TIME ON;
SET STATISTICS IO ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'I am looking for a red bike and I dont want to spend a lot';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

SELECT t.ProductID, t.chunk, s.distance, p.ListPrice
FROM VECTOR_SEARCH(
        TABLE      = SalesLT.ProductEmbeddings AS t,
        COLUMN     = [embeddings],
        SIMILAR_TO = @search_vector,
        METRIC     = 'cosine',
        TOP_N      = 10
     ) AS s
JOIN SalesLT.Product p ON t.ProductID = p.ProductID
ORDER BY s.distance;
GO
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO


/* =============================================================================
   STEP 7  —  Hand the database to an AI agent   [SETUP — the payoff]
   =============================================================================
   Everything above is SQL. Now we expose it so an AI agent (Claude, GitHub
   Copilot, anything that speaks MCP) can use it WITHOUT writing any SQL.

   Two pieces:
     (a) A clean catalog view + a semantic-search stored procedure. The proc
         wraps exactly the kNN query from Step 5, so the agent gets semantic
         search as a single callable tool.
     (b) A least-privilege login (dab_app) that Data API builder connects as.
         It can read a few catalog objects and EXECUTE the search proc — and
         nothing else. The agent literally cannot drop a table or read a column
         we didn't expose.

   Data API builder (the `dab` container) then turns these into MCP tools. See
   dab-config.json and docs/mcp-client-setup.md.
   ============================================================================= */

-- (a1) A tidy, agent-friendly product view — only useful columns, no BLOBs.
USE [AdventureWorksLT];
GO
CREATE OR ALTER VIEW SalesLT.vProductCatalog AS
SELECT
    p.ProductID,
    p.Name,
    p.ProductNumber,
    p.Color,
    p.StandardCost,
    p.ListPrice,
    p.Size,
    p.Weight,
    c.Name AS Category,
    m.Name AS Model
FROM SalesLT.Product p
LEFT JOIN SalesLT.ProductCategory c ON p.ProductCategoryID = c.ProductCategoryID
LEFT JOIN SalesLT.ProductModel    m ON p.ProductModelID    = m.ProductModelID;
GO

-- (a2) Semantic search as a stored procedure. This is the kNN query from Step 5,
--      parameterized. It returns only scalar columns (no VECTOR column), which
--      keeps it clean for Data API builder to expose. Exact search is plenty
--      fast for this catalog and avoids a preview-feature dependency in the
--      agent path.
CREATE OR ALTER PROCEDURE SalesLT.find_similar_products
    @prompt NVARCHAR(MAX),
    @top    INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(@prompt USE MODEL ollama);

    SELECT TOP (@top)
        p.ProductID,
        p.Name,
        p.ListPrice,
        pe.chunk,
        VECTOR_DISTANCE('cosine', @qv, pe.embeddings) AS distance
    FROM SalesLT.ProductEmbeddings pe
    JOIN SalesLT.Product p ON pe.ProductID = p.ProductID
    ORDER BY distance;
END
GO

-- Try the proc directly, the same way Data API builder will call it for the agent:
EXEC SalesLT.find_similar_products @prompt = N'something comfortable for a long ride', @top = 5;
GO

-- (b) Least-privilege login for Data API builder.
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'dab_app')
    CREATE LOGIN dab_app WITH PASSWORD = 'DabP@ss123!',   -- demo only
        CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF;
GO

USE [AdventureWorksLT];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'dab_app')
    CREATE USER dab_app FOR LOGIN dab_app;
GO

-- Read access to the catalog objects we expose, EXECUTE on the search proc, and
-- EXECUTE on the external model (so the proc can generate the query embedding).
-- Nothing else — no server-level rights, no access to anything we didn't list.
GRANT SELECT  ON SalesLT.vProductCatalog        TO dab_app;
GRANT SELECT  ON SalesLT.ProductCategory        TO dab_app;
GRANT SELECT  ON SalesLT.Customer               TO dab_app;
GRANT SELECT  ON SalesLT.SalesOrderHeader       TO dab_app;
GRANT SELECT  ON SalesLT.SalesOrderDetail       TO dab_app;
GRANT SELECT  ON SalesLT.Product                TO dab_app;  -- joined inside the proc
GRANT SELECT  ON SalesLT.ProductEmbeddings      TO dab_app;  -- read inside the proc
GRANT EXECUTE ON SalesLT.find_similar_products  TO dab_app;
GRANT EXECUTE ON EXTERNAL MODEL::ollama         TO dab_app;
GO

PRINT 'Setup complete. AdventureWorksLT is vectorized and exposed to Data API builder.';
GO
