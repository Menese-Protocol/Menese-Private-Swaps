// Feed rules, exact cases. Run: moc -r --package core <core/src> swap/canister/test/FeedTest.mo
import Array "mo:core/Array";
import Debug "mo:core/Debug";
import Int "mo:core/Int";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Feed "../src/Feed";

let S : Nat64 = 1_000_000_000;
let P = Feed.PRICE_SCALE;
let r1 = Principal.fromText("2vxsx-fae") ; // anonymous, used only to show it is refused
let a = Principal.fromText("aaaaa-aa");
let b = Principal.fromBlob("\DE\AD\00\01");
let c = Principal.fromBlob("\DE\AD\00\02");
let d = Principal.fromBlob("\DE\AD\00\03");
let e = Principal.fromBlob("\DE\AD\00\04");

var passed = 0;
func check(what : Text, ok : Bool) {
  if (not ok) Runtime.trap("FAIL " # what);
  passed += 1;
};

let base : Feed.Settings = {
  round_ns = 5 * S; deadline_ns = 5 * S; max_report_age_ns = 3 * S; k = 3;
  reporters = [a, b, c, d, e]; spread_bps = 50; jump_bps = 250; confirm_bps = 50; jump_gap_ns = 30 * S;
};

// ---- the floor: k >= 3 and k > n/2, no way around it ----
check("base settings valid", Feed.settingsRejection(base) == null);
check("k = 2 refused", Feed.settingsRejection({ base with k = 2; reporters = [a, b, c] }) == ?"REJECT:feed-k-below-3");
check("k = 2 of 2 refused", Feed.settingsRejection({ base with k = 2; reporters = [a, b] }) == ?"REJECT:feed-k-below-3");
check("k = 3 of 6 (not a majority) refused", Feed.settingsRejection({ base with k = 3; reporters = [a, b, c, d, e, Principal.fromBlob("\DE\AD\00\05")] }) == ?"REJECT:feed-k-not-majority");
check("k above n refused", Feed.settingsRejection({ base with k = 4; reporters = [a, b, c] }) == ?"REJECT:feed-k-above-n");
check("duplicate reporter refused", Feed.settingsRejection({ base with reporters = [a, b, b, c, d] }) == ?"REJECT:feed-duplicate-reporter");
check("anonymous reporter refused", Feed.settingsRejection({ base with reporters = [a, b, c, d, r1] }) == ?"REJECT:feed-anonymous-reporter");
check("spread above 50 refused", Feed.settingsRejection({ base with spread_bps = 51 }) == ?"REJECT:feed-spread");
check("jump above 250 refused", Feed.settingsRejection({ base with jump_bps = 251 }) == ?"REJECT:feed-jump");
check("round of 1 s refused", Feed.settingsRejection({ base with round_ns = 1 * S; deadline_ns = S; max_report_age_ns = S; jump_gap_ns = 30 * S }) == ?"REJECT:feed-round-length");
check("deadline past the round refused", Feed.settingsRejection({ base with deadline_ns = 6 * S }) == ?"REJECT:feed-deadline");

// ---- a round: closed, future, before-round sample, stale, duplicate, non-reporter ----
let px = 30_000 * P; // 1 sat = 30,000 ... any positive value works
let f = Feed.newPairFeed();
let t0 : Nat64 = 1_000 * S; // round opens at 1000 s
func rep(who : Principal, open : Nat64, price : Nat, obs : Nat64, now : Nat64) : Feed.ReportOutcome {
  Feed.report(f, base, who, open, price, obs, now)
};
check("non-reporter refused", rep(r1, t0, px, t0, t0 + S) == #refused("REJECT:not-a-reporter"));
check("closed round refused", rep(a, t0 - 5 * S, px, t0, t0 + S) == #refused("REJECT:round-closed"));
check("future round refused", rep(a, t0 + 5 * S, px, t0, t0 + S) == #refused("REJECT:round-future"));
check("sample before the round refused", rep(a, t0, px, t0 - 1, t0 + S) == #refused("REJECT:observed-before-round"));
check("sample in the future refused", rep(a, t0, px, t0 + 2 * S, t0 + S) == #refused("REJECT:observed-in-future"));
check("first report counted", rep(a, t0, px, t0 + S / 2, t0 + S) == #accepted_report);
check("duplicate refused", rep(a, t0, px, t0 + S / 2, t0 + S) == #refused("REJECT:duplicate-report"));
check("stale report refused", rep(b, t0, px, t0, t0 + 4 * S) == #refused("REJECT:report-stale"));
check("second report counted", rep(b, t0, px + px / 1000, t0 + S, t0 + 2 * S) == #accepted_report);
// third report: spread 49 bps from the median finalizes
let p49 = px + px * 49 / 10_000;
switch (rep(c, t0, p49, t0 + 2 * S, t0 + 3 * S)) {
  case (#finalized(acc)) {
    check("finalized at k = 3, lower median", acc.price == px + px / 1000);
    check("finalized round is the open one", acc.open_ns == t0);
  };
  case _ check("49 bps spread finalizes", false);
};
check("late report after finalization changes nothing", rep(d, t0, 2 * px, t0 + 3 * S, t0 + 4 * S) == #late);
check("late report did not move the price", (switch (f.last) { case (?x) x.price == px + px / 1000; case null false }));

// ---- 51 bps spread freezes; a frozen round never finalizes ----
let t1 = t0 + 5 * S;
let pm = px + px / 1000; // the last accepted price, so no jump is involved
check("r1 a", rep(a, t1, pm, t1 + S, t1 + S) == #accepted_report);
check("r1 b", rep(b, t1, pm, t1 + S, t1 + S) == #accepted_report);
check("51 bps spread freezes", rep(c, t1, pm + pm * 51 / 10_000, t1 + S, t1 + S) == #frozen);
check("a frozen round takes no more reports", rep(d, t1, pm, t1 + S, t1 + 2 * S) == #late);
check("frozen round not accepted", (switch (f.last) { case (?x) x.open_ns == t0; case null false }));

// ---- deadline: a round with no quorum at its deadline is dead ----
let dl : Feed.Settings = { base with deadline_ns = 3 * S };
let t2 = t1 + 5 * S;
check("before the deadline", Feed.report(f, dl, a, t2, pm, t2 + S, t2 + S) == #accepted_report);
check("after the deadline refused", Feed.report(f, dl, b, t2, pm, t2 + 3 * S, t2 + 3 * S) == #refused("REJECT:round-deadline"));
let deadBefore = f.dead_count;
Feed.rollover(f, dl, t2 + 5 * S);
check("the round counted dead", f.dead_count == deadBefore + 1);

// ---- jump breaker: 300 bps jump held; confirmed only after the gap ----
let g = Feed.newPairFeed();
func rg(who : Principal, open : Nat64, price : Nat, now : Nat64) : Feed.ReportOutcome {
  Feed.report(g, base, who, open, price, open + S / 2, now)
};
func roundOf(open : Nat64, price : Nat) : Feed.ReportOutcome {
  ignore rg(a, open, price, open + S);
  ignore rg(b, open, price, open + S);
  rg(c, open, price, open + S)
};
let q0 = 10_000 * S;
check("first round accepted", (switch (roundOf(q0, px)) { case (#finalized(_)) true; case _ false }));
let jump = px + px * 300 / 10_000;
check("300 bps jump held", roundOf(q0 + 5 * S, jump) == #held);
check("confirm too soon still held", roundOf(q0 + 10 * S, jump) == #held);
check("held price never prices a lock", Feed.settlingRound(g, q0 + 1, q0 + 600 * S, q0 + 34 * S) == #wait);
check("confirmed after the gap", (switch (roundOf(q0 + 35 * S, jump)) { case (#finalized(x)) x.price == jump; case _ false }));
check("a lock during the hold settles at the confirming round, never the held one",
  (switch (Feed.settlingRound(g, q0 + 6 * S, q0 + 600 * S, q0 + 36 * S)) { case (#round(x)) x.open_ns == q0 + 35 * S; case _ false }));
// a jump that reverts is accepted at once
let back = px + px * 200 / 10_000;
check("next jump held", roundOf(q0 + 40 * S, jump * 2) == #held);
check("a revert to within the jump of the last accepted is accepted", (switch (roundOf(q0 + 45 * S, jump)) { case (#finalized(_)) true; case _ false }));
ignore back;

// ---- settlement round: first accepted round opened strictly after the lock, within the timeout ----
let h = Feed.newPairFeed();
func rh(open : Nat64, now : Nat64) {
  // fresh reports (sampled half a second before they land), so the round is really accepted
  ignore Feed.report(h, base, a, open, px, now - S / 2, now);
  ignore Feed.report(h, base, b, open, px, now - S / 2, now);
  switch (Feed.report(h, base, c, open, px, now - S / 2, now)) {
    case (#finalized(x)) { if (x.open_ns != open or x.finalized_ns != now) Runtime.trap("FAIL rh round") };
    case _ Runtime.trap("FAIL rh: the round did not finalize");
  };
};
let u0 = 20_000 * S;
rh(u0, u0 + 4 * S); // round u0 finalizes at u0 + 4 s, AFTER a lock at u0 + 1 s
rh(u0 + 5 * S, u0 + 6 * S);
check("lock inside a round: the round that opened before it never settles it",
  (switch (Feed.settlingRound(h, u0 + S, u0 + 60 * S, u0 + 7 * S)) { case (#round(x)) x.open_ns == u0 + 5 * S; case _ false }));
check("lock exactly at a round's open: that round did not open strictly after",
  (switch (Feed.settlingRound(h, u0, u0 + 60 * S, u0 + 7 * S)) { case (#round(x)) x.open_ns == u0 + 5 * S; case _ false }));
check("no round within the timeout: never", Feed.settlingRound(h, u0 + S, u0 + 5 * S, u0 + 7 * S) == #never);
check("a lock after the last round, deadline ahead: wait", Feed.settlingRound(h, u0 + 6 * S, u0 + 60 * S, u0 + 7 * S) == #wait);
check("a lock after the last round, deadline passed: never", Feed.settlingRound(h, u0 + 6 * S, u0 + 60 * S, u0 + 61 * S) == #never);

// ---- round length change: rounds never open backwards ----
let seven : Feed.Settings = { base with round_ns = 7 * S; deadline_ns = 7 * S; jump_gap_ns = 30 * S };
// last accepted round opened at u0 + 5 s (20,005 s); at 20,005.5 s a 7 s round length gives 19,999 s
let nowR = u0 + 5 * S + S / 2;
let openR = Feed.roundOpen(seven, nowR);
check("the 7 s round opens before the last accepted one", openR < u0 + 5 * S);
check("a rewinding round is refused", Feed.report(h, seven, a, openR, px, nowR, nowR) == #refused("REJECT:round-rewinds"));


// ---- the ring: an evicted window answers never, not a later round ----
let rg2 = Feed.newPairFeed();
let v0 = 100_000 * S;
var j = 0;
while (j < Feed.HISTORY + 3) {
  let o = v0 + Nat64.fromNat(j) * 5 * S;
  ignore Feed.report(rg2, base, a, o, px, o + S / 2, o + S);
  ignore Feed.report(rg2, base, b, o, px, o + S / 2, o + S);
  ignore Feed.report(rg2, base, c, o, px, o + S / 2, o + S);
  j += 1;
};
check("ring holds HISTORY rounds", Feed.historySize(rg2) == Feed.HISTORY);
check("a lock whose first round was evicted is never priced by a later one", Feed.settlingRound(rg2, v0 + S, v0 + 1_000_000 * S, v0 + 10 * S) == #never);
let late0 = v0 + Nat64.fromNat(Feed.HISTORY) * 5 * S; // the oldest round still held opened at v0 + 3*5 s
check("a lock inside the ring still finds its first round",
  (switch (Feed.settlingRound(rg2, late0 + S, late0 + 600 * S, late0 + 20 * S)) { case (#round(x)) x.open_ns == late0 + 5 * S; case _ false }));

// ---- a frozen round names the reporter furthest from its median ----
let fz = Feed.newPairFeed();
let w0 = 200_000 * S;
ignore Feed.report(fz, base, a, w0, px, w0 + S / 2, w0 + S);
ignore Feed.report(fz, base, b, w0, px, w0 + S / 2, w0 + S);
check("an outlier freezes", Feed.report(fz, base, e, w0, px * 2, w0 + S / 2, w0 + S) == #frozen);
check("the outlier is named", Feed.frozenOutlier(fz) == ?e);


// ---- one liar, in every arrival position: it never moves the price ----
let honestOrder = [a, b, c, d];
func runOrder(order : [Principal], liar : Principal, liarPrice : Nat, w : Nat64) : (Feed.PairFeed, [Feed.ReportOutcome]) {
  let g = Feed.newPairFeed();
  var outs : [Feed.ReportOutcome] = [];
  var t = w + S / 2;
  for (who in order.vals()) {
    let p = if (Principal.equal(who, liar)) liarPrice else px;
    outs := Array.concat(outs, [Feed.report(g, base, who, w, p, t, t)]);
    t += S / 10;
  };
  (g, outs)
};
func insertAt(xs : [Principal], x : Principal, pos : Nat) : [Principal] {
  Array.tabulate<Principal>(xs.size() + 1, func(i) { if (i < pos) xs[i] else if (i == pos) x else xs[i - 1] })
};
func lastPrice(g : Feed.PairFeed) : ?Nat { switch (g.last) { case (?x) ?x.price; case null null } };
var pos = 0;
while (pos <= 4) {
  let w = 300_000 * S + Nat64.fromNat(pos) * 100 * S;
  let (g, _) = runOrder(insertAt(honestOrder, e, pos), e, px + px * 300 / 10_000, w);
  // before quorum the liar freezes the round; after it, it is late
  check("liar +300 bps at position " # debug_show pos # ": price never moves",
    if (pos < 3) lastPrice(g) == null and Feed.frozenOutlier(g) == ?e else lastPrice(g) == ?px);
  for (off in [40, -40].vals()) {
    let lp : Nat = if (off > 0) px + px * 40 / 10_000 else px - px * 40 / 10_000;
    let (g2, _) = runOrder(insertAt(honestOrder, e, pos), e, lp, w);
    check("liar " # debug_show off # " bps at position " # debug_show pos # ": finalized at the honest price", lastPrice(g2) == ?px);
  };
  pos += 1;
};

// ---- k - 1 = 2 colluders: never finalize alone; move the price at most spread_bps ----
let five = [a, b, c, d, e];
var maxMoveBps = 0;
var moved = 0;
var cases = 0;
for (i in [0, 1, 2, 3, 4].vals()) {
  for (j in [0, 1, 2, 3, 4].vals()) {
    if (i < j) {
      for (off in [-60, -50, -40, 40, 50, 60].vals()) {
        let cp : Nat = if (off > 0) px + px * Int.abs(off) / 10_000 else px - px * Int.abs(off) / 10_000;
        let g = Feed.newPairFeed();
        let w = 400_000 * S + Nat64.fromNat(cases) * 10 * S;
        var t = w + S / 2;
        var outcomes : [Feed.ReportOutcome] = [];
        // the colluders report first, then the honest three in order
        let order = Array.concat([five[i], five[j]], Array.filter<Principal>(five, func(x) { not Principal.equal(x, five[i]) and not Principal.equal(x, five[j]) }));
        var k = 0;
        for (who in order.vals()) {
          let p = if (k < 2) cp else px;
          outcomes := Array.concat(outcomes, [Feed.report(g, base, who, w, p, t, t)]);
          t += S / 10;
          k += 1;
        };
        check("colluders alone never finalize (" # debug_show cases # ")", outcomes[1] == #accepted_report or outcomes[1] == #frozen);
        switch (lastPrice(g)) {
          case (?p) {
            let d = if (p >= px) p - px else px - p;
            let bps = d * 10_000 / px;
            if (bps > maxMoveBps) maxMoveBps := bps;
            if (p != px) moved += 1;
            check("a finalized colluded round is within spread of the honest price (" # debug_show off # ")", d * 10_000 <= px * 50);
          };
          // the spread is measured from the median, relative to the median: at -50 bps the colluders'
          // value is the median and the honest reports sit 50.25 bps above it, so that round freezes too
          case null check("beyond the spread the colluded round freezes (" # debug_show off # ")", Int.abs(off) > 50 or off == -50);
        };
        cases += 1;
      };
    };
  };
};
check("the colluder bound is exactly the spread", maxMoveBps == 50);
Debug.print("colluders: " # debug_show cases # " cases, " # debug_show moved # " moved the price, at most " # debug_show maxMoveBps # " bps");

// ---- sample time is monotonic at the report: a shorter round cannot reach back ----
let sm = Feed.newPairFeed();
let z0 = 500_000 * S;
ignore Feed.report(sm, base, a, z0, px, z0 + 3 * S, z0 + 3 * S);
ignore Feed.report(sm, base, b, z0, px, z0 + 3 * S, z0 + 3 * S);
ignore Feed.report(sm, base, c, z0, px, z0 + 3 * S, z0 + 3 * S);
let two : Feed.Settings = { base with round_ns = 2 * S; deadline_ns = 2 * S; max_report_age_ns = 2 * S; jump_gap_ns = 30 * S };
// the 2 s round opening at z0 + 2 s is after the accepted round's open, but before its sample
check("a report sampled before the last accepted sample is refused",
  Feed.report(sm, two, a, z0 + 2 * S, px, z0 + 2 * S + S / 2, z0 + 2 * S + S / 2 + 1) == #refused("REJECT:sample-time-rewinds"));


// ---- the breaker's clock: sample times only, and a steady move confirms ----
let bk = Feed.newPairFeed();
// every report of a round sampled at `sample`, landing just after it
func roundAt(open : Nat64, sample : Nat64, price : Nat) : Feed.ReportOutcome {
  ignore Feed.report(bk, base, a, open, price, sample, sample + S / 10);
  ignore Feed.report(bk, base, b, open, price, sample, sample + S / 10);
  Feed.report(bk, base, c, open, price, sample, sample + S / 10)
};
func bps(x : Nat, n : Nat) : Nat { x + x * n / 10_000 };
func bpsDown(x : Nat, n : Nat) : Nat { x - x * n / 10_000 };
let k0 = 600_000 * S;
check("breaker clock: base round", (switch (roundAt(k0, k0 + S, px)) { case (#finalized(_)) true; case _ false }));
// a sustained move of 20 bps per 5 s round (4 bps/s) after a 300 bps step: every round leaves the
// first held price's 50 bps neighbourhood within 15 s, but stays on the same side
var tr = 1;
var trOut : Feed.ReportOutcome = #held;
var trendPrice = bps(px, 300);
while (tr <= 7) { // rounds at +5 s .. +35 s
  let o = k0 + Nat64.fromNat(tr) * 5 * S;
  trOut := roundAt(o, o + S, trendPrice);
  if (tr < 7) check("sustained move held before the gap (round " # debug_show tr # ")", trOut == #held);
  trendPrice := bps(trendPrice, 20);
  tr += 1;
};
// sampled at +36 s, 30 s after the first held sample at +6 s: confirmed at the moved price
check("a sustained move confirms after the gap (no livelock)", (switch (trOut) { case (#finalized(x)) x.price > bps(px, 300); case _ false }));

// a fast move, 60 bps per round (each round breaks the chain), then it settles: the clock starts
// at the first settled round, so the level is confirmed 30 s of its own observations later
let bf = Feed.newPairFeed();
func roundBf(open : Nat64, price : Nat) : Feed.ReportOutcome {
  ignore Feed.report(bf, base, a, open, price, open + S, open + S + S / 10);
  ignore Feed.report(bf, base, b, open, price, open + S, open + S + S / 10);
  Feed.report(bf, base, c, open, price, open + S, open + S + S / 10)
};
let f0 = 650_000 * S;
ignore roundBf(f0, px);
var fp = bps(px, 300);
var fr = 1;
while (fr <= 7) { // +5 s .. +35 s, each 60 bps above the last
  check("fast move held (round " # debug_show fr # ")", roundBf(f0 + Nat64.fromNat(fr) * 5 * S, fp) == #held);
  fp := bps(fp, 60);
  fr += 1;
};
let settled = fp; // first settled round at +40 s
check("a fast move that just settled is still held", roundBf(f0 + 40 * S, settled) == #held);
check("settled for 25 s: held", roundBf(f0 + 65 * S, settled) == #held);
check("settled for 30 s of its own observations: confirmed", (switch (roundBf(f0 + 70 * S, settled)) { case (#finalized(x)) x.price == settled; case _ false }));

// a spike on top of a held move: the move holds at +300 for 25 s, a 200 bps spike above it lasts two
// rounds, the price returns: the spike's level is never accepted
let bp = Feed.newPairFeed();
func roundBp(open : Nat64, price : Nat) : Feed.ReportOutcome {
  ignore Feed.report(bp, base, a, open, price, open + S, open + S + S / 10);
  ignore Feed.report(bp, base, b, open, price, open + S, open + S + S / 10);
  Feed.report(bp, base, c, open, price, open + S, open + S + S / 10)
};
let p0 = 680_000 * S;
ignore roundBp(p0, px);
let mv = bps(px, 300);
let spike = bps(mv, 200);
var pr = 1;
while (pr <= 5) { ignore roundBp(p0 + Nat64.fromNat(pr) * 5 * S, mv); pr += 1 }; // +5 .. +25 s
check("spike held", roundBp(p0 + 30 * S, spike) == #held);
check("spike, second round, 25 s after the move began: held", roundBp(p0 + 35 * S, spike) == #held);
check("the move resumes: held (its chain restarted at the return)", roundBp(p0 + 40 * S, mv) == #held);
check("the spike's level never priced", (switch (bp.last) { case (?x) x.price == px; case null false }));
check("the move confirmed 30 s after its return", (switch (roundBp(p0 + 70 * S, mv)) { case (#finalized(x)) x.price == mv; case _ false }));

// the clock is the sample time: a round opened 30 s after the held one but sampled 26 s after it
// does not confirm
let bs = Feed.newPairFeed();
func roundBs(open : Nat64, sample : Nat64, price : Nat) : Feed.ReportOutcome {
  ignore Feed.report(bs, base, a, open, price, sample, sample + S / 10);
  ignore Feed.report(bs, base, b, open, price, sample, sample + S / 10);
  Feed.report(bs, base, c, open, price, sample, sample + S / 10)
};
let m0 = 700_000 * S;
ignore roundBs(m0, m0 + S, px);
check("breaker clock: step held (sampled late in its round)", roundBs(m0 + 5 * S, m0 + 9 * S, bps(px, 300)) == #held);
check("opened 30 s later but sampled 26 s later: still held", roundBs(m0 + 35 * S, m0 + 35 * S + S / 2, bps(px, 300)) == #held);
check("sampled 30 s later: confirmed", (switch (roundBs(m0 + 40 * S, m0 + 40 * S, bps(px, 300))) { case (#finalized(_)) true; case _ false }));

// a held round on the other side breaks the chain: +300 at +6 s, -300 at +21 s, -300 again at
// +36 s (30 s after the first hold, 15 s after the break): still held; confirmed at +51 s
let bo = Feed.newPairFeed();
func roundBo(open : Nat64, price : Nat) : Feed.ReportOutcome {
  ignore Feed.report(bo, base, a, open, price, open + S, open + S + S / 10);
  ignore Feed.report(bo, base, b, open, price, open + S, open + S + S / 10);
  Feed.report(bo, base, c, open, price, open + S, open + S + S / 10)
};
let n0 = 800_000 * S;
ignore roundBo(n0, px);
check("up step held", roundBo(n0 + 5 * S, bps(px, 300)) == #held);
check("down step held", roundBo(n0 + 20 * S, bpsDown(px, 300)) == #held);
check("other side: the clock restarted, still held at +35 s", roundBo(n0 + 35 * S, bpsDown(px, 300)) == #held);
check("other side confirmed 30 s after it began", (switch (roundBo(n0 + 50 * S, bpsDown(px, 300))) { case (#finalized(x)) x.price == bpsDown(px, 300); case _ false }));
Debug.print("FeedTest: " # debug_show passed # " checks PASS");
