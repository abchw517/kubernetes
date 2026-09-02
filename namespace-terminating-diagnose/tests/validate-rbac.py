#!/usr/bin/env python3
"""Fail CI if namespace-terminating-diagnose RBAC gains write or privilege verbs."""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ALLOWED_RESOURCE_VERBS = {"get", "list"}
ALLOWED_NON_RESOURCE_VERBS = {"get"}
FORBIDDEN_VERBS = {
    "*",
    "create",
    "update",
    "patch",
    "delete",
    "deletecollection",
    "escalate",
    "bind",
    "impersonate",
}


def fail(message: str) -> None:
    print(f"RBAC validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <rbac.yaml>", file=sys.stderr)
        return 64

    path = Path(sys.argv[1])
    docs = [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]

    kinds = [doc.get("kind") for doc in docs]
    for required in ("ServiceAccount", "ClusterRole", "ClusterRoleBinding"):
        if required not in kinds:
            fail(f"missing {required}")

    roles = [doc for doc in docs if doc.get("kind") == "ClusterRole"]
    if len(roles) != 1:
        fail(f"expected exactly one ClusterRole, got {len(roles)}")

    role = roles[0]
    rules = role.get("rules") or []
    if not rules:
        fail("ClusterRole has no rules")

    for index, rule in enumerate(rules):
        verbs = set(rule.get("verbs") or [])
        if not verbs:
            fail(f"rule[{index}] has no verbs")

        forbidden = verbs & FORBIDDEN_VERBS
        if forbidden:
            fail(f"rule[{index}] contains forbidden verbs: {sorted(forbidden)}")

        if "nonResourceURLs" in rule:
            if not verbs <= ALLOWED_NON_RESOURCE_VERBS:
                fail(f"rule[{index}] non-resource verbs are not read-only: {sorted(verbs)}")
        else:
            if not verbs <= ALLOWED_RESOURCE_VERBS:
                fail(f"rule[{index}] resource verbs are not get/list only: {sorted(verbs)}")

    bindings = [doc for doc in docs if doc.get("kind") == "ClusterRoleBinding"]
    binding = bindings[0]
    role_ref = binding.get("roleRef") or {}
    if role_ref.get("kind") != "ClusterRole":
        fail("ClusterRoleBinding roleRef.kind must be ClusterRole")
    if role_ref.get("name") != role.get("metadata", {}).get("name"):
        fail("ClusterRoleBinding roleRef.name does not match ClusterRole")

    print("RBAC contract OK: read-only get/list only, no write/privilege verbs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
