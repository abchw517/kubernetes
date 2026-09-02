#!/usr/bin/env python3
"""Validate namespace-terminating-diagnose JSON output against its contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <schema.json> <result.json>", file=sys.stderr)
        return 64

    schema_path = Path(sys.argv[1])
    result_path = Path(sys.argv[2])

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    instance = json.loads(result_path.read_text(encoding="utf-8"))

    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))

    if errors:
        for error in errors:
            path = ".".join(str(part) for part in error.absolute_path) or "<root>"
            print(f"JSON contract violation at {path}: {error.message}", file=sys.stderr)
        return 1

    print(f"JSON contract OK: {result_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
