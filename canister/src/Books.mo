/// The swap canister's books: every money transition, as pure functions over explicit state.
///
/// Per asset (index 0 is ICP, the hub), in the asset's base units:
///
///   held + pending + owed + fees + sweeping + paying + dao_due
///     == credited + locked - collected - swept - paid                      (the books identity)
///
/// and the right side is exactly what the asset's pool holds as its reserve record (plus a payout
/// reservation while one is in flight), which `books` in the actor checks against the pools.
///
///   held       providers' holdings: what the reserve's shares are claims on
///   pending    locked in a pool, not priced yet
///   owed       owed records not collected yet (payouts, refunds, leaves)
///   fees       the protocol's part of swap fees, not swept into the pool's revenue yet
///   sweeping   a fee sweep sent to the pool and not confirmed yet
///   paying     a DAO payout sent to the pool and not confirmed yet (ICP only)
///   dao_due    the DAO's withdrawn value not paid out yet
///
/// Shares: total == locked + dao + receipts_owed + receipts_out, where receipts_owed are shares
/// minted to a provider and not yet collected as a receipt note, and receipts_out are shares held
/// as receipt notes.
///
/// Rounding always goes toward the reserve (Pricing.mo). A transition either applies whole or not
/// at all: each function checks everything first, then writes.
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Pricing "Pricing";
import Settings "Settings";

module {
  public let ICP : Nat = 0;
  public let MINUTE_NS : Nat64 = 60_000_000_000;
  public let U64_LIMIT : Nat = 18_446_744_073_709_551_616;

  public type AssetBooks = {
    var held : Nat;
    var pending : Nat;
    var owed : Nat;
    var fees : Nat;
    var sweeping : Nat;
    var paying : Nat;
    var dao_due : Nat;
    var locked : Nat;
    var credited : Nat;
    var collected : Nat;
    var swept : Nat;
    var paid : Nat;
    var minute : Nat64;
    var minute_volume : Nat; // ICP e8s of value through this asset's pair in `minute`
  };

  public type Shares = {
    var total : Nat;
    var locked : Nat;
    var dao : Nat;
    var receipts_owed : Nat;
    var receipts_out : Nat;
  };

  public type State = { assets : Map.Map<Nat, AssetBooks>; shares : Shares };

  public func newAsset() : AssetBooks {
    {
      var held = 0; var pending = 0; var owed = 0; var fees = 0; var sweeping = 0; var paying = 0; var dao_due = 0;
      var locked = 0; var credited = 0; var collected = 0; var swept = 0; var paid = 0;
      var minute = 0; var minute_volume = 0;
    }
  };

  public func newState() : State {
    let assets = Map.empty<Nat, AssetBooks>();
    Map.add(assets, Nat.compare, ICP, newAsset());
    { assets; shares = { var total = 0; var locked = 0; var dao = 0; var receipts_owed = 0; var receipts_out = 0 } }
  };

  public func asset(s : State, i : Nat) : AssetBooks {
    switch (Map.get(s.assets, Nat.compare, i)) { case (?a) a; case null { assert false; loop {} } }
  };

  public func addAsset(s : State, i : Nat) {
    if (not Map.containsKey(s.assets, Nat.compare, i)) Map.add(s.assets, Nat.compare, i, newAsset());
  };

  /// The left side of the books identity.
  public func parts(a : AssetBooks) : Nat { a.held + a.pending + a.owed + a.fees + a.sweeping + a.paying + a.dao_due };
  /// The right side: what the pool's reserve record must be (plus an in-flight payout reservation).
  public func poolSide(a : AssetBooks) : Int { a.credited + a.locked - a.collected - a.swept - a.paid };
  public func identityHolds(a : AssetBooks) : Bool { parts(a) == poolSide(a) };
  public func sharesHold(sh : Shares) : Bool { sh.total == sh.locked + sh.dao + sh.receipts_owed + sh.receipts_out };

  // ---------------------------------------------------------------- locks, refunds, collects

  /// A pool verified a lock of `amount`: it is pending until priced.
  public func lockIn(a : AssetBooks, amount : Nat) { a.pending += amount; a.locked += amount };

  /// The DAO's seed block was credited by the ICP pool: pending until it joins at a priced round.
  public func creditIn(a : AssetBooks, amount : Nat) { a.pending += amount; a.credited += amount };

  /// A pending lock that cannot be priced: the whole amount is owed back.
  public func refund(a : AssetBooks, amount : Nat) {
    assert (a.pending >= amount);
    a.pending -= amount;
    a.owed += amount;
  };

  /// The pool confirmed a collect of `amount` (exactly once per owed record).
  public func collected(a : AssetBooks, amount : Nat) {
    assert (a.owed >= amount);
    a.owed -= amount;
    a.collected += amount;
  };

  // ---------------------------------------------------------------- pricing a swap

  public type Leg = {
    pair : Nat; // the asset whose pair this leg uses
    price : Nat;
    gross : Nat;
    fee : Nat;
    protocol : Nat;
    out : Nat;
    volume : Nat; // ICP e8s counted against the pair's minute cap
  };

  public type Fill = {
    from : Nat;
    to : Nat;
    amount : Nat;
    legs : [Leg];
    out : Nat; // what the swapper is owed, in `to`
    icp_protocol : Nat; // protocol fee taken in ICP (a sell leg)
    to_protocol : Nat; // protocol fee taken in `to` (a buy leg)
  };

  public type Quote = { #fill : Fill; #refund : Text };

  public type PairView = { settings : Settings.PairSettings; price : Nat };

  /// Price a swap of `amount` of `from` into `to` at the given legs' round prices. Pure: checks the
  /// reserve can pay, the payout bound, the size and minute caps and the depth, and says how
  /// the books change; `applySwap` makes the change.
  public func quoteSwap(s : State, from : Nat, to : Nat, amount : Nat, minOut : Nat, fromPair : ?PairView, toPair : ?PairView, now : Nat64) : Quote {
    if (from == to) return #refund("same-asset");
    if (amount == 0) return #refund("zero");
    let icpHeld = asset(s, ICP).held;
    var legs : [Leg] = [];
    var mid = amount; // ICP after the sell leg (or the input, if it is ICP)
    var icpProtocol = 0;
    switch (fromPair) {
      case (?p) {
        let l = Pricing.sellAsset(amount, p.price, p.settings.fee_bps, p.settings.protocol_share_bps);
        legs := [{ pair = from; price = p.price; gross = l.gross; fee = l.fee; protocol = l.protocol; out = l.out; volume = l.gross }];
        mid := l.out;
        icpProtocol := l.protocol;
      };
      case null { if (from != ICP) return #refund("no-pair") };
    };
    var out = mid;
    var toProtocol = 0;
    switch (toPair) {
      case (?p) {
        let l = Pricing.buyAsset(mid, p.price, p.settings.fee_bps, p.settings.protocol_share_bps);
        legs := switch (legs.size()) {
          case 0 [{ pair = to; price = p.price; gross = l.gross; fee = l.fee; protocol = l.protocol; out = l.out; volume = mid }];
          case _ [legs[0], { pair = to; price = p.price; gross = l.gross; fee = l.fee; protocol = l.protocol; out = l.out; volume = mid }];
        };
        out := l.out;
        toProtocol := l.protocol;
      };
      case null { if (to != ICP) return #refund("no-pair") };
    };
    if (out == 0) return #refund("payout-zero");
    if (out < minOut) return #refund("below-lowest-payout");
    if (out >= U64_LIMIT) return #refund("payout-too-large");
    // the paying side and the reserve's own fee draw on holdings
    let payHeld = asset(s, to).held;
    if (to == ICP) {
      if (icpHeld < out + icpProtocol) return #refund("reserve-short");
    } else {
      if (payHeld < out + toProtocol) return #refund("reserve-short");
      if (icpHeld < icpProtocol) return #refund("reserve-short");
    };
    // the size cap of the paying pair, the depth and minute cap of each pair used
    let payPair = switch (toPair, fromPair) { case (?p, _) p; case (null, ?p) p; case (null, null) return #refund("no-pair") };
    let payOut = if (to == ICP) out + icpProtocol else out + toProtocol;
    if (payOut * 10_000 > payHeld * payPair.settings.max_swap_bps) return #refund("too-large-for-reserve");
    for (l in legs.vals()) {
      let pv = switch (if (l.pair == from) fromPair else toPair) { case (?v) v; case null return #refund("no-pair") };
      let ab = asset(s, l.pair);
      if (Pricing.assetToIcp(ab.held, pv.price) < pv.settings.min_depth_icp) return #refund("pair-too-shallow");
      if (icpHeld < pv.settings.min_depth_icp) return #refund("pair-too-shallow");
      let used = if (ab.minute == now / MINUTE_NS) ab.minute_volume else 0;
      if (used + l.volume > pv.settings.minute_cap_icp) return #refund("minute-cap");
    };
    #fill({ from; to; amount; legs; out; icp_protocol = icpProtocol; to_protocol = toProtocol })
  };

  public func applySwap(s : State, f : Fill, now : Nat64) {
    let src = asset(s, f.from);
    let dst = asset(s, f.to);
    let icp = asset(s, ICP);
    assert (src.pending >= f.amount);
    src.pending -= f.amount;
    src.held += f.amount;
    if (f.to == ICP) {
      // single sell leg: ICP pays the swapper and the protocol's part of the fee
      icp.held -= f.out + f.icp_protocol;
      icp.fees += f.icp_protocol;
      icp.owed += f.out;
    } else {
      icp.held -= f.icp_protocol;
      icp.fees += f.icp_protocol;
      dst.held -= f.out + f.to_protocol;
      dst.fees += f.to_protocol;
      dst.owed += f.out;
    };
    let minute = now / MINUTE_NS;
    for (l in f.legs.vals()) {
      let ab = asset(s, l.pair);
      if (ab.minute != minute) { ab.minute := minute; ab.minute_volume := 0 };
      ab.minute_volume += l.volume;
    };
  };

  // ---------------------------------------------------------------- joins and leaves

  /// The reserve's value in ICP e8s at the given prices (`priceOf(i)` for every asset i != ICP
  /// with holdings). Null if a held asset has no price.
  public func reserveValue(s : State, priceOf : Nat -> ?Nat) : ?Nat {
    var v = 0;
    for ((i, a) in Map.entries(s.assets)) {
      if (i == ICP) v += a.held
      else if (a.held > 0) {
        switch (priceOf(i)) { case (?p) v += Pricing.assetToIcp(a.held, p); case null return null };
      };
    };
    ?v
  };

  public type JoinFill = { asset : Nat; amount : Nat; value : Nat; shares : Nat; locked : Nat; fee_value : Nat };
  public type JoinQuote = { #fill : JoinFill; #refund : Text };

  /// Price a join of `amount` of asset `i` (worth `value` ICP e8s at its round) into a reserve worth
  /// `reserveValue`. `capIcp` is the asset side's cap (null for ICP).
  public func quoteJoin(s : State, i : Nat, amount : Nat, value : Nat, reserveValueIcp : Nat, joinFeeBps : Nat, minShares : Nat, capIcp : ?(Nat, Nat)) : JoinQuote {
    if (amount == 0 or value == 0) return #refund("zero");
    let (shares, lockedNew, fee) = Pricing.joinShares(value, reserveValueIcp, s.shares.total, joinFeeBps);
    if (shares == 0) return #refund("no-shares");
    if (shares < minShares) return #refund("below-fewest-shares");
    if (shares >= U64_LIMIT) return #refund("shares-too-large");
    switch (capIcp) {
      case (?(price, cap)) {
        if (Pricing.assetToIcp(asset(s, i).held + amount, price) > cap) return #refund("pair-cap");
      };
      case null {};
    };
    #fill({ asset = i; amount; value; shares; locked = lockedNew; fee_value = fee })
  };

  /// `toDao`: the shares are the DAO's (public) instead of a provider's (owed as a receipt note).
  public func applyJoin(s : State, f : JoinFill, toDao : Bool) {
    let a = asset(s, f.asset);
    assert (a.pending >= f.amount);
    a.pending -= f.amount;
    a.held += f.amount;
    s.shares.total += f.shares + f.locked;
    s.shares.locked += f.locked;
    if (toDao) s.shares.dao += f.shares else s.shares.receipts_owed += f.shares;
  };

  /// A receipt note was collected for `shares` (minted earlier as owed).
  public func receiptCollected(s : State, shares : Nat) {
    assert (s.shares.receipts_owed >= shares);
    s.shares.receipts_owed -= shares;
    s.shares.receipts_out += shares;
  };

  /// Each asset's part of `shares`, rounded down: what a leave takes out of holdings. No price is
  /// involved, so a leave cannot exploit one. Parts of 0 are left out.
  public func leaveParts(s : State, shares : Nat) : [(Nat, Nat)] {
    let out = List.empty<(Nat, Nat)>();
    for ((i, a) in Map.entries(s.assets)) {
      let part = Pricing.leavePart(a.held, shares, s.shares.total);
      if (part > 0) List.add(out, (i, part));
    };
    List.toArray(out)
  };

  /// A provider's leave of `shares` (already burned in the receipt tree): each part moves from
  /// holdings to owed. Returns the parts, one owed record each.
  public func applyLeave(s : State, shares : Nat) : [(Nat, Nat)] {
    assert (s.shares.receipts_out >= shares and s.shares.total >= shares);
    let p = leaveParts(s, shares);
    for ((i, part) in p.vals()) {
      let a = asset(s, i);
      a.held -= part;
      a.owed += part;
    };
    s.shares.receipts_out -= shares;
    s.shares.total -= shares;
    p
  };

  /// The DAO's withdrawal of `shares`: each part moves from holdings out of the providers' books.
  /// ICP goes to dao_due; every other part is pending again, to be sold for ICP at its next round.
  public func applyDaoLeave(s : State, shares : Nat) : [(Nat, Nat)] {
    assert (s.shares.dao >= shares and s.shares.total >= shares);
    let p = leaveParts(s, shares);
    for ((i, part) in p.vals()) {
      let a = asset(s, i);
      a.held -= part;
      if (i == ICP) a.dao_due += part else a.pending += part;
    };
    s.shares.dao -= shares;
    s.shares.total -= shares;
    p
  };

  /// A DAO sale of part of a withdrawn non-ICP part, filled as a single sell leg: the ICP goes to
  /// the DAO's due ICP instead of an owed record. The rest of the part stays pending.
  public func applyDaoSell(s : State, f : Fill, now : Nat64) {
    assert (f.to == ICP and f.legs.size() == 1);
    let src = asset(s, f.from);
    let icp = asset(s, ICP);
    assert (src.pending >= f.amount and icp.held >= f.out + f.icp_protocol);
    src.pending -= f.amount;
    src.held += f.amount;
    icp.held -= f.out + f.icp_protocol;
    icp.fees += f.icp_protocol;
    icp.dao_due += f.out;
    let minute = now / MINUTE_NS;
    let l = f.legs[0];
    let ab = asset(s, l.pair);
    if (ab.minute != minute) { ab.minute := minute; ab.minute_volume := 0 };
    ab.minute_volume += l.volume;
  };

  /// A DAO withdrawal whose ICP came to less than the DAO's floor goes back in, as a DAO join.
  public func daoRejoin(s : State, amount : Nat) {
    let icp = asset(s, ICP);
    assert (icp.dao_due >= amount);
    icp.dao_due -= amount;
    icp.pending += amount;
  };

  /// A DAO join too small to mint one share: its amount stays in the reserve, a gift to every
  /// share. Only DAO joins end this way; a provider's join is refunded instead.
  public func absorb(a : AssetBooks, amount : Nat) {
    assert (a.pending >= amount);
    a.pending -= amount;
    a.held += amount;
  };

  // ---------------------------------------------------------------- sweeps and payouts

  public func sweepStart(a : AssetBooks, amount : Nat) { assert (a.fees >= amount); a.fees -= amount; a.sweeping += amount };
  public func sweepDone(a : AssetBooks, amount : Nat) { assert (a.sweeping >= amount); a.sweeping -= amount; a.swept += amount };
  public func sweepUndone(a : AssetBooks, amount : Nat) { assert (a.sweeping >= amount); a.sweeping -= amount; a.fees += amount };

  public func payoutStart(a : AssetBooks, amount : Nat) { assert (a.dao_due >= amount); a.dao_due -= amount; a.paying += amount };
  public func payoutDone(a : AssetBooks, amount : Nat) { assert (a.paying >= amount); a.paying -= amount; a.paid += amount };
  public func payoutUndone(a : AssetBooks, amount : Nat) { assert (a.paying >= amount); a.paying -= amount; a.dao_due += amount };
};
