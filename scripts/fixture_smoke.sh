#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_name="market-hyperfeed-fixture"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for scripts/fixture_smoke.sh" >&2
  exit 127
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required for scripts/fixture_smoke.sh" >&2
  exit 127
fi

compose() {
  docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" "$@"
}

cleanup() {
  compose down --remove-orphans >/dev/null
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
wal_path="$repo_root/var/fixture.wal.jsonl"
rm -f "$wal_path"

compose up -d clickhouse >/dev/null
wait_for_clickhouse
clickhouse_query "DROP DATABASE IF EXISTS market_hyperfeed"
clickhouse_multiquery_file "$repo_root/ClickHouseDDL.sql"

cat > "$wal_path" <<'JSON'
{"ts_recv":"2026-07-05 00:00:00.000001","ts_event":"2026-07-05 00:00:00.000000","venue":"fixture","market":"spot","symbol":"BTC-USD","trade_id":"fixture-1","price":65000.5,"qty":0.01,"side":"buy","raw":"{\"type\":\"match\",\"fixture\":true}"}
JSON

export MARKET_HYPERFEED_WAL_PATH="$wal_path"
export MARKET_HYPERFEED_CLICKHOUSE_URL="http://127.0.0.1:${CLICKHOUSE_HTTP_PORT:-8123}"
cargo run --locked -- replay --config config/quickstart.toml

rows="$(clickhouse_query "SELECT count() FROM market_hyperfeed.canon_trade_v2 WHERE trade_id = 'fixture-1' FORMAT TabSeparatedRaw")"
if [[ "$rows" != "1" ]]; then
  echo "fixture smoke expected 1 row, got $rows" >&2
  exit 1
fi

echo "fixture_smoke_ok canon_trade_v2_rows=$rows"
