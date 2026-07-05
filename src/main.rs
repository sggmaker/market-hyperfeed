use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, Parser)]
#[command(
    name = "market-hyperfeed",
    about = "Capture public crypto market data into a local WAL and replay it into ClickHouse."
)]
struct Cli {
    #[arg(long, global = true, default_value = "config/quickstart.toml")]
    config: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Capture {
        #[arg(long, default_value_t = 1)]
        max_trades: usize,
    },
    Replay,
    Smoke {
        #[arg(long, default_value_t = 1)]
        max_trades: usize,
    },
}

#[derive(Debug, Clone, Deserialize)]
struct AppConfig {
    exchange: ExchangeConfig,
    wal: WalConfig,
    clickhouse: ClickHouseConfig,
}

#[derive(Debug, Clone, Deserialize)]
struct ExchangeConfig {
    websocket_url: String,
    product_id: String,
    channel: String,
}

#[derive(Debug, Clone, Deserialize)]
struct WalConfig {
    path: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
struct ClickHouseConfig {
    url: String,
    database: String,
    table: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WalTrade {
    ts_recv: String,
    ts_event: String,
    venue: String,
    market: String,
    symbol: String,
    trade_id: String,
    price: f64,
    qty: f64,
    side: String,
    raw: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let cfg = load_config(&cli.config).await?;
    match cli.command {
        Command::Capture { max_trades } => {
            let captured = capture(&cfg, max_trades).await?;
            println!(
                "capture_ok trades={captured} wal={}",
                cfg.wal.path.display()
            );
        }
        Command::Replay => {
            let inserted = replay(&cfg).await?;
            println!("replay_ok inserted={inserted}");
        }
        Command::Smoke { max_trades } => {
            let before = clickhouse_count(&cfg).await.unwrap_or(0);
            let captured = capture(&cfg, max_trades).await?;
            let inserted = replay(&cfg).await?;
            let after = clickhouse_count(&cfg).await?;
            if after <= before {
                bail!("ClickHouse row count did not increase: before={before} after={after}");
            }
            println!(
                "quickstart_ok captured={captured} inserted={inserted} canon_trade_v2_rows={after}"
            );
        }
    }
    Ok(())
}

async fn load_config(path: &Path) -> Result<AppConfig> {
    let raw = fs::read_to_string(path)
        .await
        .with_context(|| format!("read config {}", path.display()))?;
    let mut cfg: AppConfig = toml::from_str(&raw).context("parse TOML config")?;
    if let Ok(url) = std::env::var("MARKET_HYPERFEED_CLICKHOUSE_URL") {
        cfg.clickhouse.url = url;
    }
    if let Ok(path) = std::env::var("MARKET_HYPERFEED_WAL_PATH") {
        cfg.wal.path = PathBuf::from(path);
    }
    Ok(cfg)
}

async fn capture(cfg: &AppConfig, max_trades: usize) -> Result<usize> {
    if max_trades == 0 {
        bail!("--max-trades must be greater than zero");
    }
    if let Some(parent) = cfg.wal.path.parent() {
        fs::create_dir_all(parent)
            .await
            .with_context(|| format!("create WAL directory {}", parent.display()))?;
    }
    let (mut ws, _) = connect_async(&cfg.exchange.websocket_url)
        .await
        .with_context(|| format!("connect {}", cfg.exchange.websocket_url))?;
    let subscribe = json!({
        "type": "subscribe",
        "product_ids": [cfg.exchange.product_id],
        "channels": [cfg.exchange.channel],
    });
    ws.send(Message::Text(subscribe.to_string()))
        .await
        .context("send Coinbase subscription")?;

    let mut wal = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&cfg.wal.path)
        .await
        .with_context(|| format!("open WAL {}", cfg.wal.path.display()))?;
    let mut captured = 0usize;
    while captured < max_trades {
        let next = timeout(Duration::from_secs(45), ws.next())
            .await
            .context("timed out waiting for public trade")?
            .ok_or_else(|| anyhow!("WebSocket closed before a trade was received"))??;
        let Message::Text(text) = next else {
            continue;
        };
        let Some(trade) = parse_coinbase_trade(&text)? else {
            continue;
        };
        let encoded = serde_json::to_vec(&trade).context("encode WAL trade")?;
        wal.write_all(&encoded).await.context("write WAL trade")?;
        wal.write_all(b"\n").await.context("write WAL newline")?;
        wal.flush().await.context("flush WAL")?;
        wal.sync_data().await.context("fsync WAL")?;
        captured += 1;
    }
    Ok(captured)
}

async fn replay(cfg: &AppConfig) -> Result<usize> {
    let raw = fs::read_to_string(&cfg.wal.path)
        .await
        .with_context(|| format!("read WAL {}", cfg.wal.path.display()))?;
    let mut rows = Vec::new();
    for (idx, line) in raw.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let trade: WalTrade =
            serde_json::from_str(line).with_context(|| format!("decode WAL line {}", idx + 1))?;
        rows.push(serde_json::to_string(&trade).context("encode ClickHouse JSONEachRow")?);
    }
    if rows.is_empty() {
        bail!("WAL contains no rows: {}", cfg.wal.path.display());
    }
    let query = format!(
        "INSERT INTO {}.{} FORMAT JSONEachRow",
        cfg.clickhouse.database, cfg.clickhouse.table
    );
    let body = rows.join("\n") + "\n";
    clickhouse_post(cfg, &query, body).await?;
    Ok(rows.len())
}

async fn clickhouse_count(cfg: &AppConfig) -> Result<u64> {
    let query = format!(
        "SELECT count() FROM {}.{} FORMAT TabSeparatedRaw",
        cfg.clickhouse.database, cfg.clickhouse.table
    );
    let text = reqwest::Client::new()
        .post(&cfg.clickhouse.url)
        .body(query)
        .send()
        .await
        .context("query ClickHouse count")?
        .error_for_status()
        .context("ClickHouse count returned error status")?
        .text()
        .await
        .context("read ClickHouse count body")?;
    text.trim()
        .parse::<u64>()
        .with_context(|| format!("parse ClickHouse count from {text:?}"))
}

async fn clickhouse_post(cfg: &AppConfig, query: &str, body: String) -> Result<()> {
    reqwest::Client::new()
        .post(&cfg.clickhouse.url)
        .query(&[("query", query)])
        .body(body)
        .send()
        .await
        .context("post ClickHouse insert")?
        .error_for_status()
        .context("ClickHouse insert returned error status")?;
    Ok(())
}

fn parse_coinbase_trade(text: &str) -> Result<Option<WalTrade>> {
    let value: Value = serde_json::from_str(text).context("parse Coinbase message")?;
    let msg_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if msg_type != "match" && msg_type != "last_match" {
        return Ok(None);
    }
    let symbol = required_str(&value, "product_id")?.to_owned();
    let price = required_str(&value, "price")?
        .parse::<f64>()
        .context("parse trade price")?;
    let qty = required_str(&value, "size")?
        .parse::<f64>()
        .context("parse trade size")?;
    let ts_event = value
        .get("time")
        .and_then(Value::as_str)
        .map(clickhouse_time)
        .transpose()?
        .unwrap_or_else(now_clickhouse_time);
    let trade_id = value
        .get("trade_id")
        .map(value_to_string)
        .unwrap_or_else(|| "unknown".to_owned());
    Ok(Some(WalTrade {
        ts_recv: now_clickhouse_time(),
        ts_event,
        venue: "coinbase".to_owned(),
        market: "spot".to_owned(),
        symbol,
        trade_id,
        price,
        qty,
        side: value
            .get("side")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
        raw: value.to_string(),
    }))
}

fn required_str<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Coinbase trade missing string field {key}"))
}

fn value_to_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => "unknown".to_owned(),
    }
}

fn clickhouse_time(raw: &str) -> Result<String> {
    let parsed = DateTime::parse_from_rfc3339(raw)
        .with_context(|| format!("parse Coinbase timestamp {raw:?}"))?;
    Ok(format_clickhouse_time(parsed.with_timezone(&Utc)))
}

fn now_clickhouse_time() -> String {
    format_clickhouse_time(Utc::now())
}

fn format_clickhouse_time(ts: DateTime<Utc>) -> String {
    ts.format("%Y-%m-%d %H:%M:%S%.6f").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_coinbase_match_message() {
        let raw = r#"{
            "type":"match",
            "trade_id":123,
            "sequence":456,
            "time":"2026-07-05T08:00:00.123456Z",
            "product_id":"BTC-USD",
            "price":"65000.50",
            "size":"0.01000000",
            "side":"buy"
        }"#;
        let trade = parse_coinbase_trade(raw).unwrap().unwrap();
        assert_eq!(trade.venue, "coinbase");
        assert_eq!(trade.market, "spot");
        assert_eq!(trade.symbol, "BTC-USD");
        assert_eq!(trade.trade_id, "123");
        assert_eq!(trade.ts_event, "2026-07-05 08:00:00.123456");
        assert_eq!(trade.price, 65000.50);
        assert_eq!(trade.qty, 0.01);
        assert_eq!(trade.side, "buy");
        assert!(trade.raw.contains("\"type\":\"match\""));
    }

    #[test]
    fn ignores_non_trade_messages() {
        let raw = r#"{"type":"subscriptions","channels":[]}"#;
        assert!(parse_coinbase_trade(raw).unwrap().is_none());
    }

    #[test]
    fn parses_quickstart_config() {
        let raw = include_str!("../config/quickstart.toml");
        let cfg: AppConfig = toml::from_str(raw).unwrap();
        assert_eq!(cfg.exchange.product_id, "BTC-USD");
        assert_eq!(cfg.clickhouse.database, "market_hyperfeed");
        assert!(cfg.wal.path.ends_with("quickstart.wal.jsonl"));
    }
}
