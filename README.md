# MarketHyperFeed

MarketHyperFeed is a Rust-based crypto market data pipeline packaged as a small Apache-2.0 OSS project. The quickstart captures Coinbase Exchange public WebSocket trades, persists them to a local JSONL WAL, replays that WAL into ClickHouse, and verifies rows in `market_hyperfeed.canon_trade_v2`.

No vendor credentials are required for the public quickstart.

## 10-Minute Quickstart

Prerequisites:

- Rust toolchain from `rust-toolchain.toml`
- Docker with the `docker compose` plugin
- Network access to `wss://ws-feed.exchange.coinbase.com`

Run:

```bash
git clone https://github.com/sggmaker/market-hyperfeed.git
cd market-hyperfeed
scripts/quickstart_smoke.sh
```

Expected final line:

```text
quickstart_ok canon_trade_v2_rows=<number>
```

What the script does:

1. Starts ClickHouse from `docker-compose.yml`.
2. Applies `ClickHouseDDL.sql`.
3. Captures a public Coinbase `BTC-USD` trade into the repo-local ignored WAL configured by `config/quickstart.toml`.
4. Replays the WAL into `market_hyperfeed.canon_trade_v2`.
5. Confirms the ClickHouse row count increased.

The Compose file binds ClickHouse HTTP to `127.0.0.1` only. The quickstart is intended for local evaluation, not for exposing a database service on a network.

## Manual Run

Start ClickHouse:

```bash
docker compose -p market-hyperfeed-quickstart up -d clickhouse
docker compose -p market-hyperfeed-quickstart exec -T clickhouse clickhouse-client --multiquery < ClickHouseDDL.sql
```

Capture one public trade into the WAL:

```bash
cargo run --locked -- capture --config config/quickstart.toml --max-trades 1
```

Replay WAL rows into ClickHouse:

```bash
cargo run --locked -- replay --config config/quickstart.toml
```

Verify rows:

```bash
docker compose -p market-hyperfeed-quickstart exec -T clickhouse clickhouse-client --query \
  "SELECT count() FROM market_hyperfeed.canon_trade_v2 FORMAT TabSeparatedRaw"
```

Stop ClickHouse:

```bash
docker compose -p market-hyperfeed-quickstart down --remove-orphans
```

## Repository Shape

- `src/main.rs`: public Coinbase WebSocket capture, JSONL WAL write, and ClickHouse replay.
- `config/quickstart.toml`: credential-free quickstart config.
- `ClickHouseDDL.sql`: ClickHouse table used by the quickstart.
- `scripts/quickstart_smoke.sh`: end-to-end local smoke test.

## Development Checks

```bash
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 scripts/readme_sanity.py
scripts/public_secret_scan.sh
scripts/gitleaks_scan.sh
scripts/fixture_smoke.sh
```

CI uses `scripts/fixture_smoke.sh` for deterministic pull-request coverage and keeps the live public WebSocket smoke as a manual workflow.

## Scope

`v0.1.0-alpha.1` is an alpha packaging release for public WebSocket ingest, WAL durability, and ClickHouse replay. It does not include historical backfill, vendor credentials, or private operations tooling.

## License

MarketHyperFeed is licensed under Apache-2.0. See `LICENSE` and `NOTICE`.
