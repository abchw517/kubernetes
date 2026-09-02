#!/usr/bin/env bash
# Static guard: production scripts must not introduce Kubernetes write operations.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

mapfile -t files < <(
  find "$ROOT_DIR" -maxdepth 2 -type f -name '*.sh' \
    ! -path '*/tests/*' -print | sort
)

if (( ${#files[@]} == 0 )); then
  echo "No production Shell files found" >&2
  exit 1
fi

# Match executable-style calls, not documentation prose.
patterns=(
  '(^|[;&|[:space:]])kubectl[[:space:]]+([^#\n]*[[:space:]])?(delete|patch|replace|edit|apply|create|scale)[[:space:]]'
  '(^|[;&|[:space:]])k[[:space:]]+(delete|patch|replace|edit|apply|create|scale)[[:space:]]'
  '/api/v1/namespaces/.*/finalize'
)

for pattern in "${patterns[@]}"; do
  if grep -nE "$pattern" "${files[@]}"; then
    echo "Read-only contract violation: Kubernetes mutating operation detected" >&2
    exit 1
  fi
done

echo "Read-only Shell contract OK"
