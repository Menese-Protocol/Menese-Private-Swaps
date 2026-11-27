/// The consensus price feed: rounds, reports, finalization, the jump breaker.
///
/// Pure rules over one pair's feed state. The actor owns the state and the clock; every function
/// here takes `now` (nanoseconds, the canister's own `Time.now()`) as an argument and never reads
/// a clock itself, so the rules can be tested exactly.
///
/// A round is a window of the canister's clock: round `j` opens at `j * R` and takes reports until
/// its deadline, `j * R + D` (D <= R). A reporter names the round it reports for; a report for any
/// other round than the open one is refused. Reports carry the time the reporter read its
/// exchanges (`observed_at`); it must lie inside the round (never before the round opened) and be
/// at most `max_report_age` old when the report lands.
///
/// A round FINALIZES when it holds at least `k` reports and every report lies within `spread_bps`
/// of their median (the largest deviation from the median, not a standard deviation: that bounds
/// every accepted report's distance from the price, so k - 1 colluding reporters can move the price
/// by at most `spread_bps`, while a standard deviation lets one far report hide among many close
/// ones). If the reports spread further, the round is FROZEN: it never finalizes, and later reports
/// cannot unfreeze it (a far report stays far). A split is never averaged.
///
/// A finalized round is ACCEPTED (it can price swaps) unless its price jumps more than `jump_bps`
/// from the last accepted round. Then it is HELD, and so is every later round, until either
/// - the held rounds form an unbroken chain (each within `confirm_bps` of the one before it) whose
///   last round is sampled at least `jump_gap` after its first: that last round is accepted; or
/// - a round comes back within `jump_bps` of the last accepted price (accepted: the jump reverted).
/// A held round more than `confirm_bps` from the one before it starts a new chain. The clock runs on
/// sample times, never on arrival or round-open times. The held price follows the chain, so a
/// steady move of up to `confirm_bps` per round confirms after `jump_gap` instead of holding
/// forever; a faster move stays held until it slows, then confirms `jump_gap` later. A chain
/// is never kept across a break, not even one in the same direction: a level reached by a break is
/// confirmed only by `jump_gap` of its own observations. A held price never prices a
/// swap. The XRC band (in the swap canister) is the absolute anchor the breaker lacks.
///
/// A round still open at its deadline without finalizing is DEAD. A report that arrives after its
/// round finalized, froze or was held is recorded for observability only and changes nothing.
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";

module {
  /// Fixed in code; no setting, DAO call or test hook can go below them.
  public let MIN_K : Nat = 3;
  public let MAX_REPORTERS : Nat = 16;
  public let MAX_SPREAD_BPS : Nat = 50;
  public let MAX_JUMP_BPS : Nat = 250;
  public let MAX_CONFIRM_BPS : Nat = 50;
  /// Accepted rounds kept per pair. At the shortest round (2 s) this is 1,024 s, longer than the
  /// longest settlement timeout (600 s), so a waiting lock's round is never evicted before its
  /// timeout; an eviction is recorded anyway, and settlement refuses to guess past one.
  public let HISTORY : Nat = 512;
  /// Prices are ICP base units per asset base unit, times 10^18.
  public let PRICE_SCALE : Nat = 1_000_000_000_000_000_000;
  public let MAX_PRICE : Nat = 340_282_366_920_938_463_463_374_607_431_768_211_455; // 2^128 - 1

  public type Settings = {
    round_ns : Nat64; // R
    deadline_ns : Nat64; // D, 0 < D <= R
    max_report_age_ns : Nat64;
    k : Nat;
    reporters : [Principal];
    spread_bps : Nat;
    jump_bps : Nat;
    confirm_bps : Nat;
    jump_gap_ns : Nat64;
  };

  public type Report = { reporter : Principal; price : Nat; observed_at : Nat64; landed_at : Nat64 };

  public type Accepted = { open_ns : Nat64; price : Nat; sample_ns : Nat64; finalized_ns : Nat64 };

  public type Status = { #open; #accepted; #held; #frozen };

  public type PairFeed = {
    var cur_open : Nat64; // open time of the round in `cur_reports`; 0 = none yet
    var cur_reports : [Report];
    var cur_status : Status;
    // the jump being held: the latest held price, and the sample time its unbroken chain began
    var hold : ?{ price : Nat; since_ns : Nat64 };
    var last : ?Accepted;
    ring : [var ?Accepted]; // accepted rounds; `head` is the next slot written
    var head : Nat;
    var count : Nat;
    var evicted_through : Nat64; // open time of the newest round evicted from the ring; 0 = none
    var accepted_count : Nat;
    var dead_count : Nat;
    var frozen_count : Nat;
    var held_count : Nat;
    var late_count : Nat;
  };

  public func newPairFeed() : PairFeed {
    {
      var cur_open = 0;
      var cur_reports = [];
      var cur_status = #open;
      var hold = null;
      var last = null;
      ring = VarArray.repeat<?Accepted>(null, HISTORY);
      var head = 0;
      var count = 0;
      var evicted_through = 0;
      var accepted_count = 0;
      var dead_count = 0;
      var frozen_count = 0;
      var held_count = 0;
      var late_count = 0;
    }
  };

  /// Why a feed configuration is refused, or null. The floor of 3 and the majority rule are here,
  /// not in the caller, so no path that writes settings can skip them.
  public func settingsRejection(s : Settings) : ?Text {
    let n = s.reporters.size();
    if (n > MAX_REPORTERS) return ?"REJECT:feed-too-many-reporters";
    var i = 0;
    while (i < n) {
      var j = i + 1;
      while (j < n) {
        if (Principal.equal(s.reporters[i], s.reporters[j])) return ?"REJECT:feed-duplicate-reporter";
        j += 1;
      };
      if (Principal.isAnonymous(s.reporters[i])) return ?"REJECT:feed-anonymous-reporter";
      i += 1;
    };
    if (s.k < MIN_K) return ?"REJECT:feed-k-below-3";
    if (s.k > n) return ?"REJECT:feed-k-above-n";
    if (2 * s.k <= n) return ?"REJECT:feed-k-not-majority";
    if (s.round_ns < 2_000_000_000 or s.round_ns > 60_000_000_000) return ?"REJECT:feed-round-length";
    if (s.deadline_ns == 0 or s.deadline_ns > s.round_ns) return ?"REJECT:feed-deadline";
    if (s.max_report_age_ns == 0 or s.max_report_age_ns > s.round_ns) return ?"REJECT:feed-report-age";
    if (s.spread_bps < 5 or s.spread_bps > MAX_SPREAD_BPS) return ?"REJECT:feed-spread";
    if (s.jump_bps < 50 or s.jump_bps > MAX_JUMP_BPS) return ?"REJECT:feed-jump";
    if (s.confirm_bps < 5 or s.confirm_bps > MAX_CONFIRM_BPS or s.confirm_bps > s.jump_bps) return ?"REJECT:feed-confirm";
    if (s.jump_gap_ns < 2 * s.round_ns or s.jump_gap_ns > 600_000_000_000) return ?"REJECT:feed-jump-gap";
    null
  };

  public func isReporter(s : Settings, p : Principal) : Bool {
    for (r in s.reporters.vals()) { if (Principal.equal(r, p)) return true };
    false
  };

  public func roundOpen(s : Settings, now : Nat64) : Nat64 { (now / s.round_ns) * s.round_ns };

  /// Lower median: the middle value, or the lower of the two middle values. Never a mean.
  public func lowerMedian(xs : [Nat]) : Nat {
    let sorted = Array.sort<Nat>(xs, Nat.compare);
    sorted[(sorted.size() - 1) / 2]
  };

  func within(a : Nat, b : Nat, bps : Nat) : Bool {
    // |a - b| <= b * bps / 10_000, exactly
    let diff = if (a >= b) a - b else b - a;
    diff * 10_000 <= b * bps
  };

  /// Close the round in progress if `now` is past it: a round that is still open is dead.
  public func rollover(f : PairFeed, s : Settings, now : Nat64) {
    let open = roundOpen(s, now);
    if (f.cur_open == open and f.cur_open != 0) return;
    if (f.cur_open != 0 and f.cur_status == #open) f.dead_count += 1;
    f.cur_open := open;
    f.cur_reports := [];
    f.cur_status := #open;
  };

  public type ReportOutcome = {
    #accepted_report; // counted; the round is still open
    #finalized : Accepted; // this report finalized the round and the round was accepted
    #held; // this report finalized the round but its price is held by the jump breaker
    #frozen; // this report made the round's reports spread too far
    #late; // the round had already finalized, frozen or been held: recorded only
    #refused : Text;
  };

  /// Apply one report. `round_open` is the round the reporter names (its open time).
  public func report(f : PairFeed, s : Settings, reporter : Principal, round_open : Nat64, price : Nat, observed_at : Nat64, now : Nat64) : ReportOutcome {
    if (not isReporter(s, reporter)) return #refused("REJECT:not-a-reporter");
    let open = roundOpen(s, now);
    if (round_open < open) return #refused("REJECT:round-closed");
    if (round_open > open) return #refused("REJECT:round-future");
    // A change of round length can make floor(now / R) * R fall before a round already accepted;
    // rounds never open backwards, so accepted rounds stay in strictly increasing open order.
    switch (f.last) {
      case (?a) { if (open < a.open_ns) return #refused("REJECT:round-rewinds") };
      case null {};
    };
    if (now >= open + s.deadline_ns) {
      // the named round is the current window but its deadline passed: it is dead
      rollover(f, s, now);
      if (f.cur_status == #open) return #refused("REJECT:round-deadline");
    };
    rollover(f, s, now);
    if (f.cur_status != #open) {
      f.late_count += 1;
      return #late;
    };
    for (r in f.cur_reports.vals()) {
      if (Principal.equal(r.reporter, reporter)) return #refused("REJECT:duplicate-report");
    };
    if (price == 0 or price > MAX_PRICE) return #refused("REJECT:price-range");
    if (observed_at < open) return #refused("REJECT:observed-before-round");
    if (observed_at > now) return #refused("REJECT:observed-in-future");
    if (now - observed_at > s.max_report_age_ns) return #refused("REJECT:report-stale");
    switch (f.last) {
      case (?a) { if (observed_at < a.sample_ns) return #refused("REJECT:sample-time-rewinds") };
      case null {};
    };
    f.cur_reports := Array.concat(f.cur_reports, [{ reporter; price; observed_at; landed_at = now }]);
    tryFinalize(f, s, now)
  };

  func tryFinalize(f : PairFeed, s : Settings, now : Nat64) : ReportOutcome {
    let prices = Array.map<Report, Nat>(f.cur_reports, func(r) { r.price });
    let median = lowerMedian(prices);
    for (p in prices.vals()) {
      if (not within(p, median, s.spread_bps)) {
        f.cur_status := #frozen;
        f.frozen_count += 1;
        return #frozen;
      };
    };
    if (prices.size() < s.k) return #accepted_report;
    let sample = lowerMedian(Array.map<Report, Nat>(f.cur_reports, func(r) { Nat64.toNat(r.observed_at) }));
    let sampleNs = Nat64.fromNat(sample);
    // monotonic sample time, checked again on the round as a whole (each report was already
    // checked against the last accepted round; this is the rule for the round as a whole)
    switch (f.last) {
      case (?a) {
        if (sampleNs < a.sample_ns) {
          f.cur_status := #frozen;
          f.frozen_count += 1;
          return #refused("REJECT:sample-time-rewinds");
        };
      };
      case null {};
    };
    let candidate : Accepted = { open_ns = f.cur_open; price = median; sample_ns = sampleNs; finalized_ns = now };
    if (breakerAccepts(f, s, candidate)) {
      accept(f, candidate);
      #finalized(candidate)
    } else {
      f.cur_status := #held;
      f.held_count += 1;
      #held
    }
  };

  /// The jump breaker. Updates the hold and says whether `c` may price swaps.
  func breakerAccepts(f : PairFeed, s : Settings, c : Accepted) : Bool {
    let lastPrice = switch (f.last) { case (?a) a.price; case null return true }; // first round: the XRC band decides
    switch (f.hold) {
      case null {
        if (within(c.price, lastPrice, s.jump_bps)) return true;
        f.hold := ?{ price = c.price; since_ns = c.sample_ns };
        false
      };
      case (?h) {
        if (within(c.price, h.price, s.confirm_bps)) {
          if (c.sample_ns >= h.since_ns + s.jump_gap_ns) {
            f.hold := null;
            return true;
          };
          f.hold := ?{ h with price = c.price }; // the chain goes on: still held, at its latest price
          return false;
        };
        if (within(c.price, lastPrice, s.jump_bps)) {
          f.hold := null; // the jump reverted
          return true;
        };
        f.hold := ?{ price = c.price; since_ns = c.sample_ns }; // the chain broke: a new one starts here
        false
      };
    }
  };

  func accept(f : PairFeed, a : Accepted) {
    f.cur_status := #accepted;
    f.last := ?a;
    f.accepted_count += 1;
    switch (f.ring[f.head]) { case (?old) f.evicted_through := old.open_ns; case null {} };
    f.ring[f.head] := ?a;
    f.head := (f.head + 1) % HISTORY;
    if (f.count < HISTORY) f.count += 1;
  };

  /// The i-th accepted round still held, oldest first (i < count).
  func at(f : PairFeed, i : Nat) : Accepted {
    let start = (f.head + HISTORY - f.count) % HISTORY;
    switch (f.ring[(start + i) % HISTORY]) { case (?a) a; case null { assert false; loop {} } }
  };

  public type Settle = {
    #round : Accepted; // the round that prices the lock
    #wait; // no accepted round after the lock yet, and its deadline has not passed
    #never; // the lock can never be priced: refund it
  };

  /// What prices a lock made at `lock_ns` with deadline `deadline_ns`, at time `now`: the first
  /// ACCEPTED round that opened strictly after the lock, if it was finalized no later than the
  /// deadline. Never a round that opened at or before the lock, never a held, frozen or dead round,
  /// never a later round in place of the first one.
  public func settlingRound(f : PairFeed, lock_ns : Nat64, deadline_ns : Nat64, now : Nat64) : Settle {
    // a round opened after the lock may have left the ring: then the first one is unknown
    if (f.evicted_through > lock_ns) return #never;
    var i = 0;
    while (i < f.count) {
      let a = at(f, i);
      if (a.open_ns > lock_ns) {
        return if (a.finalized_ns <= deadline_ns) #round(a) else #never;
      };
      i += 1;
    };
    if (now > deadline_ns) #never else #wait
  };

  /// In a frozen round, the reporter furthest from the median of its reports (the first such, in
  /// arrival order), so a reporter that keeps freezing rounds is visible to the DAO.
  public func frozenOutlier(f : PairFeed) : ?Principal {
    if (f.cur_status != #frozen or f.cur_reports.size() == 0) return null;
    let median = lowerMedian(Array.map<Report, Nat>(f.cur_reports, func(r) { r.price }));
    var best : ?Principal = null;
    var bestDiff = 0;
    for (r in f.cur_reports.vals()) {
      let d = if (r.price >= median) r.price - median else median - r.price;
      if (best == null or d > bestDiff) { best := ?r.reporter; bestDiff := d };
    };
    best
  };

  public func historySize(f : PairFeed) : Nat { f.count };

  /// Accepted rounds still held, oldest first, from position `start`, at most `count`.
  public func historyPage(f : PairFeed, start : Nat, count : Nat) : [Accepted] {
    if (start >= f.count) return [];
    let n = Nat.min(count, f.count - start);
    Array.tabulate<Accepted>(n, func(i) { at(f, start + i) })
  };

  /// Discard the round in progress (its reports were made under settings that just changed). It
  /// counts as dead; accepted history is kept.
  public func resetRound(f : PairFeed) {
    if (f.cur_open != 0 and f.cur_status == #open) f.dead_count += 1;
    f.cur_open := 0;
    f.cur_reports := [];
    f.cur_status := #open;
  };

  /// Seconds since the pair last accepted a round, for the stall rule.
  public func lastAcceptedAt(f : PairFeed) : ?Nat64 {
    switch (f.last) { case (?a) ?a.finalized_ns; case null null }
  };
};
