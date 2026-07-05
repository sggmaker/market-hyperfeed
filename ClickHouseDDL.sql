CREATE DATABASE IF NOT EXISTS market_hyperfeed;

CREATE TABLE IF NOT EXISTS market_hyperfeed.canon_trade_v2
(
    ts_recv DateTime64(6, 'UTC'),
    ts_event DateTime64(6, 'UTC'),
    venue LowCardinality(String),
    market LowCardinality(String),
    symbol String,
    trade_id String,
    price Float64,
    qty Float64,
    side LowCardinality(String),
    raw String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toDate(ts_recv)
ORDER BY (venue, market, symbol, ts_recv, trade_id);
