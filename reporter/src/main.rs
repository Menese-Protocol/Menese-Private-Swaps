//! swap-reporter: one reporter of the private swap canister's consensus feed.
//!
//!   swap-reporter keygen <identity.pem>     a new Ed25519 identity; prints its principal
//!   swap-reporter principal <identity.pem>
//!   swap-reporter run <config.json>          report every round until stopped
//!
//! Each round (the canister's clock, read from `round_info`, not this machine's): wait for the
//! round to open, read every configured venue for every pair, take the lower median of at least
//! `min_sources` venues, and report it only if every venue is within `max_disagreement_bps` of
//! it. The report names the round and the time the prices were asked for, which is after the
//! round opened; the canister refuses any report observed before its round opened.
//!
//! The reporter is authenticated by its update calls: the subnet checks the sender's signature
//! before the canister runs, and the canister takes reports only from the principals the DAO set.

mod aggregate;
mod sources;

use aggregate::{aggregate, Verdict};
use candid::{CandidType, Decode, Deserialize, Encode, Principal};
use ic_agent::identity::BasicIdentity;
use ic_agent::{Agent, Identity};
use sources::{PairConfig, Plant, Replay, Source};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, serde::Deserialize)]
struct Config {
    canister: String,
    url: String,
    identity: String,
    /// true only against a local replica (its root key is not the IC's)
    #[serde(default)]
    local: bool,
    #[serde(default = "default_min_sources")]
    min_sources: usize,
    #[serde(default = "default_disagreement")]
    max_disagreement_bps: u32,
    #[serde(default = "default_start_delay")]
    start_delay_ms: u64,
    #[serde(default = "default_fetch_timeout")]
    fetch_timeout_ms: u64,
    pairs: Vec<PairConfig>,
    /// local runs only: recorded prices instead of the venues
    replay: Option<String>,
    /// local runs only: a planted fault
    plant: Option<Plant>,
    /// stop after this many rounds (0 = never)
    #[serde(default)]
    rounds: u64,
}
fn default_min_sources() -> usize { 3 }
fn default_disagreement() -> u32 { 50 }
fn default_start_delay() -> u64 { 500 }
fn default_fetch_timeout() -> u64 { 1_500 }

#[derive(CandidType, Deserialize, Debug)]
struct RoundInfo {
    now: u64,
    round_ns: u64,
    deadline_ns: u64,
    max_report_age_ns: u64,
    pools: Vec<Principal>,
}

#[derive(CandidType, Deserialize, Debug, Clone)]
struct PriceReport {
    pool: Principal,
    price: Price,
    observed_at: u64,
}

/// The canister's price: `hi * 2^64 + lo`.
#[derive(CandidType, Deserialize, Debug, Clone)]
struct Price {
    hi: u64,
    lo: u64,
}

fn local_ns() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).expect("clock after 1970").as_nanos() as u64
}

fn keygen(path: &str) -> Result<(), String> {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = ring::signature::Ed25519KeyPair::generate_pkcs8(&rng).map_err(|e| e.to_string())?;
    let b64 = base64_encode(pkcs8.as_ref());
    let mut pem = String::from("-----BEGIN PRIVATE KEY-----\n");
    for chunk in b64.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).unwrap());
        pem.push('\n');
    }
    pem.push_str("-----END PRIVATE KEY-----\n");
    if std::path::Path::new(path).exists() {
        return Err(format!("{path} exists; refusing to overwrite an identity"));
    }
    std::fs::write(path, pem).map_err(|e| e.to_string())?;
    let id = BasicIdentity::from_pem_file(path).map_err(|e| e.to_string())?;
    println!("{}", id.sender().map_err(|e| e.to_string())?);
    Ok(())
}

fn base64_encode(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

async fn round_info(agent: &Agent, canister: &Principal) -> Result<(RoundInfo, i128), String> {
    let sent = local_ns();
    let bytes = agent
        .query(canister, "round_info")
        .with_arg(Encode!().unwrap())
        .call()
        .await
        .map_err(|e| e.to_string())?;
    let got = local_ns();
    let info = Decode!(&bytes, RoundInfo).map_err(|e| e.to_string())?;
    // the canister's clock minus this host's, at the midpoint of the call; a query sees the last
    // finalized state, so this lags the canister's update clock: prices are asked for later,
    // never earlier, than the round opened
    let offset = info.now as i128 - ((sent as i128 + got as i128) / 2);
    Ok((info, offset))
}

async fn run(path: &str) -> Result<(), String> {
    let cfg: Config = serde_json::from_str(&std::fs::read_to_string(path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    if (cfg.replay.is_some() || cfg.plant.is_some()) && !cfg.local {
        return Err("replay and planted faults run only against a local replica".into());
    }
    if cfg.min_sources < 3 {
        return Err("min_sources must be at least 3".into());
    }
    let canister = Principal::from_text(&cfg.canister).map_err(|e| e.to_string())?;
    let identity = BasicIdentity::from_pem_file(&cfg.identity).map_err(|e| e.to_string())?;
    let me = identity.sender().map_err(|e| e.to_string())?;
    let agent = Agent::builder().with_url(&cfg.url).with_identity(identity).build().map_err(|e| e.to_string())?;
    if cfg.local {
        agent.fetch_root_key().await.map_err(|e| e.to_string())?;
    }
    let pools: Vec<(PairConfig, Principal)> = cfg
        .pairs
        .iter()
        .map(|p| Principal::from_text(&p.pool).map(|id| (p.clone(), id)).map_err(|e| e.to_string()))
        .collect::<Result<_, _>>()?;
    for (p, _) in &pools {
        if p.venues.len() < cfg.min_sources {
            return Err(format!("{}: {} venues configured, {} needed", p.symbol, p.venues.len(), cfg.min_sources));
        }
    }
    let source = match &cfg.replay {
        Some(f) => {
            let replay: Replay = serde_json::from_str(&std::fs::read_to_string(f).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            let (_, offset) = round_info(&agent, &canister).await?;
            Source::Replay { origin_ns: (local_ns() as i128 + offset) as u64, replay }
        }
        None => Source::live(Duration::from_millis(cfg.fetch_timeout_ms))?,
    };
    let plant = cfg.plant.clone().unwrap_or_default();
    eprintln!("reporter {me} for {} pair(s) on {canister}", pools.len());
    let mut done = 0u64;
    loop {
        let (info, offset) = match round_info(&agent, &canister).await {
            Ok(x) => x,
            Err(e) => {
                eprintln!("round_info: {e}");
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };
        if info.round_ns == 0 {
            tokio::time::sleep(Duration::from_secs(1)).await;
            continue;
        }
        let canister_now = (local_ns() as i128 + offset) as u64;
        let open = (canister_now / info.round_ns + 1) * info.round_ns;
        let start = open + cfg.start_delay_ms * 1_000_000;
        tokio::time::sleep(Duration::from_nanos(start.saturating_sub(canister_now))).await;
        let observed_at = ((local_ns() as i128 + offset) as u64).max(start);
        let mut reports = Vec::new();
        for (pair, pool) in &pools {
            if !info.pools.contains(pool) {
                continue;
            }
            let (venues, errors) = source.venue_prices(pair, observed_at).await;
            for e in &errors {
                eprintln!("{}: {e}", pair.symbol);
            }
            let prices: Vec<_> = venues.into_iter().map(|(_, p)| p).collect();
            match aggregate(&prices, cfg.min_sources, cfg.max_disagreement_bps) {
                Verdict::Report(p) => match aggregate::wire_price(&plant.apply(p)) {
                    Some((hi, lo)) => reports.push(PriceReport { pool: *pool, price: Price { hi, lo }, observed_at }),
                    None => eprintln!("{} round {open}: no report: the price is 2^128 or more", pair.symbol),
                },
                Verdict::Refuse(why) => eprintln!("{} round {open}: no report: {why}", pair.symbol),
            }
        }
        if !reports.is_empty() {
            let arg = Encode!(&open, &reports).map_err(|e| e.to_string())?;
            match agent.update(&canister, "report").with_arg(arg).call_and_wait().await {
                Ok(bytes) => match Decode!(&bytes, Vec<String>) {
                    Ok(outcomes) => println!("round {open}: {}", outcomes.join(",")),
                    Err(e) => eprintln!("round {open}: decode: {e}"),
                },
                Err(e) => eprintln!("round {open}: report: {e}"),
            }
        }
        done += 1;
        if cfg.rounds > 0 && done >= cfg.rounds {
            return Ok(());
        }
    }
}

/// Read every venue once for one symbol and print what this reporter would report. No canister.
async fn probe(symbol: &str, decimals: &str) -> Result<(), String> {
    let decimals: u32 = decimals.parse().map_err(|_| "decimals must be a number".to_string())?;
    let pair = PairConfig {
        pool: String::new(),
        symbol: symbol.to_string(),
        decimals,
        venues: vec!["binance".into(), "coinbase".into(), "kraken".into(), "okx".into()],
    };
    let source = Source::live(Duration::from_millis(3_000))?;
    let (venues, errors) = source.venue_prices(&pair, local_ns()).await;
    for (v, p) in &venues {
        println!("{v}: {p}");
    }
    for e in &errors {
        println!("error: {e}");
    }
    let prices: Vec<_> = venues.into_iter().map(|(_, p)| p).collect();
    println!("verdict: {:?}", aggregate(&prices, 3, 50));
    Ok(())
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let r = match args.get(1).map(String::as_str) {
        Some("keygen") if args.len() == 3 => keygen(&args[2]),
        Some("principal") if args.len() == 3 => BasicIdentity::from_pem_file(&args[2])
            .map_err(|e| e.to_string())
            .and_then(|i| i.sender().map_err(|e| e.to_string()))
            .map(|p| println!("{p}")),
        Some("run") if args.len() == 3 => run(&args[2]).await,
        Some("probe") if args.len() == 4 => probe(&args[2], &args[3]).await,
        _ => Err("usage: swap-reporter keygen <pem> | principal <pem> | run <config.json> | probe <SYMBOL> <decimals>".into()),
    };
    if let Err(e) = r {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
