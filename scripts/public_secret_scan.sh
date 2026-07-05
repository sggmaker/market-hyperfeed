#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
from __future__ import annotations

import math
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path.cwd()

CATEGORY_PATTERNS = [
    ("private_key_block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("aws_access_key_id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github_token", re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{30,}\b")),
    ("bearer_token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b", re.IGNORECASE)),
]

KEY_ASSIGNMENT = re.compile(
    r"(?i)\b(password|passwd|api[_-]?key|access[_-]?key|secret|token|private[_-]?key|client[_-]?secret)\b"
    r"\s*[:=]\s*[\"']?([^\"'\s#]+)"
)

HIGH_ENTROPY = re.compile(r"\b[A-Za-z0-9_+/=-]{32,}\b")
PLACEHOLDER_VALUES = {
    "",
    "example",
    "sample",
    "placeholder",
    "changeme",
    "redacted",
    "<redacted>",
}


def tracked_files() -> list[pathlib.Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [ROOT / item.decode() for item in result.stdout.split(b"\0") if item]


def shannon_entropy(value: str) -> float:
    if not value:
        return 0.0
    counts = {char: value.count(char) for char in set(value)}
    length = len(value)
    return -sum((count / length) * math.log2(count / length) for count in counts.values())


def looks_like_digest(value: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", value))


def is_known_safe_candidate(value: str) -> bool:
    lower = value.lower().strip("\"'")
    if lower in PLACEHOLDER_VALUES:
        return True
    if looks_like_digest(value):
        return True
    if value.startswith(("http://", "https://", "wss://")):
        return True
    return False


def scan_line(line: str) -> set[str]:
    categories: set[str] = set()
    for category, pattern in CATEGORY_PATTERNS:
        if pattern.search(line):
            categories.add(category)
    for match in KEY_ASSIGNMENT.finditer(line):
        value = match.group(2).strip().strip("\"'")
        if len(value) >= 8 and not is_known_safe_candidate(value):
            categories.add("credential_assignment")
    for match in HIGH_ENTROPY.finditer(line):
        value = match.group(0)
        if is_known_safe_candidate(value):
            continue
        if shannon_entropy(value) >= 4.4:
            categories.add("high_entropy_token_candidate")
    return categories


def main() -> int:
    blocked: dict[str, set[str]] = {}
    scanned = 0
    for path in tracked_files():
        rel = path.relative_to(ROOT).as_posix()
        scanned += 1
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line in text.splitlines():
            categories = scan_line(line)
            if categories:
                blocked.setdefault(rel, set()).update(categories)

    if not blocked:
        print(f"result=clean scanned_files={scanned} blocked_paths=0")
        return 0

    print(f"result=blocked scanned_files={scanned} blocked_paths={len(blocked)}")
    for path in sorted(blocked):
        print(f"path={path} risk={','.join(sorted(blocked[path]))}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
PY
