/// The receipt tree: providers' shares as private notes, with the pools' own note scheme.
///
/// The same Poseidon tree (arity 4, 16 levels) and the same two frozen Groth16 statements as the
/// private pools: a deposit proof creates a receipt note of a public share amount, a transfer proof
/// spends receipt notes with the shares leaving as its public value. Only this canister's own tree
/// verifies here: an anchor must be one of this tree's own roots, and nullifiers are this tree's
/// own set.
///
/// The tree starts with one GENESIS leaf, a field element derived from a domain string. Nobody
/// holds an opening of it, so no other tree (a fresh pool in particular) can ever reach one of this
/// tree's roots by mirroring its leaves.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Prim "mo:⛔";
import Sha256 "mo:sha2/Sha256";
import PoseidonTree "mo:zk/PoseidonTree";
import Fr "mo:zk/groth16/Fr";
import Groth16Multi "mo:zk/groth16/Groth16Multi";
import Groth16Wire "mo:zk/groth16/Groth16Wire";

module {
  public let MAX_EPK : Nat = 256;
  public let MAX_CIPHERTEXT : Nat = 1024;

  public type Note = { commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob };

  public type State = {
    var frontier : PoseidonTree.Frontier;
    var root : Blob;
    roots : Map.Map<Blob, ()>;
    nullifiers : Map.Map<Blob, ()>;
    notes : List.List<Note>;
  };

  public type Prepared = { vk : Groth16Multi.PreparedVk; flat : Groth16Multi.FlatVk };
  public type Keys = { transfer : Prepared; deposit : Prepared };

  /// Parse and prepare one verifying key. Each key costs up to the per-message instruction budget
  /// of a large part of one message, so the caller prepares the two keys in separate messages.
  public func prepareOne(hex : Text) : ?Prepared {
    switch (Groth16Wire.parseAndPrepareVk(hex)) {
      case (?v) ?{ vk = v; flat = Groth16Multi.prepareFlatVk(v) };
      case null null;
    }
  };

  /// sha256(domain) read little-endian with the top byte cleared: always below the field modulus.
  public func genesisLeaf() : Nat {
    let digest = Blob.toArray(Sha256.fromBlob(#sha256, Text.encodeUtf8("menese/private-swaps/receipt-tree/genesis/v1")));
    var value : Nat = 0;
    var shift : Nat = 1;
    var i = 0;
    while (i < 31) { value += Nat8.toNat(digest[i]) * shift; shift *= 256; i += 1 };
    value
  };

  public func newState() : State {
    let zeros = PoseidonTree.zeroHashes();
    let (frontier, root) = PoseidonTree.append(PoseidonTree.emptyFrontier(zeros), zeros, genesisLeaf());
    let rootBlob = PoseidonTree.natToBlob(root);
    let roots = Map.empty<Blob, ()>();
    Map.add(roots, Blob.compare, rootBlob, ());
    let notes = List.empty<Note>();
    List.add(notes, { commitment = PoseidonTree.natToBlob(genesisLeaf()); ephemeral_key = "" : Blob; note_ciphertext = "" : Blob });
    { var frontier = frontier; var root = rootBlob; roots; nullifiers = Map.empty<Blob, ()>(); notes }
  };

  public func noteCount(s : State) : Nat { List.size(s.notes) };
  public func isRoot(s : State, root : Blob) : Bool { Map.containsKey(s.roots, Blob.compare, root) };
  public func isSpent(s : State, nf : Blob) : Bool { Map.containsKey(s.nullifiers, Blob.compare, nf) };

  /// A Groth16 proof is 192 bytes, so 384 hex characters (Groth16Wire.parseProof). Any other length
  /// is refused before anything reads or hashes it.
  public let PROOF_HEX_CHARS : Nat = 384;

  public func proofRejection(proofHex : Text) : ?Text {
    if (proofHex.size() != PROOF_HEX_CHARS) ?"REJECT:proof-length" else null
  };

  public func shapeRejection(n : Note) : ?Text {
    if (n.commitment.size() != 32) return ?"REJECT:commitment-length";
    if (PoseidonTree.blobToNat(n.commitment) == null) return ?"REJECT:commitment-noncanonical";
    if (n.ephemeral_key.size() == 0 or n.note_ciphertext.size() == 0) return ?"REJECT:opaque-record-empty";
    if (n.ephemeral_key.size() > MAX_EPK or n.note_ciphertext.size() > MAX_CIPHERTEXT) return ?"REJECT:opaque-record-size";
    null
  };

  /// Append notes (already validated); returns the new root.
  public func append(s : State, outs : [Note]) : Blob {
    let zeros = PoseidonTree.zeroHashes();
    var frontier = s.frontier;
    var root : Nat = 0;
    for (n in outs.vals()) {
      let leaf = switch (PoseidonTree.blobToNat(n.commitment)) { case (?v) v; case null Prim.trap("validated commitment") };
      let (next, r) = PoseidonTree.append(frontier, zeros, leaf);
      frontier := next;
      root := r;
      List.add(s.notes, n);
    };
    s.frontier := frontier;
    s.root := PoseidonTree.natToBlob(root);
    Map.add(s.roots, Blob.compare, s.root, ());
    s.root
  };

  public func nat64Field(v : Nat64) : Blob {
    let out = Prim.Array_init<Nat8>(32, 0);
    var x = v;
    var i = 0;
    while (i < 8) { out[i] := Nat8.fromNat(Nat64.toNat(x % 256)); x /= 256; i += 1 };
    Blob.fromArray(Array.fromVarArray(out))
  };

  let HEX : [Char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

  public func blobToHex(b : Blob) : Text {
    var t = "";
    for (byte in b.vals()) {
      let n = Nat8.toNat(byte);
      t #= Text.fromChar(HEX[n / 16]) # Text.fromChar(HEX[n % 16]);
    };
    t
  };

  /// ark-serialize Vec<Fr>: u64 little-endian length, then 32-byte compressed Fr values.
  public func publicInputs(fields : [Blob]) : ?Text {
    for (f in fields.vals()) { if (f.size() != 32) return null };
    let bytes = Prim.Array_init<Nat8>(8 + 32 * fields.size(), 0);
    var len = fields.size();
    var i = 0;
    while (i < 8) { bytes[i] := Nat8.fromNat(len % 256); len /= 256; i += 1 };
    var o = 8;
    for (f in fields.vals()) { for (byte in f.vals()) { bytes[o] := byte; o += 1 } };
    ?blobToHex(Blob.fromArray(Array.fromVarArray(bytes)))
  };

  public func verifyDeposit(k : Keys, commitment : Blob, value : Nat64, proofHex : Text) : Text {
    switch (publicInputs([commitment, nat64Field(value)])) {
      case (?inputs) Groth16Wire.verifyPreparedCached(k.deposit.vk, k.deposit.flat, proofHex, inputs);
      case null "REJECT:public-input-encoding";
    }
  };

  public type Spend = {
    anchor : Blob;
    nullifier_1 : Blob;
    nullifier_2 : Blob;
    output_1 : Note;
    output_2 : Note;
    fee : Nat64;
    v_pub_out : Nat64;
    proof_hex : Text;
  };

  /// Every check of a spend except the proof, in the order the pools make them. Null = may verify.
  public func spendRejection(s : State, sp : Spend) : ?Text {
    if (sp.anchor.size() != 32 or sp.nullifier_1.size() != 32 or sp.nullifier_2.size() != 32) return ?"REJECT:field-length";
    switch (proofRejection(sp.proof_hex)) { case (?e) return ?e; case null {} };
    switch (shapeRejection(sp.output_1)) { case (?e) return ?e; case null {} };
    switch (shapeRejection(sp.output_2)) { case (?e) return ?e; case null {} };
    if (not isRoot(s, sp.anchor)) return ?"REJECT:unknown-anchor";
    if (PoseidonTree.blobToNat(sp.nullifier_1) == null or PoseidonTree.blobToNat(sp.nullifier_2) == null) return ?"REJECT:nullifier-noncanonical";
    if (sp.nullifier_1 == sp.nullifier_2) return ?"REJECT:duplicate-nullifier-in-tx";
    if (isSpent(s, sp.nullifier_1) or isSpent(s, sp.nullifier_2)) return ?"REJECT:nullifier-spent";
    null
  };

  public func verifySpend(k : Keys, sp : Spend, binding : Blob) : Text {
    switch (publicInputs([sp.anchor, sp.nullifier_1, sp.nullifier_2, sp.output_1.commitment, sp.output_2.commitment, nat64Field(sp.fee), nat64Field(sp.v_pub_out), binding])) {
      case (?inputs) Groth16Wire.verifyPreparedCached(k.transfer.vk, k.transfer.flat, sp.proof_hex, inputs);
      case null "REJECT:public-input-encoding";
    }
  };

  /// Commit a verified spend: nullifiers, then both outputs. No check here; the caller made them
  /// all (spendRejection, then verifySpend) in the same message with no await in between.
  public func commitSpend(s : State, sp : Spend) : Blob {
    Map.add(s.nullifiers, Blob.compare, sp.nullifier_1, ());
    Map.add(s.nullifiers, Blob.compare, sp.nullifier_2, ());
    append(s, [sp.output_1, sp.output_2])
  };

  public func notesPage(s : State, start : Nat, count : Nat) : [Note] {
    let n = List.size(s.notes);
    if (start >= n) return [];
    let len = Nat.min(Nat.min(count, 500), n - start);
    Array.tabulate<Note>(len, func(i) { List.at(s.notes, start + i) })
  };

  public func fieldOk(b : Blob) : Bool { b.size() == 32 and PoseidonTree.blobToNat(b) != null };
  public let FR_P : Nat = Fr.P;
};
