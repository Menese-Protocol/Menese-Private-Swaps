/// Swap arithmetic at a feed price. Pure functions, exact integers.
///
/// A price `p` is ICP base units per asset base unit, times `Feed.PRICE_SCALE` (10^18).
/// Every rounding goes toward the reserve: a payout is rounded down, a fee is rounded up, shares
/// minted are rounded down, and a leaver's part of each token is rounded down.
import Nat "mo:core/Nat";

module {
  public let SCALE : Nat = 1_000_000_000_000_000_000;
  public let BPS : Nat = 10_000;
  /// The first shares minted belong to nobody (Uniswap v2's permanently locked minimum).
  public let LOCKED_SHARES : Nat = 1_000;

  public func ceilDiv(a : Nat, b : Nat) : Nat { (a + b - 1) / b };

  public func assetToIcp(amount : Nat, price : Nat) : Nat { amount * price / SCALE };
  public func icpToAsset(amount : Nat, price : Nat) : Nat { amount * SCALE / price };

  public type Leg = {
    gross : Nat; // output before the fee, rounded down
    fee : Nat; // rounded up, never more than gross
    protocol : Nat; // the protocol's part of the fee, rounded down
    out : Nat; // gross - fee
  };

  public func leg(gross : Nat, fee_bps : Nat, protocol_share_bps : Nat) : Leg {
    let fee = Nat.min(gross, ceilDiv(gross * fee_bps, BPS));
    let protocol = fee * protocol_share_bps / BPS;
    { gross; fee; protocol; out = gross - fee }
  };

  /// Asset in, ICP out.
  public func sellAsset(amount : Nat, price : Nat, fee_bps : Nat, share_bps : Nat) : Leg {
    leg(assetToIcp(amount, price), fee_bps, share_bps)
  };

  /// ICP in, asset out.
  public func buyAsset(icp : Nat, price : Nat, fee_bps : Nat, share_bps : Nat) : Leg {
    leg(icpToAsset(icp, price), fee_bps, share_bps)
  };

  /// Shares for a join of `value` ICP-worth into a reserve worth `reserve_value` with `total_shares`.
  /// The join fee stays in the reserve. Returns (shares to the joiner, shares to nobody, fee value).
  /// 0 shares means the join is refused.
  public func joinShares(value : Nat, reserve_value : Nat, total_shares : Nat, join_fee_bps : Nat) : (Nat, Nat, Nat) {
    let fee = ceilDiv(value * join_fee_bps, BPS);
    if (fee >= value) return (0, 0, fee);
    let net = value - fee;
    if (total_shares == 0) {
      if (net <= LOCKED_SHARES) return (0, 0, fee);
      return (net - LOCKED_SHARES, LOCKED_SHARES, fee);
    };
    if (reserve_value == 0) return (0, 0, fee); // shares exist but the reserve is worth nothing: refuse
    (net * total_shares / reserve_value, 0, fee)
  };

  /// A leaver's part of one token's holdings.
  public func leavePart(holdings : Nat, shares : Nat, total_shares : Nat) : Nat {
    if (total_shares == 0) 0 else holdings * shares / total_shares
  };
};
