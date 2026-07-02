#!/usr/bin/env bash
set -euo pipefail

# --- WSL2 dispatch -------------------------------------------------------
# See scripts/install-airbyte.sh for why: abctl/kind live in WSL2 on this
# machine, not natively on Windows. Re-exec there if we're on native
# Windows. No-op on WSL2/Linux/macOS.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  echo "Detected native Windows shell - re-executing inside WSL2 (per Airbyte's guidance)..."
  WIN_DIR="$(pwd -W)"
  DRIVE="$(echo "${WIN_DIR:0:1}" | tr 'A-Z' 'a-z')"
  WSL_DIR="/mnt/${DRIVE}${WIN_DIR:2}"
  exec wsl.exe -d Ubuntu -- bash -lc "cd '${WSL_DIR}' && ./scripts/verify-airbyte.sh"
fi
# ---------------------------------------------------------------------------

echo "Checking abctl reports Airbyte as running..."
if ! command -v abctl &> /dev/null; then
  echo "FAIL: abctl not found"
  exit 1
fi
# NOTE: abctl's actual `local status` output does not contain the literal
# string "running" (that wording was aspirational, not abctl's real
# output). The real, observed signal for a healthy install is the line
# "Airbyte should be accessible via http://<host>:<port>", plus a
# zero exit code. Verified against abctl v0.30.4 output.
STATUS_OUTPUT=$(abctl local status 2>&1) || {
  echo "FAIL: 'abctl local status' exited non-zero"
  echo "$STATUS_OUTPUT"
  exit 1
}
echo "$STATUS_OUTPUT" | grep -qi "Airbyte should be accessible" \
  || (echo "FAIL: abctl does not report Airbyte as running" && echo "$STATUS_OUTPUT" && exit 1)

echo "Checking Airbyte UI is reachable..."
curl -sf http://localhost:8000/ > /dev/null

echo "PASS: Airbyte is installed and reachable"
