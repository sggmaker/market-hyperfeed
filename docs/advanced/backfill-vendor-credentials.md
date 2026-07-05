# Backfill And Vendor Credentials

The public `v0.1.0-alpha.1` package does not include historical backfill or vendor credential workflows.

The quickstart uses Coinbase Exchange public WebSocket data and does not require API keys. If future releases add vendor-backed historical data, credentials should be passed only through environment-variable references or a secret manager, never as committed TOML, JSON, command-line arguments, logs, or issue text.
