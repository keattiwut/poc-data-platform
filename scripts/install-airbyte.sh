#!/usr/bin/env bash
set -euo pipefail

# --- WSL2 dispatch -------------------------------------------------------
# abctl (and the kind/kubectl tooling it drives) does not support native
# Windows. Airbyte's own docs recommend running abctl from inside WSL2 on
# Windows. If we're being invoked from a native Windows shell (Git
# Bash/MSYS), re-exec this same script inside the default WSL2 distro
# instead of failing outright. On WSL2/Linux/macOS this block is a no-op.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  echo "Detected native Windows shell - re-executing inside WSL2 (per Airbyte's guidance)..."
  WIN_DIR="$(pwd -W)"
  DRIVE="$(echo "${WIN_DIR:0:1}" | tr 'A-Z' 'a-z')"
  WSL_DIR="/mnt/${DRIVE}${WIN_DIR:2}"
  exec wsl.exe -d Ubuntu -- bash -lc "cd '${WSL_DIR}' && ./scripts/install-airbyte.sh"
fi
# ---------------------------------------------------------------------------

if ! command -v abctl &> /dev/null; then
  echo "abctl not found. Install it first (from within WSL2):"
  echo "  curl -LsfS https://get.airbyte.com | bash -"
  exit 1
fi

abctl local install
