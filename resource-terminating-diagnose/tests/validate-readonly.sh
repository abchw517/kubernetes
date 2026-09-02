#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Reject direct Kubernetes write verbs in executable shell code.
if grep -RInE --include='*.sh' \
  '(^|[[:space:]])(kubectl|k)[[:space:]]+(apply|create|delete|edit|label|annotate|patch|replace|scale|taint)[[:space:]]' \
  "$SCRIPT_DIR"; then
  echo "ERROR: write-capable kubectl invocation detected" >&2
  exit 1
fi

# The shipped RBAC must remain get/list only.
if grep -nE 'verbs:.*(create|update|patch|delete|deletecollection|impersonate|escalate|bind)' \
  "$SCRIPT_DIR/rbac/rbac.yaml"; then
  echo "ERROR: write-capable RBAC verb detected" >&2
  exit 1
fi

if ! grep -q 'verbs: \["get", "list"\]' "$SCRIPT_DIR/rbac/rbac.yaml"; then
  echo "ERROR: expected explicit get/list RBAC contract not found" >&2
  exit 1
fi

echo "read-only contract passed"
