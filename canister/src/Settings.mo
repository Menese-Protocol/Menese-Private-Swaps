/// Settings and their hard limits. Every number the DAO can change is here, with the range fixed
/// in code; a value outside its range is refused by the same function on every path (install,
/// dao_* and their validators), so no path can skip a limit.
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Feed "Feed";

module {
  public type Providers = { #AnyHolder; #Listed : [Principal] };

  public type Guards = {
    xrc_max_age_s : Nat; // a reading older than this is never used: no swap on its pair is priced
    xrc_refresh_s : Nat; // read the XRC again once the reading is older than this
    min_sources : Nat; // fewest exchanges behind each side of an XRC rate
    max_spread_bps : Nat; // widest XRC standard deviation accepted, of the rate
    stall_s : Nat; // no accepted round for this long: the pair takes no new locks
    timeout_s : Nat; // a lock not priced within this is owed back in full
    join_fee_bps : Nat; // stays in the reserve
    loss_pause_bps : Nat; // every pair pauses if a share's value fell this far within the hour
    hub_lock_fee : Nat; // e8s: the flat fee a lock of ICP proves
    hub_min_swap : Nat; // e8s
    providers : Providers;
    // the two methods that verify a proof for their caller (leave, collect_receipt)
    verify_price : Nat; // cycles a calling canister attaches per proof for an unconditional check
    work_d_base : Nat; // leading zero bits of work asked on the free path with no recent failures
    work_d_max : Nat; // the most ever asked
    work_step : Nat; // free-path failures in a window that raise the difficulty one bit
    work_window_s : Nat;
    fail_budget : Nat; // free-path failures per window; then the free path waits for the next
    backoff_s : Nat; // a receipt's first wait after a failed free collect, doubled after each
  };

  public type PairSettings = {
    fee_bps : Nat; // per leg
    protocol_share_bps : Nat; // of the fee; the rest stays in the reserve
    band_bps : Nat; // the feed's largest distance from the XRC before the pair pauses
    lock_fee : Nat; // in the asset's base units: the flat fee a lock of this asset proves
    min_swap : Nat; // in the asset's base units
    min_depth_icp : Nat; // e8s: both sides worth at least this before swaps on the pair
    cap_icp : Nat; // e8s: joins stop once the asset side is worth this
    minute_cap_icp : Nat; // e8s: value through the pair in one minute
    max_swap_bps : Nat; // the largest payout of one swap, of the paying side's holdings
  };

  public let DEFAULT_GUARDS : Guards = {
    xrc_max_age_s = 300;
    xrc_refresh_s = 60;
    min_sources = 3;
    max_spread_bps = 100;
    stall_s = 30;
    timeout_s = 120;
    join_fee_bps = 30;
    loss_pause_bps = 200;
    hub_lock_fee = 1_000_000; // 0.01 ICP
    hub_min_swap = 100_000_000; // 1 ICP
    providers = #AnyHolder;
    verify_price = 30_000_000_000;
    work_d_base = 0;
    work_d_max = 24;
    work_step = 4;
    work_window_s = 60;
    fail_budget = 4;
    backoff_s = 30;
  };

  /// Round 5 s (hard floor 2 s), confirm gap 30 s, spread, jump and confirm limits at their
  /// maxima. Reporters and k are set by the DAO; with none, no round ever forms.
  public func defaultFeed(reporters : [Principal], k : Nat) : Feed.Settings {
    {
      round_ns = 5_000_000_000;
      deadline_ns = 5_000_000_000;
      max_report_age_ns = 5_000_000_000; // one round: an update call can take two seconds to land
      k;
      reporters;
      spread_bps = 50;
      jump_bps = 250;
      confirm_bps = 50;
      jump_gap_ns = 30_000_000_000;
    }
  };

  public let MAX_LISTED_PROVIDERS : Nat = 256;

  public func guardsRejection(g : Guards, feed : Feed.Settings) : ?Text {
    if (g.xrc_max_age_s < 60 or g.xrc_max_age_s > 900) return ?"REJECT:xrc-max-age";
    if (g.xrc_refresh_s < 30 or g.xrc_refresh_s > g.xrc_max_age_s) return ?"REJECT:xrc-refresh";
    if (g.min_sources < 2 or g.min_sources > 10) return ?"REJECT:xrc-min-sources";
    if (g.max_spread_bps < 10 or g.max_spread_bps > 500) return ?"REJECT:xrc-max-spread";
    let roundS = Nat64.toNat(feed.round_ns) / 1_000_000_000;
    if (g.stall_s < 10 or g.stall_s > 600 or g.stall_s < 3 * roundS) return ?"REJECT:stall";
    // a lock must outlive a held jump: the gap plus three rounds
    let gapS = Nat64.toNat(feed.jump_gap_ns) / 1_000_000_000;
    if (g.timeout_s < 20 or g.timeout_s > 600 or g.timeout_s < gapS + 3 * roundS) return ?"REJECT:timeout";
    if (g.join_fee_bps > 300) return ?"REJECT:join-fee";
    if (g.loss_pause_bps < 50 or g.loss_pause_bps > 1_000) return ?"REJECT:loss-pause";
    if (g.hub_min_swap == 0 or g.hub_lock_fee > g.hub_min_swap) return ?"REJECT:hub-min-swap";
    // a paid check always pays for itself: a transfer-proof leave costs about 24.5 B cycles
    if (g.verify_price < 25_000_000_000 or g.verify_price > 1_000_000_000_000) return ?"REJECT:verify-price";
    if (g.work_d_max > 32 or g.work_d_base > g.work_d_max) return ?"REJECT:work-difficulty";
    if (g.work_step < 1 or g.work_step > 64) return ?"REJECT:work-step";
    if (g.work_window_s < 10 or g.work_window_s > 3_600) return ?"REJECT:work-window";
    if (g.fail_budget < 1 or g.fail_budget > 64) return ?"REJECT:fail-budget";
    if (g.backoff_s < 1 or g.backoff_s > 3_600) return ?"REJECT:backoff";
    switch (g.providers) {
      case (#Listed(list)) { if (list.size() > MAX_LISTED_PROVIDERS) return ?"REJECT:providers-list" };
      case (#AnyHolder) {};
    };
    null
  };

  public func pairRejection(p : PairSettings) : ?Text {
    if (p.fee_bps < 5 or p.fee_bps > 300) return ?"REJECT:fee-bps";
    if (p.protocol_share_bps > 10_000) return ?"REJECT:protocol-share";
    if (p.band_bps < 50 or p.band_bps > 1_000) return ?"REJECT:band";
    if (p.min_swap == 0 or p.lock_fee > p.min_swap) return ?"REJECT:min-swap";
    if (p.cap_icp < p.min_depth_icp) return ?"REJECT:cap";
    if (p.minute_cap_icp == 0) return ?"REJECT:minute-cap";
    if (p.max_swap_bps == 0 or p.max_swap_bps > 1_000) return ?"REJECT:max-swap";
    null
  };

  /// The feed's own floor (k >= 3, k > n/2, round >= 2 s) plus the guards that depend on it.
  public func feedRejection(f : Feed.Settings, g : Guards) : ?Text {
    switch (Feed.settingsRejection(f)) { case (?e) return ?e; case null {} };
    guardsRejection(g, f)
  };

  public func mayProvide(g : Guards, p : Principal) : Bool {
    switch (g.providers) {
      case (#AnyHolder) true;
      case (#Listed(list)) { for (x in list.vals()) { if (Principal.equal(x, p)) return true }; false };
    }
  };

  public func describePair(p : PairSettings) : Text {
    "fee " # Nat.toText(p.fee_bps) # " bps per leg (protocol share " # Nat.toText(p.protocol_share_bps) # " bps), band "
    # Nat.toText(p.band_bps) # " bps, lock fee " # Nat.toText(p.lock_fee) # ", smallest swap " # Nat.toText(p.min_swap)
    # ", depth " # Nat.toText(p.min_depth_icp) # " e8s, cap " # Nat.toText(p.cap_icp) # " e8s, per minute "
    # Nat.toText(p.minute_cap_icp) # " e8s, largest payout " # Nat.toText(p.max_swap_bps) # " bps of the paying side"
  };
};
