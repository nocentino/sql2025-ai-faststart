#!/usr/bin/env bash
# Start the SQL Server 2025 AI FastStart stack.
set -euo pipefail

echo "Starting the stack (SQL Server 2025 + Ollama + NGINX + Data API builder)..."
docker compose up --detach

cat <<'EOF'

Containers are starting. The first run takes a few minutes: it pulls images,
restores AdventureWorksLT, and generates embeddings for the whole catalog.

Watch the one-time setup finish:
    docker compose logs -f sql-init      # exits 0 when the database is ready

Then check everything is healthy:
    docker compose ps
    curl http://localhost:5001/health    # Data API builder

What you've got:
    SQL Server      localhost,1433   (sa / S0methingS@Str0ng!)
    Ollama API      localhost:11434
    DAB REST        http://localhost:5001/api/Products
    DAB GraphQL     http://localhost:5001/graphql
    DAB MCP         http://localhost:5001/mcp   <-- point your AI agent here

Next:
    1. Open demos/vector-demos.sql in your SQL client and walk Steps 2 and 4-7.
    2. Wire up your AI agent: see docs/mcp-client-setup.md.
    3. Run the agent prompts in demos/agent-demo.md.
EOF
