#!/usr/bin/env bash
# Start the SQL Server 2025 AI FastStart stack.
set -euo pipefail

cd "$(dirname "$0")"

EMBED_MODEL="nomic-embed-text"

# --- Host Ollama -------------------------------------------------------------
# Ollama runs on the HOST (GPU-accelerated, faster than a container). NGINX in
# the stack reverse-proxies to it at host.docker.internal:11434 and adds the TLS
# that SQL Server 2025's EXTERNAL MODEL requires.
if command -v ollama >/dev/null 2>&1; then
    if ! ollama list 2>/dev/null | grep -q "$EMBED_MODEL"; then
        echo "Pulling $EMBED_MODEL on the host (one time)..."
        ollama pull "$EMBED_MODEL"
    fi
    echo "Host Ollama ready ($EMBED_MODEL present)."
else
    echo "WARNING: 'ollama' not found on the host. Install it from https://ollama.com, then:"
    echo "    ollama pull $EMBED_MODEL"
fi
# If your containers can't reach host Ollama (non-Docker-Desktop runtimes like
# OrbStack or plain Linux), make Ollama listen on all interfaces:
#     launchctl setenv OLLAMA_HOST "0.0.0.0"   # then restart Ollama
# (Docker Desktop reaches the host's localhost via host.docker.internal already.)

# --- StackOverflow sample database (downloaded once) -------------------------
# The StackOverflowMini backup is ~759 MB — too big to commit to git, so fetch it
# once. This runs on the HOST, whose traffic isn't subject to the container TLS
# inspection (Zscaler etc.) that would otherwise block the download.
BAK="backups/StackOverflowMini.bak"
BAK_URL="https://github.com/BrentOzarULTD/Stack-Overflow-Database/releases/download/20230114/StackOverflowMini.bak"
if [ ! -f "$BAK" ]; then
    echo "Downloading the StackOverflow sample database (~759 MB, one time)..."
    mkdir -p backups
    curl -L --fail -o "$BAK" "$BAK_URL"
fi
echo "StackOverflow backup present ($(du -h "$BAK" 2>/dev/null | cut -f1))."

echo "Starting the stack (SQL Server 2025 + NGINX + Data API builder + SQL DBA MCP)..."
docker compose up --detach

cat <<'EOF'

Containers are starting. The first run takes a few minutes: it pulls images,
restores StackOverflow, and embeds a curated set of questions via host Ollama.

Watch the one-time setup finish:
    docker compose logs -f sql-init      # exits 0 when the database is ready

Then check everything is healthy:
    docker compose ps
    curl http://localhost:5001/health    # Data API builder
    curl http://localhost:3001/health    # SQL DBA MCP server

What you've got:
    SQL Server      localhost,1433   (sa / S0methingS@Str0ng!)
    Host Ollama     localhost:11434  (GPU-accelerated embeddings)
    DAB REST        http://localhost:5001/api/Questions
    DAB GraphQL     http://localhost:5001/graphql
    DAB MCP         http://localhost:5001/mcp   <-- semantic search over MCP
    SQL DBA MCP     http://localhost:3001/mcp   <-- read-only DBA tools over MCP

Next:
    1. Open demos/vector-demos.sql in your SQL client and walk Steps 2 and 4-7.
    2. Wire up your AI agent: see docs/mcp-client-setup.md (Claude in VS Code is
       pre-wired via .mcp.json — both MCP servers).
    3. Run the agent prompts in demos/agent-demo.md.
EOF
