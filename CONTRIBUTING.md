# Contributing

MarketHyperFeed is in alpha. Keep changes focused on the public WebSocket -> WAL -> ClickHouse path unless a maintainer explicitly expands the public scope.

Before proposing changes, run:

```bash
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 scripts/readme_sanity.py
scripts/public_secret_scan.sh
```

Do not commit API keys, vendor credentials, private infrastructure paths, logs with sensitive values, or generated runtime data.
