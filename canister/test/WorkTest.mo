/// Work.mo: the argument digests against vectors computed independently (Python hashlib over the
/// serialization Work.mo documents), the puzzle, the window, the budget and the backoff.
/// Run from swap/: moc -r --package core vendor/core@1.0.0/src --package sha2 vendor/sha2@0.1.9/src canister/test/WorkTest.mo
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Debug "mo:core/Debug";
import Work "../src/Work";

var passed = 0;
func check(what : Text, ok : Bool) {
  if (not ok) Runtime.trap("FAIL " # what);
  passed += 1;
};

func hex(b : Blob) : Text {
  let d = "0123456789abcdef";
  var t = "";
  for (x in b.vals()) {
    let n = Nat8.toNat(x);
    t #= Text.fromChar(Text.toArray(d)[n / 16]) # Text.fromChar(Text.toArray(d)[n % 16]);
  };
  t
};
func fill(n : Nat, v : Nat8) : Blob = Blob.fromArray(Array.repeat<Nat8>(v, n));

// ---- the digests, against hashlib ----
let owner = Principal.fromBlob("\DE\AD\00\01");
let spend : Work.SpendFields = {
  anchor = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) }));
  nullifier_1 = fill(32, 1);
  nullifier_2 = fill(32, 2);
  output_1 = { commitment = fill(32, 3); ephemeral_key = fill(32, 4); note_ciphertext = Text.encodeUtf8("ct-one") };
  output_2 = { commitment = fill(32, 5); ephemeral_key = fill(32, 6); note_ciphertext = "" };
  fee = 0;
  v_pub_out = 1000;
  proof_hex = "abcdef0123";
};
let ld = Work.leaveDigest(owner, spend);
check("leave digest = hashlib", hex(ld) == "73f3b9fc430895ef80ed56c53a939effc0cd58859d672e627c386c9f72bdd19e");
let notes : [Work.ReceiptNoteFields] = [
  { commitment = fill(32, 7); ephemeral_key = fill(32, 8); note_ciphertext = "x"; value = 600; proof_hex = "11" },
  { commitment = fill(32, 9); ephemeral_key = fill(32, 10); note_ciphertext = ""; value = 400; proof_hex = "22" },
];
check("receipt digest = hashlib", hex(Work.receiptDigest(42, notes)) == "14e22ec573ce722799df37f3943871ee975d9f824df7ee29a2b8e4d636821dc6");
let selfp = Principal.fromBlob("\DE\AD\00\00\00\00\00\01\01\01");
check("work hash = hashlib", hex(Work.workHash(selfp, 0, ld, "\2A")) == "00711dc22d737fa66414a0f9fafff1341e676a82383bc1d528675f28b6f4ead1");

let lockArgs : Work.LockFields = {
  anchor = spend.anchor;
  nullifier_1 = fill(32, 1);
  nullifier_2 = fill(32, 2);
  output_1 = spend.output_1;
  output_2 = spend.output_2;
  fee = 1000;
  v_pub_out = 100_000;
  proof_hex = "abcdef0123";
  owner;
  terms = fill(72, 9);
};
let lockPool = Principal.fromBlob("\DE\AD\00\03");
let lk = Work.lockDigest(lockPool, lockArgs);
check("lock digest = hashlib", hex(lk) == "4a67d609daa990d922180a3f691d7e13fff64b476d305cf455b4c9555a843649");
let collectArgs : Work.CollectFields = { owed_id = 42; commitment = fill(32, 7); ephemeral_key = fill(32, 8); note_ciphertext = "x"; proof_hex = "11" };
let cd = Work.collectDigest(collectArgs);
check("collect digest = hashlib", hex(cd) == "32d09ff0e38a8a617bcad1cd8eafe9a29a46ed570ab143bec028675cae060480");
let lockVariants : [Work.LockFields] = [
  { lockArgs with anchor = fill(32, 0xFF) },
  { lockArgs with nullifier_2 = fill(32, 0xFF) },
  { lockArgs with output_2 = { lockArgs.output_2 with note_ciphertext = "z" } },
  { lockArgs with fee = 1001 },
  { lockArgs with v_pub_out = 100_001 },
  { lockArgs with proof_hex = "abcdef0124" },
  { lockArgs with owner = Principal.fromBlob("\DE\AD\00\02") },
  { lockArgs with terms = fill(72, 8) },
];
for (v in lockVariants.vals()) check("a changed field changes the lock digest", not Blob.equal(Work.lockDigest(lockPool, v), lk));
check("another pool changes the lock digest", not Blob.equal(Work.lockDigest(Principal.fromBlob("\DE\AD\00\04"), lockArgs), lk));
check("another owed record changes the collect digest", not Blob.equal(Work.collectDigest({ collectArgs with owed_id = 43 }), cd));
check("another proof changes the collect digest", not Blob.equal(Work.collectDigest({ collectArgs with proof_hex = "12" }), cd));
check("a lock is not a leave", not Blob.equal(lk, Work.leaveDigest(owner, spend)));

// the pools' verifier verdicts, and nothing else, are failed verifications
for (v in ["REJECT:hex", "REJECT:inputs-deserialize", "REJECT:pairing-check", "REJECT:proof-deserialize", "REJECT:vk-deserialize"].vals()) check("a verifier verdict: " # v, Work.isVerifierVerdict(v));
for (v in ["ACCEPT", "REJECT:unknown-anchor", "REJECT:swap-proof-budget-spent", "REJECT:pairing-check ", "REJECT:unconfigured", ""].vals()) check("not a verifier verdict: " # v, not Work.isVerifierVerdict(v));

// every field is bound: changing any one changes the digest
let variants : [Work.SpendFields] = [
  { spend with anchor = fill(32, 0xFF) },
  { spend with nullifier_1 = fill(32, 0xFF) },
  { spend with nullifier_2 = fill(32, 0xFF) },
  { spend with output_1 = { spend.output_1 with note_ciphertext = "ct-onf" } },
  { spend with output_2 = { spend.output_2 with ephemeral_key = fill(32, 7) } },
  { spend with fee = 1 },
  { spend with v_pub_out = 1001 },
  { spend with proof_hex = "abcdef0124" },
];
for (v in variants.vals()) check("a changed field changes the leave digest", not Blob.equal(Work.leaveDigest(owner, v), ld));
check("another owner changes the leave digest", not Blob.equal(Work.leaveDigest(Principal.fromBlob("\DE\AD\00\02"), spend), ld));
check("another receipt id changes the receipt digest", not Blob.equal(Work.receiptDigest(43, notes), Work.receiptDigest(42, notes)));
check("another value changes the receipt digest", not Blob.equal(Work.receiptDigest(42, [notes[0], { notes[1] with value = 401 }]), Work.receiptDigest(42, notes)));
check("one note is not two", not Blob.equal(Work.receiptDigest(42, [notes[0]]), Work.receiptDigest(42, notes)));
// the length prefix separates fields: moving a byte between two fields changes the digest
check("field boundaries are bound", not Blob.equal(
  Work.leaveDigest(owner, { spend with output_1 = { spend.output_1 with note_ciphertext = "ct-on" }; output_2 = { spend.output_2 with note_ciphertext = "e" } }),
  Work.leaveDigest(owner, { spend with output_1 = { spend.output_1 with note_ciphertext = "ct-one" }; output_2 = { spend.output_2 with note_ciphertext = "" } })));

// ---- the puzzle ----
check("zero bits of 0x80..", Work.leadingZeroBits("\80\00") == 0);
check("one bit of 0x40", Work.leadingZeroBits("\40") == 1);
check("nine bits of 00 40", Work.leadingZeroBits("\00\40") == 9);
check("fifteen bits of 00 01", Work.leadingZeroBits("\00\01") == 15);
check("all zero", Work.leadingZeroBits("\00\00\00") == 24);
// hashlib found work 0000124d giving 14 leading zero bits for this argument at epoch 7
check("14 bits pass d = 14", Work.passes(selfp, 7, ld, "\00\00\12\4D", 14));
check("14 bits fail d = 15", not Work.passes(selfp, 7, ld, "\00\00\12\4D", 15));
check("the same work at the next epoch fails", not Work.passes(selfp, 8, ld, "\00\00\12\4D", 13));
check("the same work for another argument fails", not Work.passes(selfp, 7, Work.receiptDigest(42, notes), "\00\00\12\4D", 13));
check("the same work for another canister fails", not Work.passes(Principal.fromBlob("\DE\AD\00\00\00\00\00\01\01\02"), 7, ld, "\00\00\12\4D", 13));
check("d = 0 needs no work", Work.passes(selfp, 7, ld, "", 0));
check("work over 32 bytes is refused even at d = 0", not Work.passes(selfp, 7, ld, fill(33, 0), 0));

// ---- window, difficulty, budget ----
let W : Nat64 = 60_000_000_000;
let c : Work.Config = { d_base = 0; d_max = 3; step = 2; window_ns = W; budget = 3 };
let g = Work.newGate(1_000);
var v = Work.roll(g, c, 1_000);
check("starts at d_base", v.d == 0 and v.failures == 0 and not v.spent);
Work.fail(g, c);
check("one failure: d unchanged", Work.view(g, c, 2_000).d == 0);
Work.fail(g, c);
check("step failures: d + 1", Work.view(g, c, 2_000).d == 1);
Work.fail(g, c);
check("budget failures: spent", Work.view(g, c, 2_000).spent);
check("view changes nothing", g.failures == 3 and g.d == 1);
check("every failure advances the epoch", g.epoch == 3);
// the next window: budget back, d kept (the window just ended had failures)
v := Work.roll(g, c, 1_000 + W);
check("next window: budget back", not v.spent and v.failures == 0 and v.d == 1);
check("the epoch survives the window", v.epoch == 3);
// a quiet window lowers d by one
v := Work.roll(g, c, 1_000 + 2 * W);
check("a quiet window: d - 1", v.d == 0);
// d never above d_max, never below d_base
let g2 = Work.newGate(0);
for (i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].vals()) { ignore Work.roll(g2, { c with budget = 64 }, 0); Work.fail(g2, { c with budget = 64 }) };
check("d stops at d_max", Work.view(g2, c, 0).d == 3);
check("d_base raises d", Work.view(Work.newGate(0), { c with d_base = 2 }, 0).d == 2);
// several quiet windows at once
let g3 = Work.newGate(0);
g3.d := 3;
check("three quiet windows: d - 3", Work.view(g3, c, 3 * W).d == 0);
g3.failures := 1;
check("three windows, the first with a failure: d - 2", Work.view(g3, c, 3 * W).d == 1);

// ---- attempts out at a pool hold the budget ----
let gh = Work.newGate(0);
let ch : Work.Config = { c with budget = 2 };
Work.hold(gh);
check("one attempt out: not spent", not Work.view(gh, ch, 1).spent and Work.view(gh, ch, 1).inflight == 1);
Work.hold(gh);
check("two attempts out, budget 2: spent", Work.view(gh, ch, 1).spent);
check("holding is not failing", gh.failures == 0 and gh.epoch == 0 and Work.view(gh, ch, 1).d == 0);
check("still spent in the next window while they are out", Work.view(gh, ch, W + 1).spent);
Work.release(gh);
check("one back: not spent", not Work.view(gh, ch, 1).spent);
ignore Work.roll(gh, ch, 1);
Work.fail(gh, ch);
check("one out and one failed: spent", Work.view(gh, ch, 1).spent);
Work.release(gh);
check("released: the failure alone, under budget", not Work.view(gh, ch, 1).spent and Work.view(gh, ch, 1).inflight == 0);
Work.release(gh);
check("release never goes below 0", gh.inflight == 0);

// ---- backoff ----
check("first wait backoff_s", Work.backoffNs(1, 30) == 30_000_000_000);
check("second doubles", Work.backoffNs(2, 30) == 60_000_000_000);
check("fifth", Work.backoffNs(5, 30) == 480_000_000_000);
check("capped at one hour", Work.backoffNs(20, 30) == 3_600_000_000_000);
check("cap applies to a long first wait", Work.backoffNs(1, 3_600) == 3_600_000_000_000);

Debug.print("WorkTest: " # debug_show (passed) # " checks PASS");
