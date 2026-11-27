/// The private swap canister.
///
/// Swaps between the private pools through an ICP hub, priced by this canister's own consensus
/// feed at the first round that opens after a lock (PROPOSAL-private-swaps-v2.md §3.5):
///
///   1. lock: a user's transfer proof, bound to the terms of the swap, is verified by the source
///      pool (`swap_lock`); the value leaves the user's notes into the pool's reserve record;
///   2. price: the first accepted feed round that opened after the lock prices it, if one is
///      finalized before the lock's timeout and the Exchange Rate Canister agrees within the band;
///      otherwise the whole locked value is owed back in the source pool;
///   3. collect: the user's deposit proof for exactly the owed amount is verified by the paying
///      pool (`swap_collect`), which appends the note.
///
/// Calls go one way, this canister to the pools; every pool method it calls is idempotent by an
/// id it chooses, so a lost reply is recovered by asking again. Nothing is written before an
/// await that an error return would have to undo, except the in-flight markers that the books
/// count as in flight.
///
/// Liquidity providers hold shares of one reserve across every asset, as private receipt notes in
/// this canister's own tree; the DAO holds shares publicly.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import ICRC3 "mo:zk/ICRC3";
import Books "Books";
import Feed "Feed";
import PoolApi "PoolApi";
import Pricing "Pricing";
import Receipts "Receipts";
import Settings "Settings";
import Terms "Terms";
import Wire "Wire";
import Work "Work";
import Xrc "Xrc";

persistent actor class Swap(init : {
  sns_governance : Principal;
  hub_pool : Principal;
  xrc : Principal;
  feed : ?Wire.Settings;
  guards : ?Wire.Guards;
}) = self {

  // ================================================================ types

  public type Result<T> = { #ok : T; #err : Text };
  public type Validation = { #Ok : Text; #Err : Text };

  public type AssetState = { #open; #paused : Text; #closed };

  type Sweep = { id : Nat64; amount : Nat; var calling : Bool };

  type Asset = {
    index : Nat;
    pool : Principal;
    ledger : Principal;
    symbol : Text;
    xrc_class : Xrc.AssetClass;
    decimals : Nat;
    var settings : ?Settings.PairSettings; // null for the ICP hub, which has no pair of its own
    var state : AssetState;
    feed : Feed.PairFeed;
    var xrc_reading : ?Xrc.Reading;
    var xrc_inflight : Bool;
    var xrc_attempt_ns : Nat64;
    var xrc_error : Text;
    var xrc_demand_ns : Nat64;
    var lock_cursor : Nat64; // every pool lock id below this is recorded
    seen_above : Map.Map<Nat64, ()>; // recorded lock ids at or above the cursor
    var pool_lock_count : Nat;
    var sweep : ?Sweep;
    var last_sweep_ns : Nat64;
    var collecting : Nat; // owed amounts with a collect in flight
  };

  public type PendingKind = {
    #swap : { owner : Principal; to : Nat; min_out : Nat };
    #join : { owner : Principal; min_shares : Nat };
    #dao_join;
    #dao_sell : { withdrawal : Nat };
  };

  type Pending = {
    seq : Nat;
    from : Nat;
    var amount : Nat;
    var t_lock : Nat64;
    var deadline : Nat64;
    kind : PendingKind;
    lock : ?(Nat, Nat64);
  };

  public type CollectState = { #open; #collecting; #collected };
  /// What priced a payout or a receipt: the lock's time and each round used (pool, open, price).
  public type Priced = { t_lock : Nat64; rounds : [(Principal, Nat64, Nat)] };
  public type OwedKind = { #payout; #refund : Text; #leave };

  type Owed = {
    id : Nat64;
    asset : Nat;
    owner : Principal;
    amount : Nat;
    kind : OwedKind;
    created_ns : Nat64;
    priced : ?Priced;
    var state : CollectState;
    var attempts : Nat;
    var free_failures : Nat; // failed free-path verifications of a collect of this record
    var retry_after_ns : Nat64; // no free collect before this
  };

  type ReceiptOwed = {
    id : Nat64;
    owner : Principal;
    shares : Nat;
    created_ns : Nat64;
    priced : ?Priced;
    var state : CollectState;
    var free_failures : Nat; // failed free-path verifications of this receipt
    var retry_after_ns : Nat64; // no free attempt before this
  };

  type Withdrawal = {
    id : Nat;
    shares : Nat;
    min_icp : Nat;
    var waiting : Nat;
    var icp : Nat;
    var stage : { #converting; #paying; #paid; #rejoined };
  };

  type Payout = { withdrawal : Nat; total : Nat; var created_at : Nat64; var calling : Bool };

  type Snapshot = { at_ns : Nat64; held : [(Nat, Nat)]; shares : Nat };

  // ================================================================ limits

  transient let MAX_ASSETS : Nat = 16; // the hub and fifteen pairs
  transient let MAX_PENDING : Nat = 4_096;
  transient let SETTLE_BATCH : Nat = 64;
  transient let PAGE_MAX : Nat = 200;
  transient let MAX_NAT64 : Nat = 18_446_744_073_709_551_615;
  transient let MAX_ARG_BYTES : Nat = 16_384;
  transient let NS : Nat64 = 1_000_000_000;
  transient let NEVER : Nat64 = 18_446_744_073_709_551_615;
  transient let TICK_SECONDS : Nat = 2;
  transient let SWEEP_INTERVAL_NS : Nat64 = 600_000_000_000;
  transient let CROSS_CHECK_INTERVAL_NS : Nat64 = 60_000_000_000;
  transient let SNAPSHOT_INTERVAL_NS : Nat64 = 300_000_000_000;
  transient let SNAPSHOTS : Nat = 12; // one hour at the interval above
  transient let XRC_RETRY_NS : Nat64 = 10_000_000_000;
  transient let PAYOUT_FRESH_NS : Nat64 = 43_200_000_000_000; // re-stamp a refused payout after 12 h
  transient let SPLIT_TRIES : Nat = 8;

  // ================================================================ state

  let governance : Principal = init.sns_governance;
  let hubPool : Principal = init.hub_pool;
  let xrcId : Principal = init.xrc;

  var guards : Settings.Guards = switch (init.guards) { case (?g) Wire.guardsIn(g); case null Settings.DEFAULT_GUARDS };
  var feed_settings : ?Feed.Settings = switch (init.feed) { case (?f) ?Wire.feedIn(f); case null null };
  do {
    switch (feed_settings) {
      case (?f) { switch (Settings.feedRejection(f, guards)) { case (?e) Runtime.trap(e); case null {} } };
      case null { switch (Settings.guardsRejection(guards, Settings.defaultFeed([], 0))) { case (?e) Runtime.trap(e); case null {} } };
    };
    if (Principal.isAnonymous(governance) or Principal.isAnonymous(hubPool) or Principal.isAnonymous(xrcId)) Runtime.trap("REJECT:init-anonymous");
  };

  var paused : ?Text = ?"install"; // every pair: installed paused, until the DAO opens swaps (Resume, all pairs)

  let assets = Map.empty<Nat, Asset>();
  let poolIndex = Map.empty<Principal, Nat>();
  var next_asset : Nat = 1;

  let books : Books.State = Books.newState();

  let pending = Map.empty<Nat, Pending>();
  var next_seq : Nat = 0;
  var settle_cursor : Nat = 0;

  let owed = Map.empty<Nat64, Owed>();
  var next_owed : Nat64 = 0;
  let owedByOwner = Map.empty<Principal, List.List<Nat64>>();

  let receipts : Receipts.State = Receipts.newState();
  let receiptOwed = Map.empty<Nat64, ReceiptOwed>();
  var next_receipt : Nat64 = 0;
  let receiptsByOwner = Map.empty<Principal, List.List<Nat64>>();

  var vk_source : ?{ transfer_hex : Text; deposit_hex : Text; digest : Blob } = null;
  var transfer_key : ?Receipts.Prepared = null;
  var keys : ?Receipts.Keys = null;

  let credited = Map.empty<Nat64, Nat>(); // ICP ledger block -> amount
  transient let crediting = Map.empty<Nat64, ()>();

  let withdrawals = Map.empty<Nat, Withdrawal>();
  var next_withdrawal : Nat = 0;
  var active_withdrawal : ?Nat = null;
  var payout : ?Payout = null;

  var next_sweep : Nat64 = 0;

  let snapshots = List.empty<Snapshot>();
  var last_snapshot_ns : Nat64 = 0;

  var last_cross_check_ns : Nat64 = 0;
  var cross_check_note : Text = "";
  transient var cross_check_inflight : Bool = false;
  transient var setup_inflight : Bool = false;

  var swaps_filled : Nat = 0;
  var joins_filled : Nat = 0;
  var refunds : Nat = 0;
  var leaves : Nat = 0;
  let work_gate : Work.Gate = Work.newGate(Nat64.fromNat(Int.abs(Time.now())));
  var paid_checks : Nat = 0;
  var proof_cycles_accepted : Nat = 0;
  var proof_cycles_forwarded : Nat = 0; // kept by the pools on paid locks and collects

  func newAsset(index : Nat, pool : Principal, ledger : Principal, symbol : Text, cls : Xrc.AssetClass, decimals : Nat, settings : ?Settings.PairSettings) : Asset {
    {
      index;
      pool;
      ledger;
      symbol;
      xrc_class = cls;
      decimals;
      var settings = settings;
      var state = #open;
      feed = Feed.newPairFeed();
      var xrc_reading = null;
      var xrc_inflight = false;
      var xrc_attempt_ns = 0;
      var xrc_error = "";
      var xrc_demand_ns = 0;
      var lock_cursor = 0;
      seen_above = Map.empty<Nat64, ()>();
      var pool_lock_count = 0;
      var sweep = null;
      var last_sweep_ns = 0;
      var collecting = 0;
    }
  };

  do {
    Map.add(assets, Nat.compare, Books.ICP, newAsset(Books.ICP, hubPool, hubPool, "ICP", #Cryptocurrency, 8, null));
    Map.add(poolIndex, Principal.compare, hubPool, Books.ICP);
  };

  // ================================================================ helpers

  func nowNs() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };
  func selfPrincipal() : Principal { Principal.fromActor(self) };
  func isGovernance(p : Principal) : Bool { Principal.equal(p, governance) };

  func assetAt(i : Nat) : Asset {
    switch (Map.get(assets, Nat.compare, i)) { case (?a) a; case null Runtime.trap("asset index") }
  };

  func assetByPool(p : Principal) : ?Asset {
    switch (Map.get(poolIndex, Principal.compare, p)) { case (?i) ?assetAt(i); case null null }
  };

  func poolActor(a : Asset) : PoolApi.Pool { actor (Principal.toText(a.pool)) };

  func keysReady() : Bool { switch (keys) { case (?_) true; case null false } };

  /// The assets as they are now, for walks that await between items (a map is not walked across
  /// an await: a pair added meanwhile must not disturb the walk).
  func assetList() : [Asset] {
    let l = List.empty<Asset>();
    for ((_, a) in Map.entries(assets)) List.add(l, a);
    List.toArray(l)
  };

  /// The flat fee a lock in this asset's pool must prove, and its smallest swap.
  func lockFee(a : Asset) : Nat {
    switch (a.settings) { case (?p) p.lock_fee; case null guards.hub_lock_fee }
  };
  func minSwap(a : Asset) : Nat {
    switch (a.settings) { case (?p) p.min_swap; case null guards.hub_min_swap }
  };

  func addIndex(m : Map.Map<Principal, List.List<Nat64>>, owner : Principal, id : Nat64) {
    switch (Map.get(m, Principal.compare, owner)) {
      case (?l) List.add(l, id);
      case null { let l = List.empty<Nat64>(); List.add(l, id); Map.add(m, Principal.compare, owner, l) };
    }
  };

  func newOwed(asset : Nat, owner : Principal, amount : Nat, kind : OwedKind) : Nat64 { newOwedPriced(asset, owner, amount, kind, null) };

  func newOwedPriced(asset : Nat, owner : Principal, amount : Nat, kind : OwedKind, priced : ?Priced) : Nat64 {
    let id = next_owed;
    next_owed += 1;
    Map.add(owed, Nat64.compare, id, { id; asset; owner; amount; kind; created_ns = nowNs(); priced; var state = #open : CollectState; var attempts = 0; var free_failures = 0; var retry_after_ns = 0 : Nat64 } : Owed);
    addIndex(owedByOwner, owner, id);
    id
  };

  func newReceiptOwed(owner : Principal, shares : Nat, priced : ?Priced) : Nat64 {
    let id = next_receipt;
    next_receipt += 1;
    Map.add(receiptOwed, Nat64.compare, id, { id; owner; shares; created_ns = nowNs(); priced; var state = #open : CollectState; var free_failures = 0; var retry_after_ns = 0 : Nat64 } : ReceiptOwed);
    addIndex(receiptsByOwner, owner, id);
    id
  };

  func timeoutNs() : Nat64 { Nat64.fromNat(guards.timeout_s) * NS };

  /// A reading the feed may be judged by: read within the maximum age, for a rate no older.
  func freshReading(a : Asset, now : Nat64) : ?Xrc.Reading {
    switch (a.xrc_reading) {
      case (?r) {
        let maxAge = Nat64.fromNat(guards.xrc_max_age_s) * NS;
        if (r.read_at_ns + maxAge >= now and r.rate_time_ns + maxAge >= now) ?r else null
      };
      case null null;
    }
  };

  func pauseAsset(a : Asset, reason : Text) {
    switch (a.state) { case (#open) a.state := #paused(reason); case _ {} };
  };

  func pauseAll(reason : Text) {
    if (paused == null) paused := ?reason;
  };

  /// A pair takes new locks only while its feed is alive: an accepted round within the stall time.
  func feedAlive(a : Asset, now : Nat64) : Bool {
    switch (Feed.lastAcceptedAt(a.feed)) {
      case (?t) t + Nat64.fromNat(guards.stall_s) * NS >= now;
      case null false;
    }
  };

  func lockable(a : Asset, now : Nat64) : ?Text {
    switch (a.state) {
      case (#open) {};
      case (#paused(r)) return ?("REJECT:pair-paused:" # r);
      case (#closed) return ?"REJECT:pair-closed";
    };
    if (a.index != Books.ICP) {
      if (feed_settings == null) return ?"REJECT:no-feed";
      if (not feedAlive(a, now)) return ?"REJECT:feed-stalled";
    };
    null
  };

  // ================================================================ lock

  public type LockReceipt = { lock_id : Nat64; recorded : Bool };

  func lockRejection(src : Asset, args : PoolApi.SwapLockArgs, now : Nat64) : ?Text {
    switch (paused) { case (?r) return ?("REJECT:paused:" # r); case null {} };
    if (Principal.isAnonymous(args.owner)) return ?"REJECT:owner-anonymous";
    if (Map.size(pending) >= MAX_PENDING) return ?"REJECT:busy";
    switch (lockable(src, now)) { case (?e) return ?e; case null {} };
    let amount = Nat64.toNat(args.v_pub_out);
    if (amount < minSwap(src)) return ?"REJECT:below-smallest-swap";
    if (Nat64.toNat(args.fee) != lockFee(src)) return ?"REJECT:lock-fee";
    let t = switch (Terms.decode(args.terms)) { case (?t) t; case null return ?"REJECT:terms" };
    // every caller-sized field within its bound before the argument is sent on to the pool: the
    // fixed fields as the pool requires them, the opaque records within the receipt tree's bounds
    // (the live pools' note shape, 32 and 584 bytes, is inside them), the proof as the verifier
    // requires it
    if (args.anchor.size() != 32 or args.nullifier_1.size() != 32 or args.nullifier_2.size() != 32) return ?"REJECT:field-length";
    for (o in [args.output_1, args.output_2].vals()) {
      if (o.commitment.size() != 32) return ?"REJECT:commitment-length";
      if (o.ephemeral_key.size() > Receipts.MAX_EPK or o.note_ciphertext.size() > Receipts.MAX_CIPHERTEXT) return ?"REJECT:opaque-record-size";
    };
    switch (Receipts.proofRejection(args.proof_hex)) { case (?e) return ?e; case null {} };
    switch (t.kind) {
      case (#swap) {
        let dst = switch (assetByPool(t.target)) { case (?d) d; case null return ?"REJECT:unknown-target" };
        if (dst.index == src.index) return ?"REJECT:same-asset";
        switch (lockable(dst, now)) { case (?e) return ?e; case null {} };
      };
      case (#join) {
        if (not Principal.equal(t.target, selfPrincipal())) return ?"REJECT:join-target";
        if (not Settings.mayProvide(guards, args.owner)) return ?"REJECT:not-a-provider";
        if (not keysReady()) return ?"REJECT:receipt-keys-not-ready";
        // every held pair must be priceable for the join to be valued
        for ((i, a) in Map.entries(assets)) {
          if (i != Books.ICP and Books.asset(books, i).held > 0) {
            switch (lockable(a, now)) { case (?e) return ?e; case null {} };
          };
        };
      };
    };
    null
  };

  /// Lock: forward a transfer proof to the source pool, which verifies it. Anyone may relay it:
  /// the proof binds the owner and the terms, so a relayer can change neither. Checks here only
  /// save a doomed lock; every one that matters is made again when the lock is priced. The pool's
  /// verification is paid (the caller's cycles go on to the pool) or free (priced by `work` and
  /// bounded by the failure budget, as `leave`).
  public shared func lock(pool : Principal, args : PoolApi.SwapLockArgs, work : Blob) : async Result<LockReceipt> {
    let src = switch (assetByPool(pool)) { case (?a) a; case null return #err("REJECT:unknown-pool") };
    let now = nowNs();
    switch (lockRejection(src, args, now)) { case (?e) return #err(e); case null {} };
    let forwarded = takeForward<system>();
    let free = forwarded == 0;
    if (free) {
      switch (freeGate(now, Work.lockDigest(pool, args), work)) { case (?e) return #err(e); case null {} };
      Work.hold(work_gate);
    };
    // nothing is written before the pool's answer: a lock the pool refuses leaves no trace here
    // (not even XRC demand, which would let refused locks arm XRC reads)
    let r = try { await (with cycles = forwarded) poolActor(src).swap_lock(args) } catch (e) {
      #err("REJECT:pool-call:" # Error.message(e))
    } finally {
      if (free) Work.release(work_gate);
    };
    settleForwarded(forwarded);
    switch (r) {
      case (#ok(l)) {
        markDemand(l.terms, src, nowNs());
        #ok({ lock_id = l.lock_id; recorded = recordLock(src.index, l) })
      };
      case (#err(e)) {
        if (free) ignore freeVerificationFailed(e);
        #err(e)
      };
    }
  };

  func markDemand(terms : Blob, src : Asset, now : Nat64) {
    src.xrc_demand_ns := now;
    switch (Terms.decode(terms)) {
      case (?t) {
        switch (t.kind) {
          case (#swap) { switch (assetByPool(t.target)) { case (?d) d.xrc_demand_ns := now; case null {} } };
          case (#join) { for ((_, a) in Map.entries(assets)) a.xrc_demand_ns := now };
        };
      };
      case null {};
    };
  };

  /// Record a lock the pool committed, exactly once. Its time is this canister's clock when it
  /// learns of the lock, which is after the pool's commit: the round that prices it opens later.
  func recordLock(i : Nat, l : PoolApi.SwapLock) : Bool {
    let a = assetAt(i);
    if (l.lock_id < a.lock_cursor or Map.containsKey(a.seen_above, Nat64.compare, l.lock_id)) return false;
    Map.add(a.seen_above, Nat64.compare, l.lock_id, ());
    while (Map.containsKey(a.seen_above, Nat64.compare, a.lock_cursor)) {
      Map.remove(a.seen_above, Nat64.compare, a.lock_cursor);
      a.lock_cursor += 1;
    };
    let amount = Nat64.toNat(l.amount);
    let ab = Books.asset(books, i);
    Books.lockIn(ab, amount);
    let now = nowNs();
    let kind : ?PendingKind = switch (Terms.decode(l.terms)) {
      case (?t) {
        switch (t.kind) {
          case (#swap) {
            switch (assetByPool(t.target)) {
              case (?d) { if (d.index != i) ?#swap({ owner = l.owner; to = d.index; min_out = t.bound }) else null };
              case null null;
            }
          };
          case (#join) { if (Principal.equal(t.target, selfPrincipal())) ?#join({ owner = l.owner; min_shares = t.bound }) else null };
        }
      };
      case null null;
    };
    switch (kind) {
      case (?k) {
        let seq = next_seq;
        next_seq += 1;
        Map.add(pending, Nat.compare, seq, { seq; from = i; var amount = amount; var t_lock = now; var deadline = now + timeoutNs(); kind = k; lock = ?(i, l.lock_id) });
      };
      case null {
        Books.refund(ab, amount);
        ignore newOwed(i, l.owner, amount, #refund("terms"));
        refunds += 1;
      };
    };
    true
  };

  /// Import locks the pool committed whose replies this canister did not process. Anyone may call.
  public shared func sync(pool : Principal) : async Result<Nat> {
    let a = switch (assetByPool(pool)) { case (?a) a; case null return #err("REJECT:unknown-pool") };
    let page = try { await poolActor(a).swap_locks_page(a.lock_cursor, Nat64.fromNat(PAGE_MAX)) } catch (e) {
      return #err("REJECT:pool-call:" # Error.message(e));
    };
    var n = 0;
    for (l in page.vals()) { if (recordLock(a.index, l)) n += 1 };
    #ok(n)
  };

  // ================================================================ pricing a pending lock

  type Px = { #price : { price : Nat; open : Nat64 }; #wait; #never : Text };

  /// The price of asset `i` for pending item `p`: the first accepted round opened after the lock,
  /// finalized by its deadline, within the band of a fresh XRC reading. `allowClosed`: a DAO sale
  /// may still use a closed pair's feed.
  func priceFor(i : Nat, p : Pending, now : Nat64, allowClosed : Bool) : Px {
    let a = assetAt(i);
    switch (paused) { case (?r) return #never("paused:" # r); case null {} };
    switch (a.state) {
      case (#open) {};
      case (#paused(r)) return #never("pair-paused:" # r);
      case (#closed) { if (not allowClosed) return #never("pair-closed") };
    };
    let band = switch (a.settings) { case (?s) s.band_bps; case null return #never("no-pair") };
    if (feed_settings == null) return if (now > p.deadline) #never("no-feed") else #wait;
    switch (Feed.settlingRound(a.feed, p.t_lock, p.deadline, now)) {
      case (#wait) #wait;
      case (#never) #never("no-round");
      case (#round(r)) {
        a.xrc_demand_ns := now;
        switch (freshReading(a, now)) {
          case null { if (now > p.deadline) #never("xrc-stale") else #wait };
          case (?x) {
            if (not Xrc.within(r.price, x.price, band)) {
              pauseAsset(a, "xrc-drift");
              return #never("xrc-drift");
            };
            #price({ price = r.price; open = r.open_ns })
          };
        }
      };
    }
  };

  func view(i : Nat, price : Nat) : ?Books.PairView {
    switch (assetAt(i).settings) { case (?s) ?{ settings = s; price }; case null null }
  };

  func refundPending(p : Pending, owner : Principal, reason : Text) {
    Books.refund(Books.asset(books, p.from), p.amount);
    ignore newOwed(p.from, owner, p.amount, #refund(reason));
    refunds += 1;
  };

  /// One pending item. True when it is resolved and leaves the queue.
  func settleOne(p : Pending, now : Nat64) : Bool {
    switch (p.kind) {
      case (#swap(s)) settleSwap(p, s.owner, s.to, s.min_out, now);
      case (#join(j)) settleJoin(p, ?j.owner, j.min_shares, now);
      case (#dao_join) settleJoin(p, null, 0, now);
      case (#dao_sell(w)) settleDaoSell(p, w.withdrawal, now);
    }
  };

  func settleSwap(p : Pending, owner : Principal, to : Nat, minOut : Nat, now : Nat64) : Bool {
    let hub : Px = #price({ price = 0; open = 0 });
    let fromPx : Px = if (p.from == Books.ICP) hub else priceFor(p.from, p, now, false);
    let toPx : Px = if (to == Books.ICP) hub else priceFor(to, p, now, false);
    switch (fromPx, toPx) {
      case (#never(r), _) { refundPending(p, owner, r); return true };
      case (_, #never(r)) { refundPending(p, owner, r); return true };
      case (#wait, _) return false;
      case (_, #wait) return false;
      case (#price(fp), #price(tp)) {
        let fv = if (p.from == Books.ICP) null else view(p.from, fp.price);
        let tv = if (to == Books.ICP) null else view(to, tp.price);
        let rounds = List.empty<(Principal, Nat64, Nat)>();
        if (p.from != Books.ICP) List.add(rounds, (assetAt(p.from).pool, fp.open, fp.price));
        if (to != Books.ICP) List.add(rounds, (assetAt(to).pool, tp.open, tp.price));
        switch (Books.quoteSwap(books, p.from, to, p.amount, minOut, fv, tv, now)) {
          case (#fill(f)) {
            Books.applySwap(books, f, now);
            ignore newOwedPriced(to, owner, f.out, #payout, ?{ t_lock = p.t_lock; rounds = List.toArray(rounds) });
            swaps_filled += 1;
          };
          case (#refund(r)) refundPending(p, owner, r);
        };
        true
      };
    }
  };

  /// A join by a provider (`owner`) or by the DAO (null). The reserve is valued at the first
  /// accepted round after the lock of every asset it holds.
  func settleJoin(p : Pending, owner : ?Principal, minShares : Nat, now : Nat64) : Bool {
    // a reserve of ICP alone needs no price, so the pause is checked here as well
    switch (paused, owner) {
      case (?r, ?o) { refundPending(p, o, "paused:" # r); return true };
      case (?_, null) return false;
      case (null, _) {};
    };
    let prices = Map.empty<Nat, Nat>();
    let rounds = List.empty<(Principal, Nat64, Nat)>();
    for ((i, a) in Map.entries(assets)) {
      if (i != Books.ICP and (i == p.from or Books.asset(books, i).held > 0)) {
        switch (priceFor(i, p, now, false)) {
          case (#price(x)) { Map.add(prices, Nat.compare, i, x.price); List.add(rounds, (a.pool, x.open, x.price)) };
          case (#wait) return false;
          case (#never(r)) {
            switch (owner) {
              case (?o) { refundPending(p, o, r); return true };
              case null { restamp(p, now); return false }; // the DAO's join waits for the next round
            };
          };
        };
      };
    };
    let value = if (p.from == Books.ICP) p.amount else {
      switch (Map.get(prices, Nat.compare, p.from)) { case (?x) Pricing.assetToIcp(p.amount, x); case null return false }
    };
    let reserveValue = switch (Books.reserveValue(books, func(i) { Map.get(prices, Nat.compare, i) })) {
      case (?v) v;
      case null return false;
    };
    let cap : ?(Nat, Nat) = if (p.from == Books.ICP) null else {
      switch (assetAt(p.from).settings, Map.get(prices, Nat.compare, p.from)) {
        case (?s, ?x) ?(x, s.cap_icp);
        case _ return false;
      }
    };
    let feeBps = switch (owner) { case (?_) guards.join_fee_bps; case null 0 };
    switch (Books.quoteJoin(books, p.from, p.amount, value, reserveValue, feeBps, minShares, cap)) {
      case (#fill(f)) {
        switch (owner) {
          case (?o) { Books.applyJoin(books, f, false); ignore newReceiptOwed(o, f.shares, ?{ t_lock = p.t_lock; rounds = List.toArray(rounds) }) };
          case null Books.applyJoin(books, f, true);
        };
        joins_filled += 1;
      };
      case (#refund(r)) {
        switch (owner) {
          case (?o) refundPending(p, o, r);
          case null Books.absorb(Books.asset(books, p.from), p.amount);
        };
      };
    };
    true
  };

  func restamp(p : Pending, now : Nat64) {
    p.t_lock := now;
    p.deadline := NEVER;
  };

  /// Sell a withdrawn part for ICP at the first round after it was queued. Too large for one
  /// round: the largest half that fits is sold and the rest waits for the next round.
  func settleDaoSell(p : Pending, wid : Nat, now : Nat64) : Bool {
    let px = switch (priceFor(p.from, p, now, true)) {
      case (#price(x)) x.price;
      case (#wait) return false;
      case (#never(_)) { restamp(p, now); return false };
    };
    let pv = switch (view(p.from, px)) { case (?v) v; case null { restamp(p, now); return false } };
    var amount = p.amount;
    var tries = 0;
    while (tries < SPLIT_TRIES and amount > 0) {
      switch (Books.quoteSwap(books, p.from, Books.ICP, amount, 0, ?pv, null, now)) {
        case (#fill(f)) {
          Books.applyDaoSell(books, f, now);
          let w = switch (Map.get(withdrawals, Nat.compare, wid)) { case (?w) w; case null Runtime.trap("withdrawal") };
          w.icp += f.out;
          if (amount == p.amount) {
            w.waiting -= 1;
            finishWithdrawal(w, now);
            return true;
          };
          p.amount -= amount;
          restamp(p, now);
          return false;
        };
        case (#refund(r)) {
          if (r == "too-large-for-reserve" or r == "minute-cap" or r == "reserve-short") {
            amount /= 2;
          } else {
            restamp(p, now);
            return false;
          };
        };
      };
      tries += 1;
    };
    restamp(p, now);
    false
  };

  func finishWithdrawal(w : Withdrawal, now : Nat64) {
    if (w.waiting > 0 or w.stage != #converting) return;
    if (w.icp >= w.min_icp and w.icp > 0) {
      Books.payoutStart(Books.asset(books, Books.ICP), w.icp);
      w.stage := #paying;
      payout := ?{ withdrawal = w.id; total = w.icp; var created_at = now; var calling = false };
    } else {
      rejoin(w, now);
    };
  };

  func rejoin(w : Withdrawal, now : Nat64) {
    if (w.icp > 0) {
      Books.daoRejoin(books, w.icp);
      let seq = next_seq;
      next_seq += 1;
      Map.add(pending, Nat.compare, seq, { seq; from = Books.ICP; var amount = w.icp; var t_lock = now; var deadline = NEVER; kind = #dao_join; lock = null });
    };
    w.stage := #rejoined;
    active_withdrawal := null;
  };

  /// Walk the queue from the cursor, at most `max` items.
  func settleBatch(now : Nat64, max : Nat) : Nat {
    let done = List.empty<Nat>();
    var visited = 0;
    var next : ?Nat = null;
    label walk for ((seq, p) in Map.entriesFrom(pending, Nat.compare, settle_cursor)) {
      if (visited >= max) { next := ?seq; break walk };
      visited += 1;
      if (settleOne(p, now)) List.add(done, seq);
    };
    for (seq in List.values(done)) Map.remove(pending, Nat.compare, seq);
    settle_cursor := switch (next) { case (?s) s; case null 0 };
    if (List.size(done) > 0) { lossCheck(); booksCheckLocal() };
    List.size(done)
  };

  /// Anyone may push the queue along; the timer does too.
  public shared func settle() : async Nat { settleBatch(nowNs(), SETTLE_BATCH) };

  // ================================================================ feed

  public type PriceReport = { pool : Principal; price : Wire.Price; observed_at : Nat64 };

  func outcomeText(o : Feed.ReportOutcome) : Text {
    switch (o) {
      case (#accepted_report) "accepted";
      case (#finalized(_)) "finalized";
      case (#held) "held";
      case (#frozen) "frozen";
      case (#late) "late";
      case (#refused(e)) e;
    }
  };

  /// A reporter's prices for one round, one per pair. The caller is the reporter: an update call
  /// is signed by the sender's key and checked by the subnet before it runs.
  public shared ({ caller }) func report(round_open : Nat64, prices : [PriceReport]) : async [Text] {
    let fs = switch (feed_settings) { case (?f) f; case null return ["REJECT:no-feed"] };
    if (not Feed.isReporter(fs, caller)) return ["REJECT:not-a-reporter"];
    if (prices.size() > MAX_ASSETS) return ["REJECT:too-many-prices"];
    let now = nowNs();
    let out = List.empty<Text>();
    var finalized = false;
    for (r in prices.vals()) {
      let t = switch (assetByPool(r.pool)) {
        case (?a) {
          if (a.index == Books.ICP) "REJECT:hub-has-no-feed"
          else if (a.state == #closed and not hasDaoSell(a.index)) "REJECT:pair-closed"
          else {
            let o = Feed.report(a.feed, fs, caller, round_open, Wire.price(r.price), r.observed_at, now);
            switch (o) {
              case (#finalized(acc)) { finalized := true; driftCheck(a, acc.price, now) };
              case _ {};
            };
            outcomeText(o)
          }
        };
        case null "REJECT:unknown-pool";
      };
      List.add(out, t);
    };
    if (finalized) ignore settleBatch(now, SETTLE_BATCH);
    List.toArray(out)
  };

  func hasDaoSell(i : Nat) : Bool {
    for ((_, p) in Map.entries(pending)) {
      switch (p.kind) { case (#dao_sell(_)) { if (p.from == i) return true }; case _ {} };
    };
    false
  };

  /// The backstop: an accepted price outside the band of a fresh XRC reading pauses the pair.
  func driftCheck(a : Asset, price : Nat, now : Nat64) {
    switch (a.settings, freshReading(a, now)) {
      case (?s, ?x) { if (not Xrc.within(price, x.price, s.band_bps)) pauseAsset(a, "xrc-drift") };
      case _ {};
    };
  };

  // ================================================================ collect

  public type CollectArgs = { owed_id : Nat64; commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob; proof_hex : Text; work : Blob };

  func finishCollect(o : Owed, n : Nat) {
    if (o.state == #collected) return;
    if (n != o.amount) { pauseAll("collect-amount"); return };
    let a = assetAt(o.asset);
    if (o.state == #collecting) a.collecting -= o.amount;
    o.state := #collected;
    Books.collected(Books.asset(books, o.asset), o.amount);
  };

  func reopen(o : Owed) {
    if (o.state == #collecting and o.attempts == 0) {
      assetAt(o.asset).collecting -= o.amount;
      o.state := #open;
    };
  };

  /// Collect an owed amount as a note: the owner's deposit proof for exactly the amount, verified
  /// and appended by the paying pool. A collect whose reply was lost is finished by asking again.
  /// The pool's verification is paid or free, as `lock`'s; a record whose free collect failed
  /// verification waits before its next free one.
  public shared ({ caller }) func collect(args : CollectArgs) : async Result<Nat> {
    let o = switch (Map.get(owed, Nat64.compare, args.owed_id)) { case (?o) o; case null return #err("REJECT:unknown-owed") };
    if (not Principal.equal(caller, o.owner)) return #err("REJECT:not-owner");
    // every caller-sized field within its bound before it is hashed or sent on (the pool checks
    // them again)
    switch (Receipts.shapeRejection({ commitment = args.commitment; ephemeral_key = args.ephemeral_key; note_ciphertext = args.note_ciphertext })) {
      case (?e) return #err(e);
      case null {};
    };
    switch (Receipts.proofRejection(args.proof_hex)) { case (?e) return #err(e); case null {} };
    let a = assetAt(o.asset);
    if (o.state == #collected) return #ok(o.amount);
    let now = nowNs();
    let forwarded = takeForward<system>();
    let free = forwarded == 0;
    if (free) {
      if (now < o.retry_after_ns) return #err("REJECT:retry-after");
      switch (freeGate(now, Work.collectDigest(args), args.work)) { case (?e) return #err(e); case null {} };
      Work.hold(work_gate);
    };
    if (o.state == #open) { o.state := #collecting; a.collecting += o.amount };
    o.attempts += 1;
    let pool = poolActor(a);
    let r = try {
      await (with cycles = forwarded) pool.swap_collect({
        owed_id = o.id;
        amount = Nat64.fromNat(o.amount);
        commitment = args.commitment;
        ephemeral_key = args.ephemeral_key;
        note_ciphertext = args.note_ciphertext;
        proof_hex = args.proof_hex;
      })
    } catch (e) {
      #err("CALL:" # Error.message(e))
    } finally {
      o.attempts -= 1;
      if (free) Work.release(work_gate);
    };
    settleForwarded(forwarded);
    switch (r) {
      case (#ok(n)) { finishCollect(o, n); #ok(n) };
      case (#err(e)) {
        if (free and freeVerificationFailed(e)) {
          o.free_failures += 1;
          o.retry_after_ns := nowNs() + Work.backoffNs(o.free_failures, guards.backoff_s);
        };
        // whatever the error, the pool's own record decides
        let known = try { await pool.swap_collected_amount(o.id) } catch (_) { return #err(e) };
        switch (known) {
          case (?n) { finishCollect(o, n); #ok(n) };
          case null { reopen(o); #err(e) };
        }
      };
    }
  };

  public type ReceiptNote = { commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob; value : Nat64; proof_hex : Text };

  /// A provider's shares as receipt notes: one or two deposit proofs whose values sum to exactly
  /// the shares owed (a second note, which may be worth 0, lets a later leave spend two inputs as
  /// the transfer statement requires), verified here against the frozen deposit statement and
  /// appended to this canister's own tree.
  public shared ({ caller }) func collect_receipt(args : { receipt_id : Nat64; notes : [ReceiptNote]; work : Blob }) : async Result<Nat> {
    let k = switch (keys) { case (?k) k; case null return #err("REJECT:receipt-keys-not-ready") };
    let r = switch (Map.get(receiptOwed, Nat64.compare, args.receipt_id)) { case (?r) r; case null return #err("REJECT:unknown-receipt") };
    if (not Principal.equal(caller, r.owner)) return #err("REJECT:not-owner");
    if (r.state != #open) return #err("ALREADY-COLLECTED");
    if (args.notes.size() == 0 or args.notes.size() > 2) return #err("REJECT:receipt-note-count");
    var sum = 0;
    for (n in args.notes.vals()) sum += Nat64.toNat(n.value);
    if (sum != r.shares) return #err("REJECT:receipt-values");
    if (args.notes.size() == 2 and Blob.equal(args.notes[0].commitment, args.notes[1].commitment)) return #err("REJECT:receipt-duplicate-note");
    let notes = List.empty<Receipts.Note>();
    for (n in args.notes.vals()) {
      let note : Receipts.Note = { commitment = n.commitment; ephemeral_key = n.ephemeral_key; note_ciphertext = n.note_ciphertext };
      switch (Receipts.shapeRejection(note)) { case (?e) return #err(e); case null {} };
      switch (Receipts.proofRejection(n.proof_hex)) { case (?e) return #err(e); case null {} };
      List.add(notes, note);
    };
    let now = nowNs();
    let paid = takePaid<system>(args.notes.size());
    if (not paid) {
      if (now < r.retry_after_ns) return #err("REJECT:retry-after");
      switch (freeGate(now, Work.receiptDigest(args.receipt_id, args.notes), args.work)) { case (?e) return #err(e); case null {} };
    };
    for (n in args.notes.vals()) {
      let verdict = Receipts.verifyDeposit(k, n.commitment, n.value, n.proof_hex);
      if (verdict != "ACCEPT") {
        if (not paid) {
          Work.fail(work_gate, workConfig());
          r.free_failures += 1;
          r.retry_after_ns := now + Work.backoffNs(r.free_failures, guards.backoff_s);
        };
        return #err(verdict);
      };
    };
    ignore Receipts.append(receipts, List.toArray(notes));
    r.state := #collected;
    Books.receiptCollected(books, r.shares);
    #ok(Receipts.noteCount(receipts))
  };

  // ================================================================ proof checks for a caller

  func workConfig() : Work.Config {
    {
      d_base = guards.work_d_base;
      d_max = guards.work_d_max;
      step = guards.work_step;
      window_ns = Nat64.fromNat(guards.work_window_s) * NS;
      budget = guards.fail_budget;
    }
  };

  /// A calling canister that attached at least `verify_price` cycles per proof is verified
  /// unconditionally, and the cycles attached are kept.
  func takePaid<system>(proofs : Nat) : Bool {
    if (Cycles.available() < guards.verify_price * proofs) return false;
    proof_cycles_accepted += Cycles.accept<system>(Cycles.available());
    paid_checks += 1;
    true
  };

  /// A caller that attached at least `verify_price` cycles takes the paid path for a proof a pool
  /// verifies (`lock`, `collect`): its cycles are accepted here and attached to the pool's call,
  /// where the pool verifies unconditionally and keeps them. 0 when the caller did not pay.
  func takeForward<system>() : Nat {
    if (Cycles.available() < guards.verify_price) return 0;
    let c = Cycles.accept<system>(Cycles.available());
    paid_checks += 1;
    c
  };

  /// After a pool call that carried `forwarded` cycles: what the pool kept, and what it returned
  /// (which stays here).
  func settleForwarded(forwarded : Nat) {
    if (forwarded == 0) return;
    let back = Cycles.refunded();
    proof_cycles_forwarded += forwarded - back;
    proof_cycles_accepted += back;
  };

  /// A free attempt the pool refused: a failed verification on the free path when the refusal is
  /// the pool's verifier's verdict (a refusal before verifying is not). True when counted.
  func freeVerificationFailed(e : Text) : Bool {
    if (not Work.isVerifierVerdict(e)) return false;
    ignore Work.roll(work_gate, workConfig(), nowNs());
    Work.fail(work_gate, workConfig());
    true
  };

  /// The free path: refused while the window's failure budget is spent, or without enough work.
  func freeGate(now : Nat64, argDigest : Blob, work : Blob) : ?Text {
    let v = Work.roll(work_gate, workConfig(), now);
    if (v.spent) return ?"REJECT:proof-budget-spent";
    if (not Work.passes(selfPrincipal(), v.epoch, argDigest, work, v.d)) return ?"REJECT:work";
    null
  };

  /// The same check without changing anything, for `inspect`.
  func freeGateOpen(argDigest : Blob, work : Blob) : Bool {
    let v = Work.view(work_gate, workConfig(), nowNs());
    not v.spent and Work.passes(selfPrincipal(), v.epoch, argDigest, work, v.d)
  };

  // ================================================================ leave

  func leaveBinding(owner : Principal) : Blob {
    let entries = List.empty<(Text, ICRC3.Value)>();
    List.add(entries, ("domain", #Text("picp-swap-leave/v1")));
    List.add(entries, ("swap", #Blob(Principal.toBlob(selfPrincipal()))));
    List.add(entries, ("owner", #Blob(Principal.toBlob(owner))));
    let digest = Blob.toArray(ICRC3.hashValue(#Map(List.toArray(entries))));
    Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { if (i == 31) 0 else digest[i] }))
  };

  /// Leave: a transfer proof over receipt notes whose public value is the shares leaving, bound
  /// to this canister and the owner, with no fee. Each asset's part, rounded down, is owed to the
  /// owner in that asset's pool. No price is used, so a leave works while pairs are paused.
  public shared func leave(args : { spend : Receipts.Spend; owner : Principal; work : Blob }) : async Result<[Nat64]> {
    let k = switch (keys) { case (?k) k; case null return #err("REJECT:receipt-keys-not-ready") };
    let sp = args.spend;
    if (Principal.isAnonymous(args.owner)) return #err("REJECT:owner-anonymous");
    if (sp.fee != 0) return #err("REJECT:leave-fee");
    let shares = Nat64.toNat(sp.v_pub_out);
    if (shares == 0) return #err("REJECT:leave-zero");
    if (shares > books.shares.receipts_out) return #err("REJECT:leave-exceeds-shares");
    switch (Receipts.spendRejection(receipts, sp)) { case (?e) return #err(e); case null {} };
    if (Books.leaveParts(books, shares).size() == 0) return #err("REJECT:leave-too-small");
    let paid = takePaid<system>(1);
    if (not paid) {
      switch (freeGate(nowNs(), Work.leaveDigest(args.owner, sp), args.work)) { case (?e) return #err(e); case null {} };
    };
    let verdict = Receipts.verifySpend(k, sp, leaveBinding(args.owner));
    if (verdict != "ACCEPT") {
      if (not paid) Work.fail(work_gate, workConfig());
      return #err(verdict);
    };
    ignore Receipts.commitSpend(receipts, sp);
    let parts = Books.applyLeave(books, shares);
    let ids = List.empty<Nat64>();
    for ((i, part) in parts.vals()) List.add(ids, newOwed(i, args.owner, part, #leave));
    leaves += 1;
    #ok(List.toArray(ids))
  };

  // ================================================================ DAO

  public type SettingsChange = {
    #Pause : { pool : ?Principal };
    #Resume : { pool : ?Principal };
    #SetPair : { pool : Principal; settings : Wire.PairSettings };
    #SetGuards : Wire.Guards;
    #SetFeed : Wire.Settings;
  };

  public type PairChange = {
    #Add : { pool : Principal; ledger : Principal; xrc_symbol : Text; xrc_class : Xrc.AssetClass; decimals : Nat8; settings : Wire.PairSettings };
    #Close : { pool : Principal };
  };

  public type TreasuryChange = {
    #RecordSeed : { block : Nat64 };
    #Withdraw : { shares : Nat64; min_icp_e8s : Nat64 };
  };

  // The same changes with the internal records, converted once at the method boundary.
  type SettingsChangeIn = {
    #Pause : { pool : ?Principal };
    #Resume : { pool : ?Principal };
    #SetPair : { pool : Principal; settings : Settings.PairSettings };
    #SetGuards : Settings.Guards;
    #SetFeed : Feed.Settings;
  };

  type PairChangeIn = {
    #Add : { pool : Principal; ledger : Principal; xrc_symbol : Text; xrc_class : Xrc.AssetClass; decimals : Nat8; settings : Settings.PairSettings };
    #Close : { pool : Principal };
  };

  type TreasuryChangeIn = {
    #RecordSeed : { block : Nat64 };
    #Withdraw : { shares : Nat; min_icp_e8s : Nat };
  };

  func settingsIn(c : SettingsChange) : SettingsChangeIn {
    switch (c) {
      case (#Pause(x)) #Pause(x);
      case (#Resume(x)) #Resume(x);
      case (#SetPair({ pool; settings })) #SetPair({ pool; settings = Wire.pairIn(settings) });
      case (#SetGuards(g)) #SetGuards(Wire.guardsIn(g));
      case (#SetFeed(f)) #SetFeed(Wire.feedIn(f));
    }
  };

  func pairsIn(c : PairChange) : PairChangeIn {
    switch (c) {
      case (#Add(x)) #Add({ pool = x.pool; ledger = x.ledger; xrc_symbol = x.xrc_symbol; xrc_class = x.xrc_class; decimals = x.decimals; settings = Wire.pairIn(x.settings) });
      case (#Close(x)) #Close(x);
    }
  };

  func treasuryIn(c : TreasuryChange) : TreasuryChangeIn {
    switch (c) {
      case (#RecordSeed(x)) #RecordSeed(x);
      case (#Withdraw({ shares; min_icp_e8s })) #Withdraw({ shares = Nat64.toNat(shares); min_icp_e8s = Nat64.toNat(min_icp_e8s) });
    }
  };

  func pairOf(p : Principal) : Result<Asset> {
    switch (assetByPool(p)) {
      case (?a) { if (a.index == Books.ICP) #err("REJECT:hub-is-not-a-pair") else #ok(a) };
      case null #err("REJECT:unknown-pool");
    }
  };

  func currentFeedShape() : Feed.Settings {
    switch (feed_settings) { case (?f) f; case null Settings.defaultFeed([], 0) }
  };

  func settingsCheck(c : SettingsChangeIn) : Validation {
    switch (c) {
      case (#Pause({ pool })) {
        switch (pool) {
          case null #Ok("pause every pair");
          case (?p) { switch (pairOf(p)) { case (#ok(a)) #Ok("pause " # a.symbol); case (#err(e)) #Err(e) } };
        }
      };
      case (#Resume({ pool })) {
        switch (pool) {
          case null { if (paused == null) #Err("REJECT:not-paused") else #Ok("resume every pair") };
          case (?p) {
            switch (pairOf(p)) {
              case (#ok(a)) { switch (a.state) { case (#paused(r)) #Ok("resume " # a.symbol # " (paused: " # r # ")"); case _ #Err("REJECT:pair-not-paused") } };
              case (#err(e)) #Err(e);
            }
          };
        }
      };
      case (#SetPair({ pool; settings })) {
        switch (pairOf(pool)) {
          case (#ok(a)) { switch (Settings.pairRejection(settings)) { case (?e) #Err(e); case null #Ok(a.symbol # ": " # Settings.describePair(settings)) } };
          case (#err(e)) #Err(e);
        }
      };
      case (#SetGuards(g)) {
        switch (Settings.guardsRejection(g, currentFeedShape())) { case (?e) #Err(e); case null #Ok("guards: timeout " # Nat.toText(g.timeout_s) # " s, stall " # Nat.toText(g.stall_s) # " s, XRC age " # Nat.toText(g.xrc_max_age_s) # " s") };
      };
      case (#SetFeed(f)) {
        switch (Settings.feedRejection(f, guards)) {
          case (?e) #Err(e);
          case null #Ok("feed: " # Nat.toText(f.k) # " of " # Nat.toText(f.reporters.size()) # " reporters, round " # Nat64.toText(f.round_ns / 1_000_000) # " ms, gap " # Nat64.toText(f.jump_gap_ns / NS) # " s");
        }
      };
    }
  };

  public query func validate_dao_settings(c : SettingsChange) : async Validation { settingsCheck(settingsIn(c)) };

  public shared ({ caller }) func dao_settings(w : SettingsChange) : async () {
    if (not isGovernance(caller)) Runtime.trap("REJECT:not-governance");
    let c = settingsIn(w);
    switch (settingsCheck(c)) { case (#Err(e)) Runtime.trap(e); case (#Ok(_)) {} };
    switch (c) {
      case (#Pause({ pool })) {
        switch (pool) { case null paused := ?"dao"; case (?p) { switch (pairOf(p)) { case (#ok(a)) a.state := #paused("dao"); case (#err(e)) Runtime.trap(e) } } };
      };
      case (#Resume({ pool })) {
        switch (pool) { case null paused := null; case (?p) { switch (pairOf(p)) { case (#ok(a)) a.state := #open; case (#err(e)) Runtime.trap(e) } } };
      };
      case (#SetPair({ pool; settings })) {
        switch (pairOf(pool)) { case (#ok(a)) a.settings := ?settings; case (#err(e)) Runtime.trap(e) };
      };
      case (#SetGuards(g)) guards := g;
      case (#SetFeed(f)) {
        feed_settings := ?f;
        for ((_, a) in Map.entries(assets)) Feed.resetRound(a.feed);
      };
    };
  };

  func pairsCheck(c : PairChangeIn) : Validation {
    switch (c) {
      case (#Add(x)) {
        if (Map.containsKey(poolIndex, Principal.compare, x.pool)) return #Err("REJECT:pool-known");
        if (Map.size(assets) >= MAX_ASSETS) return #Err("REJECT:too-many-pairs");
        if (Principal.isAnonymous(x.pool) or Principal.isAnonymous(x.ledger)) return #Err("REJECT:anonymous");
        if (Nat8.toNat(x.decimals) > 18) return #Err("REJECT:decimals");
        let len = Text.size(x.xrc_symbol);
        if (len == 0 or len > 16) return #Err("REJECT:symbol");
        switch (Settings.pairRejection(x.settings)) { case (?e) return #Err(e); case null {} };
        #Ok("add " # x.xrc_symbol # " pool " # Principal.toText(x.pool) # ": " # Settings.describePair(x.settings))
      };
      case (#Close({ pool })) {
        switch (pairOf(pool)) {
          case (#ok(a)) { if (a.state == #closed) #Err("REJECT:pair-closed") else #Ok("close " # a.symbol # ": no more swaps or joins; leaving still works") };
          case (#err(e)) #Err(e);
        }
      };
    }
  };

  public query func validate_dao_pairs(c : PairChange) : async Validation { pairsCheck(pairsIn(c)) };

  /// Add a pair only if its pool proves the same frozen statements as the hub, so every pool's
  /// notes, and this canister's receipts, are under the same two keys.
  public shared ({ caller }) func dao_pairs(w : PairChange) : async () {
    if (not isGovernance(caller)) Runtime.trap("REJECT:not-governance");
    let c = pairsIn(w);
    switch (pairsCheck(c)) { case (#Err(e)) Runtime.trap(e); case (#Ok(_)) {} };
    switch (c) {
      case (#Add(x)) {
        let hubDigest = switch (vk_source) { case (?v) v.digest; case null Runtime.trap("REJECT:hub-keys-not-adopted") };
        let pool : PoolApi.Pool = actor (Principal.toText(x.pool));
        let anchor = await pool.verifying_key_anchor();
        if (not anchor.frozen) Runtime.trap("REJECT:pool-keys-not-frozen");
        if (not Blob.equal(anchor.digest, hubDigest)) Runtime.trap("REJECT:pool-keys-differ");
        // the pool must be this DAO's: its only controller an SNS root that names this canister's
        // governance and lists the pool among its canisters (the binding the pools make themselves)
        let info = await (actor ("aaaaa-aa") : PoolApi.Management).canister_info({ canister_id = x.pool; num_requested_changes = null });
        if (info.controllers.size() != 1) Runtime.trap("REJECT:pool-not-dao-controlled");
        let controller = info.controllers[0];
        let sns = await (actor (Principal.toText(controller)) : PoolApi.SnsRoot).list_sns_canisters({});
        switch (sns.root, sns.governance) {
          case (?r, ?g) { if (not Principal.equal(r, controller) or not Principal.equal(g, governance)) Runtime.trap("REJECT:pool-not-this-dao") };
          case _ Runtime.trap("REJECT:pool-not-this-dao");
        };
        if (Array.find<Principal>(sns.dapps, func(d) { Principal.equal(d, x.pool) }) == null) Runtime.trap("REJECT:pool-not-a-dao-canister");
        // made again after the awaits: a concurrent Add of the same pool must not both pass
        switch (pairsCheck(c)) { case (#Err(e)) Runtime.trap(e); case (#Ok(_)) {} };
        let i = next_asset;
        next_asset += 1;
        Map.add(assets, Nat.compare, i, newAsset(i, x.pool, x.ledger, x.xrc_symbol, x.xrc_class, Nat8.toNat(x.decimals), ?x.settings));
        Map.add(poolIndex, Principal.compare, x.pool, i);
        Books.addAsset(books, i);
      };
      case (#Close({ pool })) {
        switch (pairOf(pool)) { case (#ok(a)) a.state := #closed; case (#err(e)) Runtime.trap(e) };
      };
    };
  };

  func treasuryCheck(c : TreasuryChangeIn) : Validation {
    switch (c) {
      case (#RecordSeed({ block })) {
        if (Map.containsKey(credited, Nat64.compare, block)) return #Err("REJECT:seed-recorded");
        #Ok("record ICP ledger block " # Nat64.toText(block) # " as the DAO's seed; the hub pool checks it")
      };
      case (#Withdraw({ shares; min_icp_e8s })) {
        if (shares == 0 or shares > books.shares.dao) return #Err("REJECT:dao-shares");
        if (active_withdrawal != null) return #Err("REJECT:withdrawal-in-progress");
        if (min_icp_e8s == 0) return #Err("REJECT:min-icp");
        #Ok("withdraw " # Nat.toText(shares) # " of the DAO's " # Nat.toText(books.shares.dao) # " shares; paid to the SNS treasury if at least " # Nat.toText(min_icp_e8s) # " e8s, else they rejoin")
      };
    }
  };

  public query func validate_dao_treasury(c : TreasuryChange) : async Validation { treasuryCheck(treasuryIn(c)) };

  public shared ({ caller }) func dao_treasury(w : TreasuryChange) : async () {
    if (not isGovernance(caller)) Runtime.trap("REJECT:not-governance");
    let c = treasuryIn(w);
    switch (treasuryCheck(c)) { case (#Err(e)) Runtime.trap(e); case (#Ok(_)) {} };
    switch (c) {
      case (#RecordSeed({ block })) {
        if (Map.containsKey(crediting, Nat64.compare, block)) Runtime.trap("REJECT:seed-in-flight");
        Map.add(crediting, Nat64.compare, block, ());
        let hub = poolActor(assetAt(Books.ICP));
        let amount = try {
          switch (await hub.swap_reserve_credit(block)) {
            case (#ok(v)) v;
            case (#err("ALREADY-CREDITED")) {
              switch (await hub.swap_credited_amount(block)) { case (?v) v; case null Runtime.trap("REJECT:seed-unknown") }
            };
            case (#err(e)) Runtime.trap(e);
          }
        } finally {
          Map.remove(crediting, Nat64.compare, block);
        };
        if (Map.containsKey(credited, Nat64.compare, block)) return; // recorded while this awaited
        Map.add(credited, Nat64.compare, block, amount);
        Books.creditIn(Books.asset(books, Books.ICP), amount);
        let now = nowNs();
        let seq = next_seq;
        next_seq += 1;
        Map.add(pending, Nat.compare, seq, { seq; from = Books.ICP; var amount = amount; var t_lock = now; var deadline = NEVER; kind = #dao_join; lock = null });
      };
      case (#Withdraw({ shares; min_icp_e8s })) {
        let now = nowNs();
        let id = next_withdrawal;
        next_withdrawal += 1;
        let w : Withdrawal = { id; shares; min_icp = min_icp_e8s; var waiting = 0; var icp = 0; var stage = #converting };
        Map.add(withdrawals, Nat.compare, id, w);
        active_withdrawal := ?id;
        for ((i, part) in Books.applyDaoLeave(books, shares).vals()) {
          if (i == Books.ICP) w.icp += part else {
            w.waiting += 1;
            let seq = next_seq;
            next_seq += 1;
            Map.add(pending, Nat.compare, seq, { seq; from = i; var amount = part; var t_lock = now; var deadline = NEVER; kind = #dao_sell({ withdrawal = id }); lock = null });
            assetAt(i).xrc_demand_ns := now;
          };
        };
        finishWithdrawal(w, now);
      };
    };
  };

  // ================================================================ background work

  /// Adopt the hub's frozen keys for the receipt tree: read them, then prepare the transfer key,
  /// then the deposit key, each in its own message.
  func setupStep() : async () {
    if (keysReady() or setup_inflight) return;
    switch (vk_source, transfer_key) {
      case (null, _) {
        setup_inflight := true;
        try {
          let a = await poolActor(assetAt(Books.ICP)).verifying_key_anchor();
          if (a.frozen and vk_source == null) vk_source := ?{ transfer_hex = a.transfer_vk_hex; deposit_hex = a.deposit_vk_hex; digest = a.digest };
        } catch (_) {} finally { setup_inflight := false };
      };
      case (?v, null) { transfer_key := Receipts.prepareOne(v.transfer_hex) };
      case (?v, ?t) { switch (Receipts.prepareOne(v.deposit_hex)) { case (?d) keys := ?{ transfer = t; deposit = d }; case null {} } };
    };
  };

  func xrcStep(a : Asset, now : Nat64) : async () {
    if (a.index == Books.ICP or a.xrc_inflight) return;
    let maxAge = Nat64.fromNat(guards.xrc_max_age_s) * NS;
    if (a.xrc_demand_ns + maxAge < now) return; // nothing needs a reading
    let refresh = Nat64.fromNat(guards.xrc_refresh_s) * NS;
    switch (a.xrc_reading) { case (?r) { if (r.read_at_ns + refresh > now) return }; case null {} };
    if (a.xrc_attempt_ns + XRC_RETRY_NS > now) return;
    a.xrc_inflight := true;
    a.xrc_attempt_ns := now;
    let svc : Xrc.Service = actor (Principal.toText(xrcId));
    try {
      let r = await (with cycles = Xrc.CALL_CYCLES) svc.get_exchange_rate({
        base_asset = { symbol = a.symbol; class_ = a.xrc_class };
        quote_asset = { symbol = "ICP"; class_ = #Cryptocurrency };
        timestamp = null;
      });
      let at = nowNs();
      switch (r) {
        case (#Ok(rate)) {
          switch (Xrc.check(rate, a.decimals, guards.min_sources, guards.max_spread_bps, at)) {
            case (#ok(reading)) {
              let newer = switch (a.xrc_reading) { case (?old) reading.rate_time_ns >= old.rate_time_ns; case null true };
              if (newer) a.xrc_reading := ?reading;
              a.xrc_error := "";
              switch (a.feed.last) {
                case (?acc) { if (feedAlive(a, at)) driftCheck(a, acc.price, at) };
                case null {};
              };
            };
            case (#err(e)) a.xrc_error := e;
          };
        };
        case (#Err(e)) a.xrc_error := "xrc:" # debugErr(e);
      };
    } catch (e) {
      a.xrc_error := "xrc-call:" # Error.message(e);
    } finally {
      a.xrc_inflight := false;
    };
  };

  func debugErr(e : Xrc.ExchangeRateError) : Text {
    switch (e) {
      case (#AnonymousPrincipalNotAllowed) "anonymous";
      case (#Pending) "pending";
      case (#CryptoBaseAssetNotFound) "base-not-found";
      case (#CryptoQuoteAssetNotFound) "quote-not-found";
      case (#StablecoinRateNotFound) "stablecoin-not-found";
      case (#StablecoinRateTooFewRates) "stablecoin-too-few";
      case (#StablecoinRateZeroRate) "stablecoin-zero";
      case (#ForexInvalidTimestamp) "forex-timestamp";
      case (#ForexBaseAssetNotFound) "forex-base";
      case (#ForexQuoteAssetNotFound) "forex-quote";
      case (#ForexAssetsNotFound) "forex-assets";
      case (#RateLimited) "rate-limited";
      case (#NotEnoughCycles) "not-enough-cycles";
      case (#FailedToAcceptCycles) "failed-to-accept-cycles";
      case (#InconsistentRatesReceived) "inconsistent";
      case (#Other(o)) "other:" # o.description;
    }
  };

  func sweepStep(a : Asset, now : Nat64) : async () {
    let ab = Books.asset(books, a.index);
    let s = switch (a.sweep) {
      case (?s) s;
      case null {
        if (ab.fees == 0 or a.last_sweep_ns + SWEEP_INTERVAL_NS > now) return;
        // the pools take a nat64 amount: a larger total is swept in more than one sweep
        let s : Sweep = { id = next_sweep; amount = Nat.min(ab.fees, MAX_NAT64); var calling = false };
        next_sweep += 1;
        Books.sweepStart(ab, s.amount);
        a.sweep := ?s;
        a.last_sweep_ns := now;
        s
      };
    };
    if (s.calling) return;
    s.calling := true;
    let pool = poolActor(a);
    try {
      let r = await pool.swap_fee_sweep(s.id, Nat64.fromNat(s.amount));
      let known : ?Nat = switch (r) {
        case (#ok(n)) ?n;
        case (#err(_)) await pool.swap_swept_amount(s.id);
      };
      switch (a.sweep) {
        case (?cur) {
          if (cur.id == s.id) {
            switch (known) {
              case (?n) { if (n == s.amount) Books.sweepDone(ab, s.amount) else pauseAll("sweep-amount"); a.sweep := null };
              case null { Books.sweepUndone(ab, s.amount); a.sweep := null };
            };
          };
        };
        case null {};
      };
    } catch (_) {} finally { s.calling := false };
  };

  func payoutStep(now : Nat64) : async () {
    let po = switch (payout) { case (?p) p; case null return };
    if (po.calling) return;
    po.calling := true;
    let hub = poolActor(assetAt(Books.ICP));
    let total = Nat64.fromNat(po.total);
    try {
      let r = await hub.swap_reserve_payout(total, po.created_at);
      let state = switch (r) { case (#ok(_)) #done; case (#err(_)) await hub.swap_payout_state(total, po.created_at) };
      let refusedBelowFee = switch (r) { case (#err(e)) Text.startsWith(e, #text "REJECT:swap-payout-below-fee"); case _ false };
      switch (payout) {
        case (?cur) {
          if (cur.withdrawal == po.withdrawal) {
            switch (state) {
              case (#done) {
                Books.payoutDone(Books.asset(books, Books.ICP), po.total);
                markWithdrawal(po.withdrawal, #paid);
                payout := null;
                active_withdrawal := null;
              };
              case (#pending) { ignore await hub.resume_prepaid() };
              case (#none) {
                if (refusedBelowFee) {
                  Books.payoutUndone(Books.asset(books, Books.ICP), po.total);
                  payout := null;
                  switch (Map.get(withdrawals, Nat.compare, po.withdrawal)) { case (?w) rejoin(w, now); case null {} };
                } else if (po.created_at + PAYOUT_FRESH_NS < now) {
                  po.created_at := now; // a new intent: the old one is neither done nor pending
                };
              };
            };
          };
        };
        case null {};
      };
    } catch (_) {} finally { po.calling := false };
  };

  func markWithdrawal(id : Nat, stage : { #converting; #paying; #paid; #rejoined }) {
    switch (Map.get(withdrawals, Nat.compare, id)) { case (?w) w.stage := stage; case null {} };
  };

  /// Every pool's own record against these books, with what is in flight between them allowed
  /// for. A difference that in-flight work cannot explain pauses every pair.
  func crossCheckStep(now : Nat64) : async () {
    if (cross_check_inflight or last_cross_check_ns + CROSS_CHECK_INTERVAL_NS > now) return;
    cross_check_inflight := true;
    last_cross_check_ns := now;
    try {
      for (a in assetList().vals()) {
        let i = a.index;
        let ab = Books.asset(books, i);
        let before = (ab.locked, ab.credited, ab.collected, ab.swept, ab.paid);
        let st = await poolActor(a).swap_status();
        a.pool_lock_count := st.lock_count;
        let ab1 = Books.asset(books, i);
        let known = Nat64.toNat(a.lock_cursor) + Map.size(a.seen_above);
        if (st.lock_count > known) ignore await sync(a.pool);
        switch (crossCheckVerdict(a, st, before, ab1)) {
          case (?e) { pauseAll("books:" # a.symbol # ":" # e); cross_check_note := a.symbol # ": " # e };
          case null {};
        };
      };
    } catch (e) {
      cross_check_note := "call: " # Error.message(e);
    } finally {
      cross_check_inflight := false;
    };
  };

  func crossCheckVerdict(a : Asset, st : PoolApi.SwapStatus, before : (Nat, Nat, Nat, Nat, Nat), ab : Books.AssetBooks) : ?Text {
    let (locked0, credited0, collected0, swept0, paid0) = before;
    if (not Principal.equal(st.swap_canister, selfPrincipal())) return ?"pool-names-another-swap-canister";
    if (st.locked_total < locked0) return ?"locked";
    if (st.collected_total < collected0 or st.collected_total > ab.collected + a.collecting) return ?"collected";
    if (st.swept_total < swept0 or st.swept_total > ab.swept + ab.sweeping) return ?"swept";
    if (st.paid_total < paid0 or st.paid_total > ab.paid + ab.paying) return ?"paid";
    let creditsInFlight = a.index == Books.ICP and Map.size(crediting) > 0;
    if (not creditsInFlight and (st.credited_total < credited0 or st.credited_total > ab.credited)) return ?"credited";
    // the pool's own identity
    let poolSide : Int = st.credited_total + st.locked_total - st.collected_total - st.swept_total - st.paid_total;
    if (st.payout_pending) { if (st.reserve > poolSide) return ?"reserve" } else { if (st.reserve != poolSide) return ?"reserve" };
    // with nothing in flight and every lock recorded, the reserve record is exactly the books
    let quiet = a.collecting == 0 and ab.sweeping == 0 and ab.paying == 0 and not creditsInFlight and not st.payout_pending
      and st.locked_total == ab.locked and st.collected_total == ab.collected and st.swept_total == ab.swept
      and st.paid_total == ab.paid and st.credited_total == ab.credited;
    if (quiet and st.reserve != Books.parts(ab)) return ?"reserve-vs-books";
    null
  };

  /// The local identities, after every batch: a failure means the arithmetic is wrong somewhere,
  /// so every pair stops until the DAO looks.
  func booksCheckLocal() {
    for ((i, _) in Map.entries(assets)) {
      if (not Books.identityHolds(Books.asset(books, i))) pauseAll("books-identity:" # Nat.toText(i));
    };
    if (not Books.sharesHold(books.shares)) pauseAll("shares-identity");
  };

  /// A share's value at the latest accepted prices, against its value an hour of snapshots ago at
  /// the same prices: a drop beyond the loss setting pauses every pair.
  func lossCheck() {
    if (books.shares.total == 0) return;
    let priceOf = func(i : Nat) : ?Nat {
      switch (assetAt(i).feed.last) { case (?a) ?a.price; case null null }
    };
    let now = switch (Books.reserveValue(books, priceOf)) { case (?v) v; case null return };
    for (s in List.values(snapshots)) {
      if (s.shares > 0) {
        var then = 0;
        for ((i, h) in s.held.vals()) {
          if (i == Books.ICP) then += h else {
            switch (priceOf(i)) { case (?p) then += Pricing.assetToIcp(h, p); case null return };
          };
        };
        // now / total < then / s.shares * (1 - loss)
        if (now * s.shares * 10_000 < then * books.shares.total * (10_000 - guards.loss_pause_bps)) {
          pauseAll("loss");
          return;
        };
      };
    };
  };

  func snapshotStep(now : Nat64) {
    if (last_snapshot_ns + SNAPSHOT_INTERVAL_NS > now) return;
    last_snapshot_ns := now;
    let held = List.empty<(Nat, Nat)>();
    for ((i, ab) in Map.entries(books.assets)) List.add(held, (i, ab.held));
    List.add(snapshots, { at_ns = now; held = List.toArray(held); shares = books.shares.total });
    if (List.size(snapshots) > SNAPSHOTS) {
      let kept = List.empty<Snapshot>();
      var k = List.size(snapshots) - SNAPSHOTS;
      while (k < List.size(snapshots)) { List.add(kept, List.at(snapshots, k)); k += 1 };
      List.clear(snapshots);
      for (s in List.values(kept)) List.add(snapshots, s);
    };
  };

  func xrcDue(a : Asset, now : Nat64) : Bool {
    if (a.index == Books.ICP or a.xrc_inflight or a.state == #closed and not hasDaoSell(a.index)) return false;
    if (a.xrc_demand_ns + Nat64.fromNat(guards.xrc_max_age_s) * NS < now) return false;
    switch (a.xrc_reading) { case (?r) { if (r.read_at_ns + Nat64.fromNat(guards.xrc_refresh_s) * NS > now) return false }; case null {} };
    a.xrc_attempt_ns + XRC_RETRY_NS <= now
  };

  func sweepDue(a : Asset, now : Nat64) : Bool {
    switch (a.sweep) {
      case (?s) not s.calling;
      case null Books.asset(books, a.index).fees > 0 and a.last_sweep_ns + SWEEP_INTERVAL_NS <= now;
    }
  };

  /// Settle synchronously; start each other piece of work as its own message, only when it is
  /// due, so a slow XRC or pool call never holds settlement up.
  func tick() : async () {
    let now = nowNs();
    ignore settleBatch(now, SETTLE_BATCH);
    snapshotStep(now);
    if (not keysReady() and not setup_inflight) ignore setupStep();
    for (a in assetList().vals()) {
      if (xrcDue(a, now)) ignore xrcStep(a, now);
      if (sweepDue(a, now)) ignore sweepStep(a, now);
    };
    switch (payout) { case (?po) { if (not po.calling) ignore payoutStep(now) }; case null {} };
    if (not cross_check_inflight and last_cross_check_ns + CROSS_CHECK_INTERVAL_NS <= now) ignore crossCheckStep(now);
  };

  transient let _tick = Timer.recurringTimer<system>(#seconds TICK_SECONDS, tick);

  // ================================================================ queries

  public type AssetView = {
    index : Nat;
    pool : Principal;
    symbol : Text;
    state : AssetState;
    settings : ?Wire.PairSettings;
    feed_alive : Bool;
    last_round : ?Feed.Accepted;
    xrc : ?Xrc.Reading;
    xrc_error : Text;
    rounds_accepted : Nat;
    rounds_dead : Nat;
    rounds_frozen : Nat;
    rounds_held : Nat;
    late_reports : Nat;
    frozen_outlier : ?Principal;
    books : { held : Nat; pending : Nat; owed : Nat; fees : Nat; sweeping : Nat; paying : Nat; dao_due : Nat; collecting : Nat; reserve_record : Int };
  };

  func assetView(a : Asset, now : Nat64) : AssetView {
    let ab = Books.asset(books, a.index);
    {
      index = a.index;
      pool = a.pool;
      symbol = a.symbol;
      state = a.state;
      settings = switch (a.settings) { case (?p) ?Wire.pairOut(p); case null null };
      feed_alive = a.index == Books.ICP or feedAlive(a, now);
      last_round = a.feed.last;
      xrc = a.xrc_reading;
      xrc_error = a.xrc_error;
      rounds_accepted = a.feed.accepted_count;
      rounds_dead = a.feed.dead_count;
      rounds_frozen = a.feed.frozen_count;
      rounds_held = a.feed.held_count;
      late_reports = a.feed.late_count;
      frozen_outlier = Feed.frozenOutlier(a.feed);
      books = {
        held = ab.held;
        pending = ab.pending;
        owed = ab.owed;
        fees = ab.fees;
        sweeping = ab.sweeping;
        paying = ab.paying;
        dao_due = ab.dao_due;
        collecting = a.collecting;
        reserve_record = Books.poolSide(ab);
      };
    }
  };

  public query func status() : async {
    paused : ?Text;
    feed : ?Wire.Settings;
    guards : Wire.Guards;
    assets : [AssetView];
    shares : { total : Nat; locked : Nat; dao : Nat; receipts_owed : Nat; receipts_out : Nat };
    pending : Nat;
    receipt_keys_ready : Bool;
    receipt_root : Blob;
    swaps_filled : Nat;
    joins_filled : Nat;
    refunds : Nat;
    leaves : Nat;
    cross_check_note : Text;
    withdrawal : ?{ id : Nat; shares : Nat; min_icp : Nat; waiting : Nat; icp : Nat };
    proofs : { difficulty : Nat; epoch : Nat; window_start_ns : Nat64; window_ns : Nat64; failures : Nat; inflight : Nat; budget_spent : Bool; paid_checks : Nat; cycles_accepted : Nat; cycles_forwarded : Nat };
  } {
    let now = nowNs();
    let views = List.empty<AssetView>();
    for ((_, a) in Map.entries(assets)) List.add(views, assetView(a, now));
    {
      paused;
      feed = switch (feed_settings) { case (?f) ?Wire.feedOut(f); case null null };
      guards = Wire.guardsOut(guards);
      assets = List.toArray(views);
      shares = { total = books.shares.total; locked = books.shares.locked; dao = books.shares.dao; receipts_owed = books.shares.receipts_owed; receipts_out = books.shares.receipts_out };
      pending = Map.size(pending);
      receipt_keys_ready = keysReady();
      receipt_root = receipts.root;
      swaps_filled;
      joins_filled;
      refunds;
      leaves;
      cross_check_note;
      withdrawal = switch (active_withdrawal) {
        case (?id) { switch (Map.get(withdrawals, Nat.compare, id)) { case (?w) ?{ id; shares = w.shares; min_icp = w.min_icp; waiting = w.waiting; icp = w.icp }; case null null } };
        case null null;
      };
      proofs = do {
        let c = workConfig();
        let v = Work.view(work_gate, c, now);
        { difficulty = v.d; epoch = v.epoch; window_start_ns = v.window_start_ns; window_ns = c.window_ns; failures = v.failures; inflight = v.inflight; budget_spent = v.spent; paid_checks; cycles_accepted = proof_cycles_accepted; cycles_forwarded = proof_cycles_forwarded }
      };
    }
  };

  public type OwedView = { id : Nat64; pool : Principal; owner : Principal; amount : Nat; kind : OwedKind; created_ns : Nat64; priced : ?Priced; state : CollectState; retry_after_ns : Nat64 };

  func owedView(o : Owed) : OwedView {
    { id = o.id; pool = assetAt(o.asset).pool; owner = o.owner; amount = o.amount; kind = o.kind; created_ns = o.created_ns; priced = o.priced; state = o.state; retry_after_ns = o.retry_after_ns }
  };

  public query func owed_of(owner : Principal, start64 : Nat64, count64 : Nat64) : async [OwedView] {
    let (start, count) = (Nat64.toNat(start64), Nat64.toNat(count64));
    switch (Map.get(owedByOwner, Principal.compare, owner)) {
      case (?l) {
        let n = List.size(l);
        if (start >= n) return [];
        let len = Nat.min(Nat.min(count, PAGE_MAX), n - start);
        Array.tabulate<OwedView>(len, func(k) {
          switch (Map.get(owed, Nat64.compare, List.at(l, start + k))) { case (?o) owedView(o); case null Runtime.trap("owed index") }
        })
      };
      case null [];
    }
  };

  public query func receipts_owed_of(owner : Principal, start64 : Nat64, count64 : Nat64) : async [{ id : Nat64; shares : Nat; state : CollectState; created_ns : Nat64; priced : ?Priced; retry_after_ns : Nat64 }] {
    let (start, count) = (Nat64.toNat(start64), Nat64.toNat(count64));
    switch (Map.get(receiptsByOwner, Principal.compare, owner)) {
      case (?l) {
        let n = List.size(l);
        if (start >= n) return [];
        let len = Nat.min(Nat.min(count, PAGE_MAX), n - start);
        Array.tabulate<{ id : Nat64; shares : Nat; state : CollectState; created_ns : Nat64; priced : ?Priced; retry_after_ns : Nat64 }>(len, func(k) {
          switch (Map.get(receiptOwed, Nat64.compare, List.at(l, start + k))) {
            case (?r) ({ id = r.id; shares = r.shares; state = r.state; created_ns = r.created_ns; priced = r.priced; retry_after_ns = r.retry_after_ns });
            case null Runtime.trap("receipt index");
          }
        })
      };
      case null [];
    }
  };

  public query func pending_page(start64 : Nat64, count64 : Nat64) : async [{ seq : Nat; from : Principal; amount : Nat; t_lock : Nat64; deadline : Nat64; kind : PendingKind }] {
    let (start, count) = (Nat64.toNat(start64), Nat64.toNat(count64));
    let out = List.empty<{ seq : Nat; from : Principal; amount : Nat; t_lock : Nat64; deadline : Nat64; kind : PendingKind }>();
    label walk for ((seq, p) in Map.entriesFrom(pending, Nat.compare, start)) {
      if (List.size(out) >= Nat.min(count, PAGE_MAX)) break walk;
      List.add(out, { seq; from = assetAt(p.from).pool; amount = p.amount; t_lock = p.t_lock; deadline = p.deadline; kind = p.kind });
    };
    List.toArray(out)
  };

  /// What a reporter needs each round: this canister's clock (a reporter follows it, not its own),
  /// the round settings, and the pools that take prices.
  public query func round_info() : async { now : Nat64; round_ns : Nat64; deadline_ns : Nat64; max_report_age_ns : Nat64; pools : [Principal] } {
    let pools = List.empty<Principal>();
    for ((i, a) in Map.entries(assets)) { if (i != Books.ICP and a.state != #closed) List.add(pools, a.pool) };
    switch (feed_settings) {
      case (?f) ({ now = nowNs(); round_ns = f.round_ns; deadline_ns = f.deadline_ns; max_report_age_ns = f.max_report_age_ns; pools = List.toArray(pools) });
      case null ({ now = nowNs(); round_ns = 0; deadline_ns = 0; max_report_age_ns = 0; pools = List.toArray(pools) });
    }
  };

  /// A pair's accepted rounds still held (the last 512), oldest first. Anyone can audit every
  /// price the feed accepted against the venues.
  public query func rounds_page(pool : Principal, start64 : Nat64, count64 : Nat64) : async [Feed.Accepted] {
    let (start, count) = (Nat64.toNat(start64), Nat64.toNat(count64));
    for ((_, a) in Map.entries(assets)) {
      if (Principal.equal(a.pool, pool)) return Feed.historyPage(a.feed, start, Nat.min(count, PAGE_MAX));
    };
    []
  };

  public query func receipt_notes(start : Nat64, count : Nat64) : async [Receipts.Note] { Receipts.notesPage(receipts, Nat64.toNat(start), Nat64.toNat(count)) };

  public query func leave_binding(owner : Principal) : async Blob { leaveBinding(owner) };

  public query func encode_terms(t : Wire.Terms) : async ?Blob { Terms.encode(Wire.termsIn(t)) };

  /// The books cross-check (v2 §6), readable by anyone: each pool's own reserve record beside
  /// these books. A composite query, so it reads pools on this canister's subnet.
  public composite query func books_view() : async [{ pool : Principal; symbol : Text; reserve_record : Nat; books : Int; parts : Nat; equal : Bool; verdict : Text }] {
    let out = List.empty<{ pool : Principal; symbol : Text; reserve_record : Nat; books : Int; parts : Nat; equal : Bool; verdict : Text }>();
    for ((i, a) in Map.entries(assets)) {
      let ab = Books.asset(books, i);
      let st = await poolActor(a).swap_status();
      let verdict = switch (crossCheckVerdict(a, st, (ab.locked, ab.credited, ab.collected, ab.swept, ab.paid), ab)) { case (?e) e; case null "" };
      List.add(out, { pool = a.pool; symbol = a.symbol; reserve_record = st.reserve; books = Books.poolSide(ab); parts = Books.parts(ab); equal = verdict == "" and st.reserve == Books.parts(ab); verdict });
    };
    List.toArray(out)
  };

  // ================================================================ ingress size

  /// Ingress only (calls from canisters are not inspected): every argument within 16 KiB, and no
  /// query method taken as an update this canister would pay for. The DAO
  /// methods refuse every caller but SNS governance as their first step. A method added later is
  /// refused here until it is named.
  system func inspect({
    arg : Blob;
    msg : {
      #lock : () -> (Principal, PoolApi.SwapLockArgs, Blob); #sync : Any; #settle : Any; #report : Any; #collect : () -> CollectArgs;
      #collect_receipt : () -> { receipt_id : Nat64; notes : [ReceiptNote]; work : Blob };
      #leave : () -> { spend : Receipts.Spend; owner : Principal; work : Blob };
      #dao_settings : Any; #dao_pairs : Any; #dao_treasury : Any;
      #validate_dao_settings : Any; #validate_dao_pairs : Any; #validate_dao_treasury : Any;
      #status : Any; #owed_of : Any; #receipts_owed_of : Any; #pending_page : Any; #round_info : Any; #rounds_page : Any;
      #receipt_notes : Any; #leave_binding : Any; #encode_terms : Any; #books_view : Any;
    };
  }) : Bool {
    if (arg.size() > MAX_ARG_BYTES) return false;
    switch (msg) {
      case (#sync _ or #settle _ or #report _) true;
      // ingress carries no cycles, so these are always on the free path: an argument without the
      // work, or sent while the budget is spent or before its record's wait, is never inducted
      case (#lock(f)) { let (pool, a, work) = f(); freeGateOpen(Work.lockDigest(pool, a), work) };
      case (#collect(f)) {
        let a = f();
        switch (Map.get(owed, Nat64.compare, a.owed_id)) { case (?o) { if (nowNs() < o.retry_after_ns) return false }; case null {} };
        freeGateOpen(Work.collectDigest(a), a.work)
      };
      case (#leave(f)) { let a = f(); freeGateOpen(Work.leaveDigest(a.owner, a.spend), a.work) };
      case (#collect_receipt(f)) {
        let a = f();
        switch (Map.get(receiptOwed, Nat64.compare, a.receipt_id)) { case (?r) { if (nowNs() < r.retry_after_ns) return false }; case null {} };
        freeGateOpen(Work.receiptDigest(a.receipt_id, a.notes), a.work)
      };
      case (#dao_settings _ or #dao_pairs _ or #dao_treasury _) true;
      case _ false;
    }
  };
};
