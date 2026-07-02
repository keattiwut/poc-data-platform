#!/usr/bin/env bash
set -euo pipefail

echo "Checking no .env file is tracked by git..."
if git ls-files | grep -q '^\.env$'; then
  echo "FAIL: .env is tracked by git"
  exit 1
fi

echo "Checking .env.example contains only placeholder values..."
if grep -qE '^[A-Z_]+=.{20,}' .env.example; then
  echo "FAIL: .env.example may contain a real (non-placeholder) value"
  exit 1
fi

echo "PASS: no committed secrets detected"
