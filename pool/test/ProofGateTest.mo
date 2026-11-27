/// ProofGate.mo: the pool's argument digests against vectors computed independently (Python
/// hashlib over the serialization ProofGate.mo documents), the domain tag, the puzzle, the window,
/// the budget and the backoff.
/// Run from swap/: moc -r --package core vendor/core@1.0.0/src --package sha2 vendor/sha2@0.1.9/src pool/test/ProofGateTest.mo
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Debug "mo:core/Debug";
import G "../src/ProofGate";

var passed = 0;
func check(what : Text, ok : Bool) {
  if (not ok) Runtime.trap("FAIL " # what);
  passed += 1;
};

func hex(b : Blob) : Text {
  let d = Text.toArray("0123456789abcdef");
  var t = "";
  for (x in b.vals()) {
    let n = Nat8.toNat(x);
    t #= Text.fromChar(d[n / 16]) # Text.fromChar(d[n % 16]);
  };
  t
};
func fill(n : Nat, v : Nat8) : Blob = Blob.fromArray(Array.repeat<Nat8>(v, n));

// ---- the digests, against hashlib ----
let shield : G.ShieldFields = {
  value = 123456;
  from_subaccount = ?fill(32, 9);
  created_at_time = 1_700_000_000_000_000_000;
  client_nonce = fill(32, 7);
  commitment = fill(32, 3);
  ephemeral_key = fill(32, 4);
  note_ciphertext = Text.encodeUtf8("ct-one");
  proof_hex = "abcdef0123";
};
let sd = G.shieldDigest(shield);
check("shield digest = hashlib", hex(sd) == "c372a0cbc81d466e2991d2cc9e380d9a3c038bc75b43f8b1c245936fd7569df3");
check("shield digest without subaccount = hashlib", hex(G.shieldDigest({ shield with from_subaccount = null })) == "a8cc3c5849ee3981f44103c6302e454e8cbfa0c0ff0438799a39e2855ac75c9e");
let transfer : G.TransferFields = {
  anchor = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) }));
  nullifier_1 = fill(32, 1);
  nullifier_2 = fill(32, 2);
  output_1 = { commitment = fill(32, 3); ephemeral_key = fill(32, 4); note_ciphertext = Text.encodeUtf8("ct-one") };
  output_2 = { commitment = fill(32, 5); ephemeral_key = fill(32, 6); note_ciphertext = "" };
  fee = 10;
  v_pub_out = 1000;
  recipient = ?{ owner = Principal.fromBlob("\DE\AD\00\02"); subaccount = null };
  created_at_time = ?42;
  proof_hex = "abcdef0123";
  claim_envelope = null;
};
let td = G.transferDigest(transfer);
check("transfer digest = hashlib", hex(td) == "e712af233169d3bba4a076979fc73a1bf9c802bb8d9dd132a93524599f717cb0");
check("private transfer digest = hashlib", hex(G.transferDigest({ transfer with v_pub_out = 0; recipient = null; created_at_time = null; claim_envelope = ?fill(16, 8) })) == "06c65f981d79b760b07a887c9dc004f712fe5619c6b8cf22fc3807529e783e10");
let selfp = Principal.fromBlob("\DE\AD\00\00\00\00\00\01\01\01");
check("work hash = hashlib", hex(G.workHash(G.POOL_DOMAIN, selfp, 0, sd, "\2A")) == "069dbe1a6575a220f93d8e869c322667d847fe8cb9f901049913cea5fa8b5927");
check("the domain is bound = hashlib", hex(G.workHash("picp-swap-work/v1", selfp, 0, sd, "\2A")) == "67bac2537b5bd4eed0f1e4b0f401b4b63e7ec1b5a327c6bc8e6a425d567ac650");

// every field is bound: changing any one changes the digest
let shieldVariants : [G.ShieldFields] = [
  { shield with value = 123457 },
  { shield with from_subaccount = ?fill(32, 8) },
  { shield with created_at_time = 1 },
  { shield with client_nonce = fill(32, 6) },
  { shield with commitment = fill(32, 2) },
  { shield with ephemeral_key = fill(32, 5) },
  { shield with note_ciphertext = Text.encodeUtf8("ct-onf") },
  { shield with proof_hex = "abcdef0124" },
];
for (v in shieldVariants.vals()) check("a changed field changes the shield digest", not Blob.equal(G.shieldDigest(v), sd));
let transferVariants : [G.TransferFields] = [
  { transfer with anchor = fill(32, 0xFF) },
  { transfer with nullifier_1 = fill(32, 0xFF) },
  { transfer with nullifier_2 = fill(32, 0xFF) },
  { transfer with output_1 = { transfer.output_1 with commitment = fill(32, 9) } },
  { transfer with output_2 = { transfer.output_2 with ephemeral_key = fill(32, 7) } },
  { transfer with fee = 11 },
  { transfer with v_pub_out = 1001 },
  { transfer with recipient = ?{ owner = Principal.fromBlob("\DE\AD\00\03"); subaccount = null } },
  { transfer with recipient = ?{ owner = Principal.fromBlob("\DE\AD\00\02"); subaccount = ?fill(32, 1) } },
  { transfer with recipient = null },
  { transfer with created_at_time = ?43 },
  { transfer with created_at_time = null },
  { transfer with proof_hex = "abcdef0124" },
  { transfer with claim_envelope = ?"" },
];
for (v in transferVariants.vals()) check("a changed field changes the transfer digest", not Blob.equal(G.transferDigest(v), td));
// the length prefix separates fields: moving a byte between two fields changes the digest
check("field boundaries are bound", not Blob.equal(
  G.transferDigest({ transfer with output_1 = { transfer.output_1 with note_ciphertext = "ct-on" }; output_2 = { transfer.output_2 with note_ciphertext = "e" } }),
  td));
check("a shield is not a transfer", not Blob.equal(sd, td));

// ---- the puzzle ----
check("zero bits of 0x80..", G.leadingZeroBits("\80\00") == 0);
check("one bit of 0x40", G.leadingZeroBits("\40") == 1);
check("nine bits of 00 40", G.leadingZeroBits("\00\40") == 9);
check("fifteen bits of 00 01", G.leadingZeroBits("\00\01") == 15);
check("all zero", G.leadingZeroBits("\00\00\00") == 24);
// hashlib found work 0000000000000dff giving 12 leading zero bits for the shield at epoch 5, and 2 at epoch 6
let w12 : Blob = "\00\00\00\00\00\00\0D\FF";
check("12 bits pass d = 12", G.passes(G.POOL_DOMAIN, selfp, 5, sd, w12, 12));
check("12 bits fail d = 13", not G.passes(G.POOL_DOMAIN, selfp, 5, sd, w12, 13));
check("the same work at the next epoch fails", not G.passes(G.POOL_DOMAIN, selfp, 6, sd, w12, 3));
check("the same work for another argument fails", not G.passes(G.POOL_DOMAIN, selfp, 5, td, w12, 12));
check("the same work under another domain fails", not G.passes("picp-swap-work/v1", selfp, 5, sd, w12, 12));
check("the same work for another canister fails", not G.passes(G.POOL_DOMAIN, Principal.fromBlob("\DE\AD\00\00\00\00\00\01\01\02"), 5, sd, w12, 12));
check("d = 0 needs no work", G.passes(G.POOL_DOMAIN, selfp, 5, sd, "", 0));
check("work over 32 bytes is refused even at d = 0", not G.passes(G.POOL_DOMAIN, selfp, 5, sd, fill(33, 0), 0));

// ---- window, difficulty, budget ----
let W : Nat64 = 60_000_000_000;
let c : G.Config = { d_base = 0; d_max = 3; step = 2; window_ns = W; budget = 3 };
let g = G.newGate(1_000);
var v = G.roll(g, c, 1_000);
check("starts at d_base", v.d == 0 and v.failures == 0 and not v.spent);
G.fail(g, c);
check("one failure: d unchanged", G.view(g, c, 2_000).d == 0);
G.fail(g, c);
check("step failures: d + 1", G.view(g, c, 2_000).d == 1);
G.fail(g, c);
check("budget failures: spent", G.view(g, c, 2_000).spent);
check("view changes nothing", g.failures == 3 and g.d == 1);
check("every failure advances the epoch", g.epoch == 3);
v := G.roll(g, c, 1_000 + W);
check("next window: budget back", not v.spent and v.failures == 0 and v.d == 1);
check("the epoch survives the window", v.epoch == 3);
v := G.roll(g, c, 1_000 + 2 * W);
check("a quiet window: d - 1", v.d == 0);
let g2 = G.newGate(0);
for (i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].vals()) { ignore G.roll(g2, { c with budget = 64 }, 0); G.fail(g2, { c with budget = 64 }) };
check("d stops at d_max", G.view(g2, c, 0).d == 3);
check("d_base raises d", G.view(G.newGate(0), { c with d_base = 2 }, 0).d == 2);
let g3 = G.newGate(0);
g3.d := 3;
check("three quiet windows: d - 3", G.view(g3, c, 3 * W).d == 0);
g3.failures := 1;
check("three windows, the first with a failure: d - 2", G.view(g3, c, 3 * W).d == 1);

// ---- backoff ----
check("first wait backoff_s", G.backoffNs(1, 30) == 30_000_000_000);
check("second doubles", G.backoffNs(2, 30) == 60_000_000_000);
check("fifth", G.backoffNs(5, 30) == 480_000_000_000);
check("capped at one hour", G.backoffNs(20, 30) == 3_600_000_000_000);
check("cap applies to a long first wait", G.backoffNs(1, 3_600) == 3_600_000_000_000);

Debug.print("ProofGateTest: " # debug_show (passed) # " checks PASS");
