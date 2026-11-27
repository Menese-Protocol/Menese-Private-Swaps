/// The interface's fixed-width types. A caller-supplied `nat` is unbounded LEB128, and decoding one
/// costs time growing with the square of its size, before the method's first statement; calls from
/// canisters never pass `inspect`. So every integer a caller supplies is a `nat64` (a price is two),
/// and decoding costs the same whatever the caller sends. These records are converted to the
/// internal records, which use `Nat`, once, at the method boundary; the same records are used when
/// the canister reports its settings, so a setting reads back in the form it is set.
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Feed "Feed";
import Settings "Settings";
import Terms "Terms";

module {
  /// round and deadline in nanoseconds; counts and basis points as plain numbers
  public type Settings = {
    round_ns : Nat64;
    deadline_ns : Nat64;
    max_report_age_ns : Nat64;
    k : Nat64;
    reporters : [Principal];
    spread_bps : Nat64;
    jump_bps : Nat64;
    confirm_bps : Nat64;
    jump_gap_ns : Nat64;
  };

  public type Guards = {
    xrc_max_age_s : Nat64;
    xrc_refresh_s : Nat64;
    min_sources : Nat64;
    max_spread_bps : Nat64;
    stall_s : Nat64;
    timeout_s : Nat64;
    join_fee_bps : Nat64;
    loss_pause_bps : Nat64;
    hub_lock_fee : Nat64;
    hub_min_swap : Nat64;
    providers : Settings.Providers;
    verify_price : Nat64;
    work_d_base : Nat64;
    work_d_max : Nat64;
    work_step : Nat64;
    work_window_s : Nat64;
    fail_budget : Nat64;
    backoff_s : Nat64;
  };

  public type PairSettings = {
    fee_bps : Nat64;
    protocol_share_bps : Nat64;
    band_bps : Nat64;
    lock_fee : Nat64;
    min_swap : Nat64;
    min_depth_icp : Nat64;
    cap_icp : Nat64;
    minute_cap_icp : Nat64;
    max_swap_bps : Nat64;
  };

  /// A price, `hi * 2^64 + lo` at the feed's scale: at most 2^128 - 1, which is `Feed.MAX_PRICE`.
  public type Price = { hi : Nat64; lo : Nat64 };

  public type Terms = { kind : Terms.Kind; target : Principal; bound : Nat64; nonce : Blob };

  let TWO_64 : Nat = 18_446_744_073_709_551_616;

  func n(x : Nat64) : Nat = Nat64.toNat(x);
  // Every value converted out was converted in from a `Nat64`, or is a compiled-in default within
  // range, so `fromNat` cannot trap here.
  func w(x : Nat) : Nat64 = Nat64.fromNat(x);

  public func price(p : Price) : Nat = n(p.hi) * TWO_64 + n(p.lo);


  public func feedIn(s : Settings) : Feed.Settings {
    {
      round_ns = s.round_ns;
      deadline_ns = s.deadline_ns;
      max_report_age_ns = s.max_report_age_ns;
      k = n(s.k);
      reporters = s.reporters;
      spread_bps = n(s.spread_bps);
      jump_bps = n(s.jump_bps);
      confirm_bps = n(s.confirm_bps);
      jump_gap_ns = s.jump_gap_ns;
    }
  };

  public func feedOut(s : Feed.Settings) : Settings {
    {
      round_ns = s.round_ns;
      deadline_ns = s.deadline_ns;
      max_report_age_ns = s.max_report_age_ns;
      k = w(s.k);
      reporters = s.reporters;
      spread_bps = w(s.spread_bps);
      jump_bps = w(s.jump_bps);
      confirm_bps = w(s.confirm_bps);
      jump_gap_ns = s.jump_gap_ns;
    }
  };

  public func guardsIn(g : Guards) : Settings.Guards {
    {
      xrc_max_age_s = n(g.xrc_max_age_s);
      xrc_refresh_s = n(g.xrc_refresh_s);
      min_sources = n(g.min_sources);
      max_spread_bps = n(g.max_spread_bps);
      stall_s = n(g.stall_s);
      timeout_s = n(g.timeout_s);
      join_fee_bps = n(g.join_fee_bps);
      loss_pause_bps = n(g.loss_pause_bps);
      hub_lock_fee = n(g.hub_lock_fee);
      hub_min_swap = n(g.hub_min_swap);
      providers = g.providers;
      verify_price = n(g.verify_price);
      work_d_base = n(g.work_d_base);
      work_d_max = n(g.work_d_max);
      work_step = n(g.work_step);
      work_window_s = n(g.work_window_s);
      fail_budget = n(g.fail_budget);
      backoff_s = n(g.backoff_s);
    }
  };

  public func guardsOut(g : Settings.Guards) : Guards {
    {
      xrc_max_age_s = w(g.xrc_max_age_s);
      xrc_refresh_s = w(g.xrc_refresh_s);
      min_sources = w(g.min_sources);
      max_spread_bps = w(g.max_spread_bps);
      stall_s = w(g.stall_s);
      timeout_s = w(g.timeout_s);
      join_fee_bps = w(g.join_fee_bps);
      loss_pause_bps = w(g.loss_pause_bps);
      hub_lock_fee = w(g.hub_lock_fee);
      hub_min_swap = w(g.hub_min_swap);
      providers = g.providers;
      verify_price = w(g.verify_price);
      work_d_base = w(g.work_d_base);
      work_d_max = w(g.work_d_max);
      work_step = w(g.work_step);
      work_window_s = w(g.work_window_s);
      fail_budget = w(g.fail_budget);
      backoff_s = w(g.backoff_s);
    }
  };

  public func pairIn(p : PairSettings) : Settings.PairSettings {
    {
      fee_bps = n(p.fee_bps);
      protocol_share_bps = n(p.protocol_share_bps);
      band_bps = n(p.band_bps);
      lock_fee = n(p.lock_fee);
      min_swap = n(p.min_swap);
      min_depth_icp = n(p.min_depth_icp);
      cap_icp = n(p.cap_icp);
      minute_cap_icp = n(p.minute_cap_icp);
      max_swap_bps = n(p.max_swap_bps);
    }
  };

  public func pairOut(p : Settings.PairSettings) : PairSettings {
    {
      fee_bps = w(p.fee_bps);
      protocol_share_bps = w(p.protocol_share_bps);
      band_bps = w(p.band_bps);
      lock_fee = w(p.lock_fee);
      min_swap = w(p.min_swap);
      min_depth_icp = w(p.min_depth_icp);
      cap_icp = w(p.cap_icp);
      minute_cap_icp = w(p.minute_cap_icp);
      max_swap_bps = w(p.max_swap_bps);
    }
  };

  public func termsIn(t : Terms) : Terms.Terms = { kind = t.kind; target = t.target; bound = n(t.bound); nonce = t.nonce };
};
