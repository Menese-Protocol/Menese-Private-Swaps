// The books against an independent model, on random sequences of every money transition.
// Run: moc -r --package core <core/src> swap/canister/test/BooksTest.mo
//
// The model below is written from the rules (PROPOSAL-private-swaps-v2.md §3.5, §5, §6), not from
// Books.mo or Pricing.mo: its own rounding helpers, its own per-asset balances and pool records,
// its own list of open owed records and its own share counts. Every step it predicts the exact
// verdict (fill, or the refusal reason) and every amount, then checks that the books moved the
// same way, that both identities hold, that every pool's record covers what it owes, and that no
// operation lowers a share's value at the prices the operation used.
import Debug "mo:core/Debug";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Books "../src/Books";
import Settings "../src/Settings";

// ---------------------------------------------------------------- the model's own arithmetic

let SC : Nat = 1_000_000_000_000_000_000; // price scale
let BP : Nat = 10_000;
let MIN : Nat64 = 60_000_000_000;
let LIM : Nat = 18_446_744_073_709_551_616;
let FIRST : Nat = 1_000; // shares locked to nobody by the first join
let N : Nat = 3; // ICP, an 8-decimal asset, a 6-decimal asset

func up(a : Nat, b : Nat) : Nat { if (a == 0) 0 else (a - 1) / b + 1 };
func toIcp(x : Nat, p : Nat) : Nat { x * p / SC };
func toAsset(x : Nat, p : Nat) : Nat { x * SC / p };
type L = { gross : Nat; fee : Nat; prot : Nat; out : Nat };
func legOf(gross : Nat, feeBps : Nat, shareBps : Nat) : L {
  var fee = up(gross * feeBps, BP);
  if (fee > gross) fee := gross;
  let prot = fee * shareBps / BP;
  { gross; fee; prot; out = gross - fee }
};

// ---------------------------------------------------------------- random numbers

var seed : Nat64 = 0;
func next() : Nat64 {
  seed ^= seed << 13;
  seed ^= seed >> 7;
  seed ^= seed << 17;
  seed
};
func rnd(n : Nat) : Nat { if (n == 0) 0 else Nat64.toNat(next()) % n };

// ---------------------------------------------------------------- pairs

let pairSet : [Settings.PairSettings] = [
  { fee_bps = 0; protocol_share_bps = 0; band_bps = 200; lock_fee = 0; min_swap = 0; min_depth_icp = 0; cap_icp = 0; minute_cap_icp = 0; max_swap_bps = 0 }, // the hub: never a pair
  { fee_bps = 30; protocol_share_bps = 5_000; band_bps = 200; lock_fee = 0; min_swap = 0; min_depth_icp = 1_000_000_000; cap_icp = 400_000_000_000_000; minute_cap_icp = 3_000_000_000_000; max_swap_bps = 100 },
  { fee_bps = 55; protocol_share_bps = 2_500; band_bps = 200; lock_fee = 0; min_swap = 0; min_depth_icp = 500_000_000; cap_icp = 150_000_000_000_000; minute_cap_icp = 150_000_000_000; max_swap_bps = 500 },
];

// ---------------------------------------------------------------- the model's state

let mHeld : [var Nat] = [var 0, 0, 0];
let mPending : [var Nat] = [var 0, 0, 0];
let mOwed : [var Nat] = [var 0, 0, 0];
let mFees : [var Nat] = [var 0, 0, 0];
let mSweeping : [var Nat] = [var 0, 0, 0];
let mPaying : [var Nat] = [var 0, 0, 0];
let mDue : [var Nat] = [var 0, 0, 0];
let mRecord : [var Int] = [var 0, 0, 0]; // the pool's own reserve record: credited + locked - collected - swept - paid
let mMinute : [var Nat64] = [var 0, 0, 0];
let mVol : [var Nat] = [var 0, 0, 0];
let px : [var Nat] = [var 0, 0, 0];
var tTotal = 0;
var tLocked = 0;
var tDao = 0;
var tRecOwed = 0;
var tRecOut = 0;
let openOwed = List.empty<(Nat, Nat)>(); // (asset, amount) of every owed record not collected
let daoSelling = List.empty<(Nat, Nat)>(); // (asset, amount) withdrawn by the DAO, waiting to be sold

var s : Books.State = Books.newState();
var now : Nat64 = 0;

var checks = 0;
func check(what : Text, ok : Bool) {
  if (not ok) Runtime.trap("FAIL " # what);
  checks += 1;
};

let reasons = Map.empty<Text, Nat>();
func count(r : Text) {
  switch (Map.get(reasons, Text.compare, r)) { case (?n) Map.add(reasons, Text.compare, r, n + 1); case null Map.add(reasons, Text.compare, r, 1) };
};

func reset(sd : Nat64) {
  seed := sd;
  s := Books.newState();
  Books.addAsset(s, 1);
  Books.addAsset(s, 2);
  for (i in Nat.range(0, N)) {
    mHeld[i] := 0; mPending[i] := 0; mOwed[i] := 0; mFees[i] := 0; mSweeping[i] := 0; mPaying[i] := 0; mDue[i] := 0;
    mRecord[i] := 0; mMinute[i] := 0; mVol[i] := 0;
  };
  px[1] := 30_000_000_000_000_000_000_000; // 1 BTC = 30,000 ICP
  px[2] := 30_000_000_000_000_000_000; // 1 USD = 0.3 ICP
  tTotal := 0; tLocked := 0; tDao := 0; tRecOwed := 0; tRecOut := 0;
  List.clear(openOwed);
  List.clear(daoSelling);
  now := 1_000_000_000_000;
};

func value() : Nat {
  var v = mHeld[0];
  for (i in Nat.range(1, N)) v += toIcp(mHeld[i], px[i]);
  v
};

func view(i : Nat) : ?Books.PairView { if (i == 0) null else ?{ settings = pairSet[i]; price = px[i] } };

/// Every field of the books against the model, both identities, and every record's floor.
func compare(what : Text) {
  for (i in Nat.range(0, N)) {
    let a = Books.asset(s, i);
    let tag = what # " asset " # Nat.toText(i);
    check(tag # " held", a.held == mHeld[i]);
    check(tag # " pending", a.pending == mPending[i]);
    check(tag # " owed", a.owed == mOwed[i]);
    check(tag # " fees", a.fees == mFees[i]);
    check(tag # " sweeping", a.sweeping == mSweeping[i]);
    check(tag # " paying", a.paying == mPaying[i]);
    check(tag # " dao_due", a.dao_due == mDue[i]);
    check(tag # " pool record", Books.poolSide(a) == mRecord[i]);
    check(tag # " books identity", Books.identityHolds(a));
    check(tag # " the record covers what is owed", mRecord[i] >= mOwed[i] + mPaying[i]);
  };
  let owedSum : [var Nat] = [var 0, 0, 0];
  for ((i, v) in List.values(openOwed)) owedSum[i] += v;
  for (i in Nat.range(0, N)) check(what # " open owed records sum", owedSum[i] == mOwed[i]);
  let sh = s.shares;
  check(what # " shares total", sh.total == tTotal and sh.locked == tLocked and sh.dao == tDao and sh.receipts_owed == tRecOwed and sh.receipts_out == tRecOut);
  check(what # " shares identity", Books.sharesHold(sh));
};

/// A share's value at the current prices never falls: v1 / t1 >= v0 / t0.
func shareValueKept(what : Text, v0 : Nat, t0 : Nat, v1 : Nat, t1 : Nat) {
  if (t0 > 0 and t1 > 0) check(what # ": a share's value fell", v1 * t0 >= v0 * t1);
};

func owe(i : Nat, v : Nat) { mOwed[i] += v; List.add(openOwed, (i, v)) };

func amountFor(i : Nat) : Nat {
  switch (rnd(5)) {
    case 0 1 + rnd(10); // dust
    case 1 1 + rnd(100_000);
    case 2 1 + rnd(Nat.max(1, mHeld[i] / 40)); // near the size cap
    case 3 1 + rnd(1_000_000_000_000);
    case _ 1 + rnd(Nat.max(1, mHeld[i] / 400));
  }
};

// ---------------------------------------------------------------- the model's verdicts

type Expect = { #fill : { out : Nat; icpProt : Nat; toProt : Nat; vols : [(Nat, Nat)] }; #refund : Text };

func expectSwap(from : Nat, to : Nat, amount : Nat, minOut : Nat) : Expect {
  if (from == to) return #refund("same-asset");
  if (amount == 0) return #refund("zero");
  var mid = amount;
  var icpProt = 0;
  var vols : [(Nat, Nat)] = [];
  if (from != 0) {
    let l = legOf(toIcp(amount, px[from]), pairSet[from].fee_bps, pairSet[from].protocol_share_bps);
    mid := l.out;
    icpProt := l.prot;
    vols := [(from, l.gross)];
  };
  var out = mid;
  var toProt = 0;
  if (to != 0) {
    let l = legOf(toAsset(mid, px[to]), pairSet[to].fee_bps, pairSet[to].protocol_share_bps);
    out := l.out;
    toProt := l.prot;
    vols := if (vols.size() == 0) [(to, mid)] else [vols[0], (to, mid)];
  };
  if (out == 0) return #refund("payout-zero");
  if (out < minOut) return #refund("below-lowest-payout");
  if (out >= LIM) return #refund("payout-too-large");
  if (to == 0) {
    if (mHeld[0] < out + icpProt) return #refund("reserve-short");
  } else {
    if (mHeld[to] < out + toProt) return #refund("reserve-short");
    if (mHeld[0] < icpProt) return #refund("reserve-short");
  };
  let payPair = if (to != 0) to else from;
  let payOut = if (to == 0) out + icpProt else out + toProt;
  if (payOut * BP > mHeld[to] * pairSet[payPair].max_swap_bps) return #refund("too-large-for-reserve");
  for ((p, vol) in vols.vals()) {
    if (toIcp(mHeld[p], px[p]) < pairSet[p].min_depth_icp) return #refund("pair-too-shallow");
    if (mHeld[0] < pairSet[p].min_depth_icp) return #refund("pair-too-shallow");
    let used = if (mMinute[p] == now / MIN) mVol[p] else 0;
    if (used + vol > pairSet[p].minute_cap_icp) return #refund("minute-cap");
  };
  #fill({ out; icpProt; toProt; vols })
};

func modelVolumes(vols : [(Nat, Nat)]) {
  let m = now / MIN;
  for ((p, vol) in vols.vals()) {
    if (mMinute[p] != m) { mMinute[p] := m; mVol[p] := 0 };
    mVol[p] += vol;
  };
};

func expectShares(i : Nat, amount : Nat, feeBps : Nat, minShares : Nat, capped : Bool) : { #fill : (Nat, Nat); #refund : Text } {
  let v = if (i == 0) amount else toIcp(amount, px[i]);
  if (amount == 0 or v == 0) return #refund("zero");
  let fee = up(v * feeBps, BP);
  var shares = 0;
  var locked = 0;
  if (fee < v) {
    let net = v - fee;
    if (tTotal == 0) {
      if (net > FIRST) { shares := net - FIRST; locked := FIRST };
    } else {
      let r = value();
      if (r > 0) shares := net * tTotal / r;
    };
  };
  if (shares == 0) return #refund("no-shares");
  if (shares < minShares) return #refund("below-fewest-shares");
  if (shares >= LIM) return #refund("shares-too-large");
  if (capped and i != 0 and toIcp(mHeld[i] + amount, px[i]) > pairSet[i].cap_icp) return #refund("pair-cap");
  #fill((shares, locked))
};

// ---------------------------------------------------------------- the operations

func opSwap() {
  let from = rnd(N);
  var to = rnd(N);
  if (to == from) to := (from + 1 + rnd(N - 1)) % N;
  ignore doSwap(from, to, amountFor(from), null);
};

/// One swap: locked, then priced at the current prices. Returns "fill" or the refusal reason.
func doSwap(from : Nat, to : Nat, amount : Nat, fixedMinOut : ?Nat) : Text {
  var verdict = "";
  // the pool verified the lock
  Books.lockIn(Books.asset(s, from), amount);
  mPending[from] += amount;
  mRecord[from] += amount;
  let honest = switch (expectSwap(from, to, amount, 0)) { case (#fill(f)) f.out; case _ 0 };
  let minOut = switch (fixedMinOut) {
    case (?m) m;
    case null { switch (rnd(4)) { case 0 honest + 1 + rnd(3); case 1 0; case _ honest - Nat.min(honest, rnd(5)) } };
  };
  let v0 = value();
  let e = expectSwap(from, to, amount, minOut);
  switch (Books.quoteSwap(s, from, to, amount, minOut, view(from), view(to), now), e) {
    case (#fill(f), #fill(x)) {
      check("swap out", f.out == x.out and f.icp_protocol == x.icpProt and f.to_protocol == x.toProt);
      Books.applySwap(s, f, now);
      mPending[from] -= amount;
      mHeld[from] += amount;
      if (to == 0) {
        mHeld[0] -= x.out + x.icpProt;
        mFees[0] += x.icpProt;
      } else {
        mHeld[0] -= x.icpProt;
        mFees[0] += x.icpProt;
        mHeld[to] -= x.out + x.toProt;
        mFees[to] += x.toProt;
      };
      owe(to, x.out);
      modelVolumes(x.vols);
      check("a swap never lowers the reserve's value at its own prices", value() >= v0);
      count("swap-fill");
      verdict := "fill";
    };
    case (#refund(r), #refund(y)) {
      check("refusal reason " # r # " vs " # y, r == y);
      Books.refund(Books.asset(s, from), amount);
      mPending[from] -= amount;
      owe(from, amount);
      count("swap-refund:" # r);
      verdict := r;
    };
    case (#fill(_), #refund(y)) check("books filled a swap the model refuses (" # y # ")", false);
    case (#refund(r), #fill(_)) check("books refused a swap the model fills (" # r # ")", false);
  };
  compare("swap");
  verdict
};

func opJoin() {
  let i = rnd(N);
  ignore doJoin(i, if (tTotal == 0) 50_000_000_000 + rnd(1_000_000_000_000) else amountFor(i), null);
};

/// A provider's join, locked then valued at the current prices. Returns "fill" or the reason.
func doJoin(i : Nat, amount : Nat, fixedMin : ?Nat) : Text {
  var verdict = "";
  let fee = 30;
  Books.lockIn(Books.asset(s, i), amount);
  mPending[i] += amount;
  mRecord[i] += amount;
  let honest = switch (expectShares(i, amount, fee, 0, true)) { case (#fill((sh, _))) sh; case _ 0 };
  let minShares = switch (fixedMin) { case (?m) m; case null { if (rnd(5) == 0) honest + 1 else 0 } };
  let e = expectShares(i, amount, fee, minShares, true);
  let v0 = value();
  let t0 = tTotal;
  let value_ = if (i == 0) amount else toIcp(amount, px[i]);
  let rv = switch (Books.reserveValue(s, func(j) { ?px[j] })) { case (?v) v; case null Runtime.trap("reserve value") };
  check("reserve value", rv == v0);
  let cap : ?(Nat, Nat) = if (i == 0) null else ?(px[i], pairSet[i].cap_icp);
  switch (Books.quoteJoin(s, i, amount, value_, rv, fee, minShares, cap), e) {
    case (#fill(f), #fill((sh, lk))) {
      check("join shares", f.shares == sh and f.locked == lk);
      Books.applyJoin(s, f, false);
      mPending[i] -= amount;
      mHeld[i] += amount;
      tTotal += sh + lk;
      tLocked += lk;
      tRecOwed += sh;
      shareValueKept("join", v0, t0, value(), tTotal);
      count("join-fill");
      verdict := "fill";
    };
    case (#refund(r), #refund(y)) {
      check("join refusal " # r # " vs " # y, r == y);
      Books.refund(Books.asset(s, i), amount);
      mPending[i] -= amount;
      owe(i, amount);
      count("join-refund:" # r);
      verdict := r;
    };
    case (#fill(_), #refund(y)) check("books filled a join the model refuses (" # y # ")", false);
    case (#refund(r), #fill(_)) check("books refused a join the model fills (" # r # ")", false);
  };
  compare("join");
  verdict
};

func opSeed() { doSeed(if (rnd(8) == 0) 1 + rnd(10) else 1 + rnd(2_000_000_000_000)) };

func doSeed(amount : Nat) {
  Books.creditIn(Books.asset(s, 0), amount);
  mPending[0] += amount;
  mRecord[0] += amount;
  daoJoin(amount);
  compare("seed");
};

/// The DAO's join: no fee, no floor, no cap; too small for a share, it stays in the reserve.
func daoJoin(amount : Nat) {
  let v0 = value();
  let t0 = tTotal;
  let rv = switch (Books.reserveValue(s, func(j) { ?px[j] })) { case (?v) v; case null Runtime.trap("reserve value") };
  let e = expectShares(0, amount, 0, 0, false);
  switch (Books.quoteJoin(s, 0, amount, amount, rv, 0, 0, null), e) {
    case (#fill(f), #fill((sh, lk))) {
      check("dao join shares", f.shares == sh and f.locked == lk);
      Books.applyJoin(s, f, true);
      tTotal += sh + lk;
      tLocked += lk;
      tDao += sh;
      count("dao-join");
    };
    case (#refund(r), #refund(y)) {
      check("dao join refusal", r == y);
      Books.absorb(Books.asset(s, 0), amount);
      count("dao-join-absorbed");
    };
    case _ check("dao join verdicts differ", false);
  };
  mPending[0] -= amount;
  mHeld[0] += amount;
  shareValueKept("dao join", v0, t0, value(), tTotal);
};

func parts(shares : Nat) : [Nat] {
  [mHeld[0] * shares / tTotal, mHeld[1] * shares / tTotal, mHeld[2] * shares / tTotal]
};

func opReceipt() {
  if (tRecOwed == 0) return;
  let x = 1 + rnd(tRecOwed);
  Books.receiptCollected(s, x);
  tRecOwed -= x;
  tRecOut += x;
  compare("receipt");
};

func opLeave() {
  if (tRecOut == 0) return;
  let shares = 1 + rnd(if (rnd(3) == 0) tRecOut else Nat.max(1, tRecOut / 10));
  let p = parts(shares);
  let got = Books.leaveParts(s, shares);
  var expectedCount = 0;
  for (i in Nat.range(0, N)) if (p[i] > 0) expectedCount += 1;
  check("leave parts", got.size() == expectedCount);
  for ((i, v) in got.vals()) check("leave part " # Nat.toText(i), v == p[i]);
  if (got.size() == 0) { count("leave-too-small"); return };
  let v0 = value();
  let t0 = tTotal;
  ignore Books.applyLeave(s, shares);
  for (i in Nat.range(0, N)) {
    if (p[i] > 0) { mHeld[i] -= p[i]; owe(i, p[i]) };
  };
  tRecOut -= shares;
  tTotal -= shares;
  shareValueKept("leave", v0, t0, value(), tTotal);
  count("leave");
  compare("leave");
};

func opCollect() {
  let n = List.size(openOwed);
  if (n == 0) return;
  let k = rnd(n);
  let (i, v) = List.at(openOwed, k);
  List.put(openOwed, k, List.at(openOwed, n - 1));
  ignore List.removeLast(openOwed);
  Books.collected(Books.asset(s, i), v);
  mOwed[i] -= v;
  mRecord[i] -= v;
  count("collect");
  compare("collect");
};

func opDaoWithdraw() {
  if (tDao == 0) return;
  let shares = 1 + rnd(Nat.max(1, tDao / 4));
  let p = parts(shares);
  let v0 = value();
  let t0 = tTotal;
  ignore Books.applyDaoLeave(s, shares);
  for (i in Nat.range(0, N)) {
    if (p[i] > 0) {
      mHeld[i] -= p[i];
      if (i == 0) mDue[0] += p[i] else { mPending[i] += p[i]; List.add(daoSelling, (i, p[i])) };
    };
  };
  tDao -= shares;
  tTotal -= shares;
  shareValueKept("dao withdrawal", v0, t0, value(), tTotal);
  count("dao-withdraw");
  compare("dao withdrawal");
};

/// Sell a withdrawn part for ICP: too large for one round, halve it (as the actor does).
func opDaoSell() {
  let n = List.size(daoSelling);
  if (n == 0) return;
  let k = rnd(n);
  let (i, whole) = List.at(daoSelling, k);
  var amount = whole;
  var tries = 0;
  label sell while (tries < 6 and amount > 0) {
    let e = expectSwap(i, 0, amount, 0);
    switch (Books.quoteSwap(s, i, 0, amount, 0, view(i), null, now), e) {
      case (#fill(f), #fill(x)) {
        check("dao sale out", f.out == x.out and f.icp_protocol == x.icpProt);
        let v0 = value();
        Books.applyDaoSell(s, f, now);
        mPending[i] -= amount;
        mHeld[i] += amount;
        mHeld[0] -= x.out + x.icpProt;
        mFees[0] += x.icpProt;
        mDue[0] += x.out;
        modelVolumes(x.vols);
        check("a DAO sale never lowers the reserve's value at its price", value() >= v0);
        if (amount == whole) {
          List.put(daoSelling, k, List.at(daoSelling, n - 1));
          ignore List.removeLast(daoSelling);
        } else {
          List.put(daoSelling, k, (i, whole - amount));
        };
        count("dao-sell");
        break sell;
      };
      case (#refund(r), #refund(y)) {
        check("dao sale refusal " # r # " vs " # y, r == y);
        if (r == "too-large-for-reserve" or r == "minute-cap" or r == "reserve-short") amount /= 2 else break sell;
      };
      case _ check("dao sale verdicts differ", false);
    };
    tries += 1;
  };
  compare("dao sale");
};

func opSweep() {
  let i = rnd(N);
  let a = Books.asset(s, i);
  if (mFees[i] == 0) return;
  let amount = mFees[i];
  Books.sweepStart(a, amount);
  mFees[i] -= amount;
  mSweeping[i] += amount;
  compare("sweep start");
  if (rnd(4) == 0) {
    Books.sweepUndone(a, amount);
    mSweeping[i] -= amount;
    mFees[i] += amount;
    count("sweep-undone");
  } else {
    Books.sweepDone(a, amount);
    mSweeping[i] -= amount;
    mRecord[i] -= amount;
    count("sweep");
  };
  compare("sweep");
};

func opPayout() {
  if (mDue[0] == 0) return;
  let a = Books.asset(s, 0);
  let amount = mDue[0];
  switch (rnd(3)) {
    case 0 {
      // below the DAO's floor: it rejoins
      Books.daoRejoin(s, amount);
      mDue[0] -= amount;
      mPending[0] += amount;
      daoJoin(amount);
      count("dao-rejoin");
    };
    case _ {
      Books.payoutStart(a, amount);
      mDue[0] -= amount;
      mPaying[0] += amount;
      compare("payout start");
      if (rnd(4) == 0) {
        Books.payoutUndone(a, amount);
        mPaying[0] -= amount;
        mDue[0] += amount;
        count("payout-undone");
      } else {
        Books.payoutDone(a, amount);
        mPaying[0] -= amount;
        mRecord[0] -= amount;
        count("payout");
      };
    };
  };
  compare("payout");
};

func opPrice() {
  let i = 1 + rnd(N - 1);
  px[i] := Nat.max(1, px[i] * (970 + rnd(61)) / 1_000);
};

// ---------------------------------------------------------------- the runs

func seen0(r : Text) : Nat { switch (Map.get(reasons, Text.compare, r)) { case (?n) n; case null 0 } };

let SEEDS : [Nat64] = [0x9E3779B97F4A7C15, 0xD1B54A32D192ED03, 0x2545F4914F6CDD1D, 0x5851F42D4C957F2D];
let STEPS = 2_500;
for (sd in SEEDS.vals()) {
  reset(sd);
  opSeed();
  for (_ in Nat.range(0, STEPS)) {
    now += Nat64.fromNat(rnd(20)) * 1_000_000_000;
    switch (rnd(20)) {
      case (0 or 1 or 2 or 3 or 4 or 5 or 6) opSwap();
      case (7 or 8) opJoin();
      case 9 opReceipt();
      case 10 opLeave();
      case (11 or 12 or 13) opCollect();
      case 14 opDaoWithdraw();
      case 15 opDaoSell();
      case 16 opSweep();
      case 17 opPayout();
      case 18 opSeed();
      case _ opPrice();
    };
  };
  // drain: every open owed record collected, every receipt out, every share left
  while (List.size(openOwed) > 0) opCollect();
  compare("drained");
};

// ---------------------------------------------------------------- directed cases
// States the random runs reach too rarely: a reserve with almost no ICP and deep asset sides.
reset(1);
doSeed(2_000); // the first 1,000 shares are locked; the DAO holds 1,000
check("directed: BTC join", doJoin(1, 100_000_000, ?0) == "fill"); // 1 BTC
check("directed: USD join", doJoin(2, 100_000_000_000, ?0) == "fill"); // 100,000 USD
// BTC -> USD: the sell leg's protocol part is paid in ICP, and the reserve has 2,000 e8s of it
check("directed: the ICP part of a two-leg fee needs ICP", doSwap(1, 2, 1_000_000, ?0) == "reserve-short");
// ICP -> BTC: the BTC side is deep, the ICP side is 2,000 e8s against a 10 ICP depth floor
check("directed: the ICP side's depth", doSwap(0, 1, 1_000_000, ?0) == "pair-too-shallow");
// ICP -> USD sized so the payout alone fits the size cap (500 bps of the USD side) but the
// payout plus the protocol's part does not: the cap is on what leaves the side, both together
let capAmount = 150_720_000_000;
let capLeg = legOf(toAsset(capAmount, px[2]), pairSet[2].fee_bps, pairSet[2].protocol_share_bps);
check("directed: the case lands in the band", capLeg.out * BP <= mHeld[2] * 500 and (capLeg.out + capLeg.prot) * BP > mHeld[2] * 500);
check("directed: the size cap counts the protocol's part", doSwap(0, 2, capAmount, ?0) == "too-large-for-reserve");
// a DAO seed of 1 e8s is worth less than a share: it stays in the reserve, a gift to every share
let before = seen0("dao-join-absorbed");
doSeed(1);
check("directed: a seed below one share is absorbed", seen0("dao-join-absorbed") == before + 1);
while (List.size(openOwed) > 0) opCollect();
compare("directed");

// coverage: a run that never reached a branch proves nothing about it
func seen(r : Text) : Nat { switch (Map.get(reasons, Text.compare, r)) { case (?n) n; case null 0 } };
for ((r, n) in Map.entries(reasons)) Debug.print(r # " " # Nat.toText(n));
check("swaps filled", seen("swap-fill") >= 500);
check("joins filled", seen("join-fill") >= 100);
check("leaves", seen("leave") >= 50);
check("DAO sales", seen("dao-sell") >= 20);
check("payouts", seen("payout") >= 10 and seen("dao-rejoin") >= 5);
check("refusal: lowest payout", seen("swap-refund:below-lowest-payout") >= 50);
check("refusal: size cap", seen("swap-refund:too-large-for-reserve") >= 20);
check("refusal: minute cap", seen("swap-refund:minute-cap") >= 5);
check("refusal: payout zero", seen("swap-refund:payout-zero") >= 5);
check("join refusal: fewest shares", seen("join-refund:below-fewest-shares") >= 10);
Debug.print("BooksTest: " # Nat.toText(checks) # " checks PASS");
