/// Proof checks that are paid for or priced by work: the bound on what unpaid callers can make a
/// canister spend on Groth16 verifications. Used by the pool (`shield`, `confidential_transfer`)
/// and by the swap canister (with its own digests).
///
/// - Paid path: a canister that attaches `verify_price` cycles per proof is verified
///   unconditionally; the caller of this module accepts the cycles.
/// - Work: `SHA-256(domain || canister id || epoch || digest of the argument || work)` must have
///   at least `d` leading zero bits. Every value is length-prefixed (4 bytes, big-endian) except
///   the fixed 8-byte epoch. The digest covers every field of the argument except `work`, in a
///   fixed serialization (Candid has no canonical encoding a client library is bound to
///   reproduce), so one solution cannot be reused for another argument. The epoch counts every
///   failed free-path verification, so a solution is also spent by the failure it causes.
/// - Difficulty: `d` starts at `d_base`, rises one bit for every `step` failed verifications on
///   the free path within a window, up to `d_max`, and falls one bit for each window that passes
///   with none.
/// - Budget: at most `budget` failed free-path verifications per window. Once spent, the free path
///   refuses before verifying until the window turns.
/// - Backoff: a record whose free attempt failed verification waits `backoff_s`, doubled for each
///   further failure, at most one hour.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

module {
  public let MAX_WORK_BYTES : Nat = 32;
  public let MAX_BACKOFF_NS : Nat64 = 3_600_000_000_000;
  /// The pool's domain tag; the swap canister uses its own.
  public let POOL_DOMAIN : Text = "picp-pool-work/v1";

  public type Config = { d_base : Nat; d_max : Nat; step : Nat; window_ns : Nat64; budget : Nat };

  public type Gate = { var d : Nat; var window_start_ns : Nat64; var failures : Nat; var epoch : Nat };

  public type View = { d : Nat; window_start_ns : Nat64; failures : Nat; spent : Bool; epoch : Nat };

  public func newGate(now : Nat64) : Gate = { var d = 0; var window_start_ns = now; var failures = 0; var epoch = 0 };

  // ---- the serialization the digests use ----

  public func u8(d : Sha256.Digest, x : Nat8) { d.writeArray([x]) };

  public func u32be(d : Sha256.Digest, x : Nat) {
    let v = Nat32.fromNat(x);
    d.writeArray([Nat8.fromNat(Nat32.toNat(v >> 24)), Nat8.fromNat(Nat32.toNat((v >> 16) & 0xff)), Nat8.fromNat(Nat32.toNat((v >> 8) & 0xff)), Nat8.fromNat(Nat32.toNat(v & 0xff))]);
  };

  public func u64be(d : Sha256.Digest, x : Nat64) {
    d.writeArray(Array.tabulate<Nat8>(8, func(i) { Nat8.fromNat(Nat64.toNat((x >> Nat64.fromNat(8 * (7 - i))) & 0xff)) }));
  };

  public func field(d : Sha256.Digest, b : Blob) { u32be(d, b.size()); d.writeBlob(b) };

  public func text(d : Sha256.Digest, t : Text) { field(d, Text.encodeUtf8(t)) };

  /// An optional blob: one byte 0 for null, or 1 and the field.
  public func optField(d : Sha256.Digest, b : ?Blob) {
    switch (b) { case (?v) { u8(d, 1); field(d, v) }; case null u8(d, 0) };
  };

  /// An optional 8-byte integer: one byte 0 for null, or 1 and the integer.
  public func optU64(d : Sha256.Digest, x : ?Nat64) {
    switch (x) { case (?v) { u8(d, 1); u64be(d, v) }; case null u8(d, 0) };
  };

  // ---- the pool's digests ----

  public type ShieldFields = {
    value : Nat64;
    from_subaccount : ?Blob;
    created_at_time : Nat64;
    client_nonce : Blob;
    commitment : Blob;
    ephemeral_key : Blob;
    note_ciphertext : Blob;
    proof_hex : Text;
  };

  public type OutputFields = { commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob };

  public type TransferFields = {
    anchor : Blob;
    nullifier_1 : Blob;
    nullifier_2 : Blob;
    output_1 : OutputFields;
    output_2 : OutputFields;
    fee : Nat64;
    v_pub_out : Nat64;
    recipient : ?{ owner : Principal; subaccount : ?Blob };
    created_at_time : ?Nat64;
    proof_hex : Text;
    claim_envelope : ?Blob;
  };

  func output(d : Sha256.Digest, o : OutputFields) {
    field(d, o.commitment);
    field(d, o.ephemeral_key);
    field(d, o.note_ciphertext);
  };

  /// Every field of a shield's argument but `work`, in declaration order.
  public func shieldDigest(a : ShieldFields) : Blob {
    let d = Sha256.Digest(#sha256);
    text(d, "shield");
    u64be(d, a.value);
    optField(d, a.from_subaccount);
    u64be(d, a.created_at_time);
    field(d, a.client_nonce);
    field(d, a.commitment);
    field(d, a.ephemeral_key);
    field(d, a.note_ciphertext);
    text(d, a.proof_hex);
    d.sum()
  };

  /// Every field of a confidential transfer's argument but `work`, in declaration order. The
  /// recipient is one byte 0 for null, or 1, the owner and the optional subaccount.
  public func transferDigest(a : TransferFields) : Blob {
    let d = Sha256.Digest(#sha256);
    text(d, "confidential_transfer");
    field(d, a.anchor);
    field(d, a.nullifier_1);
    field(d, a.nullifier_2);
    output(d, a.output_1);
    output(d, a.output_2);
    u64be(d, a.fee);
    u64be(d, a.v_pub_out);
    switch (a.recipient) {
      case (?r) { u8(d, 1); field(d, Principal.toBlob(r.owner)); optField(d, r.subaccount) };
      case null u8(d, 0);
    };
    optU64(d, a.created_at_time);
    text(d, a.proof_hex);
    optField(d, a.claim_envelope);
    d.sum()
  };

  // ---- the puzzle ----

  public func leadingZeroBits(b : Blob) : Nat {
    var n = 0;
    for (x in b.vals()) {
      if (x == 0) n += 8
      else {
        var y = x;
        while (y < 0x80) { n += 1; y <<= 1 };
        return n;
      };
    };
    n
  };

  public func workHash(domain : Text, self : Principal, epoch : Nat, argDigest : Blob, work : Blob) : Blob {
    let d = Sha256.Digest(#sha256);
    text(d, domain);
    field(d, Principal.toBlob(self));
    u64be(d, Nat64.fromNat(epoch));
    field(d, argDigest);
    field(d, work);
    d.sum()
  };

  public func passes(domain : Text, self : Principal, epoch : Nat, argDigest : Blob, work : Blob, d : Nat) : Bool {
    if (work.size() > MAX_WORK_BYTES) return false;
    d == 0 or leadingZeroBits(workHash(domain, self, epoch, argDigest, work)) >= d
  };

  // ---- difficulty, window and budget ----

  func clamp(d : Nat, c : Config) : Nat = Nat.min(Nat.max(d, c.d_base), c.d_max);

  /// The gate as it stands at `now`, without changing it (also what `inspect` reads).
  public func view(g : Gate, c : Config, now : Nat64) : View {
    if (now < g.window_start_ns + c.window_ns) {
      let d = clamp(g.d, c);
      return { d; window_start_ns = g.window_start_ns; failures = g.failures; spent = g.failures >= c.budget; epoch = g.epoch };
    };
    let elapsed = Nat64.toNat((now - g.window_start_ns) / c.window_ns);
    // each window that passed with no failure lowers d by one; the one just ended had g.failures
    let quiet = if (g.failures == 0) elapsed else elapsed - 1;
    let d = clamp(if (g.d > quiet) g.d - quiet else 0, c);
    { d; window_start_ns = g.window_start_ns + Nat64.fromNat(elapsed) * c.window_ns; failures = 0; spent = false; epoch = g.epoch }
  };

  /// Brings the gate to `now`.
  public func roll(g : Gate, c : Config, now : Nat64) : View {
    let v = view(g, c, now);
    g.d := v.d;
    g.window_start_ns := v.window_start_ns;
    g.failures := v.failures;
    v
  };

  /// A failed verification on the free path, after `roll`.
  public func fail(g : Gate, c : Config) {
    g.failures += 1;
    g.epoch += 1;
    if (g.failures % c.step == 0) g.d := Nat.min(clamp(g.d, c) + 1, c.d_max);
  };

  /// The wait before a record's next free attempt, after its `failures`-th failure (1, 2, ...).
  public func backoffNs(failures : Nat, backoff_s : Nat) : Nat64 {
    var ns : Nat = backoff_s * 1_000_000_000;
    var i = 1;
    while (i < failures and ns < Nat64.toNat(MAX_BACKOFF_NS)) { ns *= 2; i += 1 };
    Nat64.fromNat(Nat.min(ns, Nat64.toNat(MAX_BACKOFF_NS)))
  };
};
