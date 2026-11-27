/// The Exchange Rate Canister backstop: its interface, and the pure checks made on its answers.
///
/// The XRC never prices a swap. A reading is compared with the feed's accepted price: a pair whose
/// feed drifts beyond the band from a fresh, well-sourced XRC reading pauses until the DAO resumes
/// it. Interface: dfinity/ic rs/rust_canisters/xrc_mock/xrc.did (the XRC's own service), with the
/// call cost of the live XRC (1,000,000,000 cycles attached; the XRC refunds what it does not use).
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";

module {
  public type AssetClass = { #Cryptocurrency; #FiatCurrency };
  public type Asset = { symbol : Text; class_ : AssetClass };
  public type GetExchangeRateRequest = { base_asset : Asset; quote_asset : Asset; timestamp : ?Nat64 };
  public type ExchangeRateMetadata = {
    decimals : Nat32;
    base_asset_num_received_rates : Nat64;
    base_asset_num_queried_sources : Nat64;
    quote_asset_num_received_rates : Nat64;
    quote_asset_num_queried_sources : Nat64;
    standard_deviation : Nat64;
    forex_timestamp : ?Nat64;
  };
  public type ExchangeRate = {
    base_asset : Asset;
    quote_asset : Asset;
    timestamp : Nat64;
    rate : Nat64;
    metadata : ExchangeRateMetadata;
  };
  public type ExchangeRateError = {
    #AnonymousPrincipalNotAllowed;
    #Pending;
    #CryptoBaseAssetNotFound;
    #CryptoQuoteAssetNotFound;
    #StablecoinRateNotFound;
    #StablecoinRateTooFewRates;
    #StablecoinRateZeroRate;
    #ForexInvalidTimestamp;
    #ForexBaseAssetNotFound;
    #ForexQuoteAssetNotFound;
    #ForexAssetsNotFound;
    #RateLimited;
    #NotEnoughCycles;
    #FailedToAcceptCycles;
    #InconsistentRatesReceived;
    #Other : { code : Nat32; description : Text };
  };
  public type GetExchangeRateResult = { #Ok : ExchangeRate; #Err : ExchangeRateError };
  public type Service = actor { get_exchange_rate : GetExchangeRateRequest -> async GetExchangeRateResult };

  public let CALL_CYCLES : Nat = 1_000_000_000;
  public let ICP_DECIMALS : Nat = 8;
  public let SCALE : Nat = 1_000_000_000_000_000_000;

  /// A checked reading: the XRC's rate as a feed price (ICP e8s per asset base unit, times 10^18)
  /// and the time the XRC says the rate is for (ns).
  public type Reading = { price : Nat; rate_time_ns : Nat64; read_at_ns : Nat64; sources : Nat; spread_bps : Nat };

  /// rate is "ICP per asset" times 10^decimals; one asset base unit is 10^-asset_decimals asset,
  /// one ICP is 10^8 e8s.
  public func priceOf(rate : Nat64, xrcDecimals : Nat32, assetDecimals : Nat) : Nat {
    Nat64.toNat(rate) * SCALE * (10 ** ICP_DECIMALS) / ((10 ** Nat32.toNat(xrcDecimals)) * (10 ** assetDecimals))
  };

  /// Why an XRC answer is not good enough to judge the feed by, or the checked reading.
  public func check(r : ExchangeRate, assetDecimals : Nat, minSources : Nat, maxSpreadBps : Nat, now : Nat64) : { #ok : Reading; #err : Text } {
    if (r.rate == 0) return #err("xrc-zero-rate");
    if (Nat32.toNat(r.metadata.decimals) > 18) return #err("xrc-decimals");
    let sources = Nat.min(Nat64.toNat(r.metadata.base_asset_num_received_rates), Nat64.toNat(r.metadata.quote_asset_num_received_rates));
    if (sources < minSources) return #err("xrc-too-few-sources");
    let spread = Nat64.toNat(r.metadata.standard_deviation) * 10_000 / Nat64.toNat(r.rate);
    if (spread > maxSpreadBps) return #err("xrc-spread");
    let rateTime = r.timestamp * 1_000_000_000;
    if (rateTime > now + 60_000_000_000) return #err("xrc-time-ahead");
    let price = priceOf(r.rate, r.metadata.decimals, assetDecimals);
    if (price == 0) return #err("xrc-price-zero");
    #ok({ price; rate_time_ns = rateTime; read_at_ns = now; sources; spread_bps = spread })
  };

  /// |a - b| <= b * bps / 10_000
  public func within(a : Nat, b : Nat, bps : Nat) : Bool {
    let diff = if (a >= b) a - b else b - a;
    diff * 10_000 <= b * bps
  };
};
