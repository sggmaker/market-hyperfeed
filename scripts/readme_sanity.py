#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
README = ROOT / "README.md"

REQUIRED = [
    "Rust-based crypto market data pipeline",
    "scripts/quickstart_smoke.sh",
    "config/quickstart.toml",
    "ClickHouseDDL.sql",
    "market_hyperfeed.canon_trade_v2",
    "127.0.0.1",
    "scripts/fixture_smoke.sh",
    "scripts/gitleaks_scan.sh",
    "Apache-2.0",
]

FORBIDDEN_CLAIMS = re.compile(
    r"\b(HFT-ready|production-ready|fastest|public SLA|SLA-backed)\b",
    re.IGNORECASE,
)

FORBIDDEN_PATHS = [
    "docs/evidence",
    "docs/plans",
    "docs/packets",
    "docs/generated",
    ".agents",
    "AGENTS.md",
    "CLAUDE.md",
    "schemas",
    "crates",
    "ingest",
]

ALLOWED_TRACKED_PREFIXES = (
    ".github/",
    "scripts/",
    "src/",
)
ALLOWED_TRACKED_FILES = {
    ".gitignore",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "Cargo.lock",
    "Cargo.toml",
    "ClickHouseDDL.sql",
    "LICENSE",
    "NOTICE",
    "README.md",
    "SECURITY.md",
    "config.example.toml",
    "config/quickstart.toml",
    "docker-compose.yml",
    "docs/advanced/backfill-vendor-credentials.md",
    "rust-toolchain.toml",
}


def fail(message: str) -> None:
    print(f"readme_sanity: {message}", file=sys.stderr)
    raise SystemExit(1)


def tracked_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return [line for line in result.stdout.splitlines() if line]


def main() -> None:
    if not README.exists():
        fail("README.md is missing")
    text = README.read_text(encoding="utf-8")
    for snippet in REQUIRED:
        if snippet not in text:
            fail(f"README.md missing required snippet: {snippet}")
    if FORBIDDEN_CLAIMS.search(text):
        fail("README.md contains a forbidden readiness/performance claim")
    for rel in FORBIDDEN_PATHS:
        if (ROOT / rel).exists():
            fail(f"forbidden private/internal path exists: {rel}")
    for rel in tracked_files():
        if rel in ALLOWED_TRACKED_FILES:
            continue
        if rel.startswith(ALLOWED_TRACKED_PREFIXES):
            continue
        fail(f"tracked file is outside the public allowlist: {rel}")
    print("readme_sanity: ok")


if __name__ == "__main__":
    main()
