#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_name="market-hyperfeed-quickstart"
keep_up=0

if [[ "${1:-}" == "--keep-up" ]]; then
  keep_up=1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for scripts/quickstart_smoke.sh" >&2
  exit 127
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required for scripts/quickstart_smoke.sh" >&2
  exit 127
fi

compose() {
  docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" "$@"
}

cleanup() {
  if [[ "$keep_up" -eq 0 ]]; then
    compose down --remove-orphans >/dev/null
  fi
}
trap cleanup EXIT

wait_for_clickhouse() {
  for _ in $(seq 1 60); do
    if compose exec -T clickhouse clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "ClickHouse did not become ready in time" >&2
  return 1
}

clickhouse_query() {
  local query="$1"
  for _ in $(seq 1 30); do
    if compose exec -T clickhouse clickhouse-client --query "$query"; then
      return 0
    fi
    sleep 1
  done
  echo "ClickHouse query did not succeed: $query" >&2
  return 1
}

clickhouse_multiquery_file() {
  local ddl_file="$1"
  for _ in $(seq 1 30); do
    if compose exec -T clickhouse clickhouse-client --multiquery < "$ddl_file"; then
      return 0
    fi
    sleep 1
  done
  echo "ClickHouse DDL did not succeed: $ddl_file" >&2
  return 1
}

cd "$repo_root"
mkdir -p "$repo_root/var"
rm -f "$repo_root/var/quickstart.wal.jsonl"

compose up -d clickhouse >/dev/null
wait_for_clickhouse
clickhouse_query "DROP DATABASE IF EXISTS market_hyperfeed"
clickhouse_multiquery_file "$repo_root/ClickHouseDDL.sql"

export MARKET_HYPERFEED_CLICKHOUSE_URL="http://127.0.0.1:${CLICKHOUSE_HTTP_PORT:-8123}"
cargo run --locked -- smoke --config config/quickstart.toml --max-trades 1
