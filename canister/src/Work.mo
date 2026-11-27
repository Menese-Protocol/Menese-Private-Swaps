/// The free path's price and bound for the methods that have a Groth16 proof verified on a
/// caller's behalf: here (`leave`, `collect_receipt`) or by the pool they forward it to (`lock`,
/// `collect`).
///
/// - Work: `SHA-256("picp-swap-work/v1" || canister id || epoch || digest of the argument || work)`
///   must have at least `d` leading zero bits. The digest covers every field of the argument except
///   `work`, in a fixed length-prefixed serialization (Candid has no canonical encoding a client
///   library is bound to reproduce), so one solution cannot be reused for another argument. The
///   epoch counts every failed free-path verification, so a solution is also spent by the failure
///   it causes: sending the same forged argument again needs new work.
/// - Difficulty: `d` starts at `d_base`, rises one bit for every `step` failed verifications on
///   the free path within a window, up to `d_max`, and falls one bit for each window that passes
///   with none.
/// - Budget: at most `budget` failed free-path verifications per window. Once spent, the free path
///   refuses before verifying until the window turns. A free attempt forwarded to a pool holds one
///   unit of the budget while its call is out (`hold` / `release`), so attempts sent together
///   cannot pass the check before any of them has failed.
/// - Backoff: a receipt or owed record whose free collect failed verification waits `backoff_s`,
///   doubled for each further failure, at most one hour, before its next free attempt.
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

  public type Config = { d_base : Nat; d_max : Nat; step : Nat; window_ns : Nat64; budget : Nat };

  public type Gate = { var d : Nat; var window_start_ns : Nat64; var failures : Nat; var epoch : Nat; var inflight : Nat };

  public type View = { d : Nat; window_start_ns : Nat64; failures : Nat; spent : Bool; epoch : Nat; inflight : Nat };

  public func newGate(now : Nat64) : Gate = { var d = 0; var window_start_ns = now; var failures = 0; var epoch = 0; var inflight = 0 };

  /// What the pools' verifier answers when it refuses a proof (pool/src/groth16/Groth16Wire.mo):
  /// a pool's refusal of a forwarded proof is a failed verification only when it is one of these.
  public let VERIFIER_VERDICTS : [Text] = ["REJECT:hex", "REJECT:inputs-deserialize", "REJECT:pairing-check", "REJECT:proof-deserialize", "REJECT:vk-deserialize"];

  public func isVerifierVerdict(t : Text) : Bool {
    for (v in VERIFIER_VERDICTS.vals()) { if (v == t) return true };
    false
  };

  public type NoteFields = { commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob };

  public type SpendFields = {
    anchor : Blob;
    nullifier_1 : Blob;
    nullifier_2 : Blob;
    output_1 : NoteFields;
    output_2 : NoteFields;
    fee : Nat64;
    v_pub_out : Nat64;
    proof_hex : Text;
  };

  public type ReceiptNoteFields = { commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob; value : Nat64; proof_hex : Text };

  public type LockFields = {
    anchor : Blob;
    nullifier_1 : Blob;
    nullifier_2 : Blob;
    output_1 : NoteFields;
    output_2 : NoteFields;
    fee : Nat64;
    v_pub_out : Nat64;
    proof_hex : Text;
    owner : Principal;
    terms : Blob;
  };

  public type CollectFields = { owed_id : Nat64; commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob; proof_hex : Text };

  // ---- the argument digests ----

  func u32be(d : Sha256.Digest, x : Nat) {
    let v = Nat32.fromNat(x);
    d.writeArray([Nat8.fromNat(Nat32.toNat(v >> 24)), Nat8.fromNat(Nat32.toNat((v >> 16) & 0xff)), Nat8.fromNat(Nat32.toNat((v >> 8) & 0xff)), Nat8.fromNat(Nat32.toNat(v & 0xff))]);
  };

  func u64be(d : Sha256.Digest, x : Nat64) {
    d.writeArray(Array.tabulate<Nat8>(8, func(i) { Nat8.fromNat(Nat64.toNat((x >> Nat64.fromNat(8 * (7 - i))) & 0xff)) }));
  };

  func field(d : Sha256.Digest, b : Blob) { u32be(d, b.size()); d.writeBlob(b) };

  func note(d : Sha256.Digest, n : NoteFields) {
    field(d, n.commitment);
    field(d, n.ephemeral_key);
    field(d, n.note_ciphertext);
  };

  /// Every field of a leave's argument but `work`, in declaration order.
  public func leaveDigest(owner : Principal, s : SpendFields) : Blob {
    let d = Sha256.Digest(#sha256);
    field(d, Text.encodeUtf8("leave"));
    field(d, Principal.toBlob(owner));
    field(d, s.anchor);
    field(d, s.nullifier_1);
    field(d, s.nullifier_2);
    note(d, s.output_1);
    note(d, s.output_2);
    u64be(d, s.fee);
    u64be(d, s.v_pub_out);
    field(d, Text.encodeUtf8(s.proof_hex));
    d.sum()
  };

  /// Every field of a collect_receipt's argument but `work`, in declaration order.
  public func receiptDigest(receipt_id : Nat64, notes : [ReceiptNoteFields]) : Blob {
    let d = Sha256.Digest(#sha256);
    field(d, Text.encodeUtf8("collect_receipt"));
    u64be(d, receipt_id);
    u32be(d, notes.size());
    for (n in notes.vals()) {
      note(d, n);
      u64be(d, n.value);
      field(d, Text.encodeUtf8(n.proof_hex));
    };
    d.sum()
  };

  /// The source pool and every field of a lock's argument, in declaration order.
  public func lockDigest(pool : Principal, a : LockFields) : Blob {
    let d = Sha256.Digest(#sha256);
    field(d, Text.encodeUtf8("lock"));
    field(d, Principal.toBlob(pool));
    field(d, a.anchor);
    field(d, a.nullifier_1);
    field(d, a.nullifier_2);
    note(d, a.output_1);
    note(d, a.output_2);
    u64be(d, a.fee);
    u64be(d, a.v_pub_out);
    field(d, Text.encodeUtf8(a.proof_hex));
    field(d, Principal.toBlob(a.owner));
    field(d, a.terms);
    d.sum()
  };

  /// Every field of a collect's argument but `work`, in declaration order.
  public func collectDigest(a : CollectFields) : Blob {
    let d = Sha256.Digest(#sha256);
    field(d, Text.encodeUtf8("collect"));
    u64be(d, a.owed_id);
    field(d, a.commitment);
    field(d, a.ephemeral_key);
    field(d, a.note_ciphertext);
    field(d, Text.encodeUtf8(a.proof_hex));
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

  public func workHash(self : Principal, epoch : Nat, argDigest : Blob, work : Blob) : Blob {
    let d = Sha256.Digest(#sha256);
    field(d, Text.encodeUtf8("picp-swap-work/v1"));
    field(d, Principal.toBlob(self));
    u64be(d, Nat64.fromNat(epoch));
    field(d, argDigest);
    field(d, work);
    d.sum()
  };

  public func passes(self : Principal, epoch : Nat, argDigest : Blob, work : Blob, d : Nat) : Bool {
    if (work.size() > MAX_WORK_BYTES) return false;
    d == 0 or leadingZeroBits(workHash(self, epoch, argDigest, work)) >= d
  };

  // ---- difficulty, window and budget ----

  func clamp(d : Nat, c : Config) : Nat = Nat.min(Nat.max(d, c.d_base), c.d_max);

  /// The gate as it stands at `now`, without changing it (also what `inspect` reads).
  public func view(g : Gate, c : Config, now : Nat64) : View {
    if (now < g.window_start_ns + c.window_ns) {
      let d = clamp(g.d, c);
      return { d; window_start_ns = g.window_start_ns; failures = g.failures; spent = g.failures + g.inflight >= c.budget; epoch = g.epoch; inflight = g.inflight };
    };
    let elapsed = Nat64.toNat((now - g.window_start_ns) / c.window_ns);
    // each window that passed with no failure lowers d by one; the one just ended had g.failures
    let quiet = if (g.failures == 0) elapsed else elapsed - 1;
    let d = clamp(if (g.d > quiet) g.d - quiet else 0, c);
    { d; window_start_ns = g.window_start_ns + Nat64.fromNat(elapsed) * c.window_ns; failures = 0; spent = g.inflight >= c.budget; epoch = g.epoch; inflight = g.inflight }
  };

  /// Brings the gate to `now`.
  public func roll(g : Gate, c : Config, now : Nat64) : View {
    let v = view(g, c, now);
    g.d := v.d;
    g.window_start_ns := v.window_start_ns;
    g.failures := v.failures;
    v
  };

  /// A free attempt forwarded to a pool, from the check until the pool's answer.
  public func hold(g : Gate) { g.inflight += 1 };

  public func release(g : Gate) { if (g.inflight > 0) g.inflight -= 1 };

  /// A failed verification on the free path, after `roll`.
  public func fail(g : Gate, c : Config) {
    g.failures += 1;
    g.epoch += 1;
    if (g.failures % c.step == 0) g.d := Nat.min(clamp(g.d, c) + 1, c.d_max);
  };

  /// The wait before a receipt's next free attempt, after its `failures`-th failure (1, 2, ...).
  public func backoffNs(failures : Nat, backoff_s : Nat) : Nat64 {
    var ns : Nat = backoff_s * 1_000_000_000;
    var i = 1;
    while (i < failures and ns < Nat64.toNat(MAX_BACKOFF_NS)) { ns *= 2; i += 1 };
    Nat64.fromNat(Nat.min(ns, Nat64.toNat(MAX_BACKOFF_NS)))
  };
};
