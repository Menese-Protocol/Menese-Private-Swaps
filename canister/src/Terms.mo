/// The terms of a lock, in one fixed byte layout the app and this canister both build.
///
/// The pool binds these bytes into the lock proof (`swap_lock`'s `terms`), so a relayer can change
/// none of them. Version 1, 72 bytes:
///
///   [0]       version = 1
///   [1]       kind: 0 = swap, 1 = join
///   [2]       target length L (1..29)
///   [3..32)   target principal bytes, then zeros: the pool paid out in (swap), or this swap
///             canister (join)
///   [32..40)  bound, u64 big-endian: the lowest payout accepted (swap, in the target's token)
///             or the fewest shares accepted (join)
///   [40..72)  nonce: 32 bytes the app draws, so two locks never share terms
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

module {
  public let LEN : Nat = 72;

  public type Kind = { #swap; #join };
  public type Terms = { kind : Kind; target : Principal; bound : Nat; nonce : Blob };

  public func encode(t : Terms) : ?Blob {
    let p = Blob.toArray(Principal.toBlob(t.target));
    if (p.size() == 0 or p.size() > 29) return null;
    if (t.nonce.size() != 32) return null;
    if (t.bound >= 18_446_744_073_709_551_616) return null;
    let n = Blob.toArray(t.nonce);
    ?Blob.fromArray(Array.tabulate<Nat8>(LEN, func(i) {
      if (i == 0) 1
      else if (i == 1) (switch (t.kind) { case (#swap) 0; case (#join) 1 })
      else if (i == 2) Nat8.fromNat(p.size())
      else if (i < 32) (if (i - 3 < p.size()) p[i - 3] else 0)
      else if (i < 40) Nat8.fromNat((t.bound / (256 ** (39 - i))) % 256)
      else n[i - 40]
    }))
  };

  public func decode(b : Blob) : ?Terms {
    if (b.size() != LEN) return null;
    let a = Blob.toArray(b);
    if (a[0] != 1) return null;
    let kind = switch (a[1]) { case 0 #swap; case 1 #join; case _ return null };
    let len = Nat8.toNat(a[2]);
    if (len == 0 or len > 29) return null;
    var i = 3 + len;
    while (i < 32) { if (a[i] != 0) return null; i += 1 }; // one encoding per terms
    let target = Principal.fromBlob(Blob.fromArray(Array.sliceToArray<Nat8>(a, 3, 3 + len)));
    var bound = 0;
    i := 32;
    while (i < 40) { bound := bound * 256 + Nat8.toNat(a[i]); i += 1 };
    ?{ kind; target; bound; nonce = Blob.fromArray(Array.sliceToArray<Nat8>(a, 40, 72)) }
  };
};
