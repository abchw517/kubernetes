#!/usr/bin/env bash
# Thin wrapper for periodic cluster-wide Terminating metrics collection.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "${SCRIPT_DIR}/resource-terminating-diagnose.sh" collector "$@"
