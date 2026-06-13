#!/usr/bin/env bash
# Stop the stack. Pass --wipe to also delete the SQL data and Ollama models
# (forces a fresh restore + re-embedding on the next start).
set -euo pipefail

if [[ "${1:-}" == "--wipe" ]]; then
    echo "Stopping and deleting all data (SQL data, Ollama models)..."
    docker compose down --volumes
else
    echo "Stopping containers (data is kept). Use './stop.sh --wipe' for a clean reset."
    docker compose down
fi
