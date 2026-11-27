//! Where prices come from: public exchange tickers, or (against a local replica only) a recorded
//! replay with optional planted faults for tests.

use crate::aggregate::{feed_price, parse_decimal, Quote};
use num_bigint::BigUint;
use serde::Deserialize;
use std::time::Duration;

#[derive(Clone, Debug, Deserialize)]
pub struct PairConfig {
    /// the asset's private pool: the pair's name on the canister
    pub pool: String,
    /// the asset's market symbol, e.g. "BTC" for ckBTC
    pub symbol: String,
    pub decimals: u32,
    pub venues: Vec<String>,
}

/// One venue's price for a symbol in its own quote currency (USD or USDT; the same currency for
/// the asset and for ICP on one venue, so it cancels).
async fn venue_quote(http: &reqwest::Client, venue: &str, symbol: &str) -> Result<Quote, String> {
    let get = |url: String| async move {
        let r = http.get(&url).send().await.map_err(|e| format!("{venue}: {e}"))?;
        if !r.status().is_success() {
            return Err(format!("{venue}: http {}", r.status()));
        }
        r.json::<serde_json::Value>().await.map_err(|e| format!("{venue}: {e}"))
    };
    let text: Option<String> = match venue {
        "binance" => {
            let v = get(format!("https://api.binance.com/api/v3/ticker/price?symbol={symbol}USDT")).await?;
            v["price"].as_str().map(str::to_owned)
        }
        "coinbase" => {
            let v = get(format!("https://api.exchange.coinbase.com/products/{symbol}-USD/ticker")).await?;
            v["price"].as_str().map(str::to_owned)
        }
        "kraken" => {
            let k = if symbol == "BTC" { "XBT" } else { symbol };
            let v = get(format!("https://api.kraken.com/0/public/Ticker?pair={k}USD")).await?;
            if v["error"].as_array().map(|e| !e.is_empty()).unwrap_or(true) {
                return Err(format!("kraken: {}", v["error"]));
            }
            v["result"].as_object().and_then(|m| m.values().next()).and_then(|t| t["c"][0].as_str()).map(str::to_owned)
        }
        "okx" => {
            let v = get(format!("https://www.okx.com/api/v5/market/ticker?instId={symbol}-USDT")).await?;
            v["data"][0]["last"].as_str().map(str::to_owned)
        }
        other => return Err(format!("unknown venue {other}")),
    };
    let t = text.ok_or_else(|| format!("{venue}: no price for {symbol}"))?;
    parse_decimal(&t).ok_or_else(|| format!("{venue}: unparsable price {t:?}"))
}

/// Recorded venue prices for local runs: the latest row at or before the replay clock wins.
#[derive(Clone, Debug, Deserialize)]
pub struct Replay {
    pub rows: Vec<ReplayRow>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ReplayRow {
    pub t_ms: u64,
    pub venue: String,
    pub symbol: String,
    pub price: String,
}

impl Replay {
    fn quote(&self, t_ms: u64, venue: &str, symbol: &str) -> Result<Quote, String> {
        let row = self
            .rows
            .iter()
            .filter(|r| r.venue == venue && r.symbol == symbol && r.t_ms <= t_ms)
            .max_by_key(|r| r.t_ms)
            .ok_or_else(|| format!("replay: no {venue} {symbol} at {t_ms} ms"))?;
        parse_decimal(&row.price).ok_or_else(|| format!("replay: bad price {:?}", row.price))
    }
}

pub enum Source {
    Live(reqwest::Client),
    /// replay clock origin (the canister-clock ns at which t_ms = 0), and the rows
    Replay { origin_ns: u64, replay: Replay },
}

impl Source {
    pub fn live(timeout: Duration) -> Result<Source, String> {
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .user_agent("swap-reporter/0.1")
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Source::Live(http))
    }

    /// Each venue's price of `pair` in the canister's unit; venues that fail are left out.
    pub async fn venue_prices(&self, pair: &PairConfig, now_ns: u64) -> (Vec<(String, BigUint)>, Vec<String>) {
        let mut ok = Vec::new();
        let mut errors = Vec::new();
        let futs = pair.venues.iter().map(|venue| async move {
            let (a, i) = match self {
                Source::Live(http) => {
                    futures::join!(venue_quote(http, venue, &pair.symbol), venue_quote(http, venue, "ICP"))
                }
                Source::Replay { origin_ns, replay } => {
                    let t_ms = now_ns.saturating_sub(*origin_ns) / 1_000_000;
                    (replay.quote(t_ms, venue, &pair.symbol), replay.quote(t_ms, venue, "ICP"))
                }
            };
            (venue.clone(), a, i)
        });
        for (venue, a, i) in futures::future::join_all(futs).await {
            match (a, i) {
                (Ok(a), Ok(i)) => match feed_price(&a, &i, pair.decimals) {
                    Some(p) => ok.push((venue, p)),
                    None => errors.push(format!("{venue}: price out of range")),
                },
                (Err(e), _) | (_, Err(e)) => errors.push(e),
            }
        }
        (ok, errors)
    }
}

/// Planted faults for local tests (replay only): a lying reporter.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Plant {
    /// multiply every reported price by (10_000 + bias_bps) / 10_000
    #[serde(default)]
    pub bias_bps: i64,
}

impl Plant {
    pub fn apply(&self, p: BigUint) -> BigUint {
        let num = BigUint::from((10_000 + self.bias_bps).max(0) as u64);
        p * num / 10_000u32
    }
}
