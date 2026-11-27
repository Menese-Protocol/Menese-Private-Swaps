/// The private pools' interface, as the upgraded pool module (../../pool/src/Main.mo) serves it.
module {
  public type Result<T> = { #ok : T; #err : Text };
  public type OutputRecord = { commitment : Blob; ephemeral_key : Blob; note_ciphertext : Blob };
  public type SwapLockArgs = {
    anchor : Blob;
    nullifier_1 : Blob;
    nullifier_2 : Blob;
    output_1 : OutputRecord;
    output_2 : OutputRecord;
    fee : Nat64;
    v_pub_out : Nat64;
    proof_hex : Text;
    owner : Principal;
    terms : Blob;
  };
  public type SwapLock = { lock_id : Nat64; owner : Principal; terms : Blob; amount : Nat64; fee : Nat64; time : Int };
  public type SwapCollectArgs = {
    owed_id : Nat64;
    amount : Nat64;
    commitment : Blob;
    ephemeral_key : Blob;
    note_ciphertext : Blob;
    proof_hex : Text;
  };
  public type SwapStatus = {
    enabled : Bool;
    swap_canister : Principal;
    reserve : Nat;
    locked_total : Nat;
    collected_total : Nat;
    swept_total : Nat;
    credited_total : Nat;
    paid_total : Nat;
    lock_count : Nat;
    collect_count : Nat;
    sweep_count : Nat;
    payout_pending : Bool;
  };
  public type SwapPayoutState = { #done; #pending; #none };
  public type VkAnchor = {
    transfer_vk_hex : Text;
    deposit_vk_hex : Text;
    digest : Blob;
    epoch : Nat64;
    certified : Bool;
    frozen : Bool;
  };
  public type Pool = actor {
    swap_lock : SwapLockArgs -> async Result<SwapLock>;
    swap_collect : SwapCollectArgs -> async Result<Nat>;
    swap_fee_sweep : (Nat64, Nat64) -> async Result<Nat>;
    swap_reserve_credit : Nat64 -> async Result<Nat>;
    swap_reserve_payout : (Nat64, Nat64) -> async Result<Nat>;
    swap_payout_state : shared query (Nat64, Nat64) -> async SwapPayoutState;
    swap_status : shared query () -> async SwapStatus;
    swap_locks_page : shared query (Nat64, Nat64) -> async [SwapLock];
    swap_collected_amount : shared query Nat64 -> async ?Nat;
    swap_swept_amount : shared query Nat64 -> async ?Nat;
    swap_credited_amount : shared query Nat64 -> async ?Nat;
    verifying_key_anchor : shared query () -> async VkAnchor;
    resume_prepaid : () -> async Result<Nat>;
  };
  /// The management canister's `canister_info`: who controls a canister (any canister may ask).
  public type Management = actor {
    canister_info : shared { canister_id : Principal; num_requested_changes : ?Nat64 } -> async { controllers : [Principal] };
  };
  /// SNS root's `list_sns_canisters`, as far as a pair's check reads it.
  public type SnsRoot = actor {
    list_sns_canisters : shared {} -> async { root : ?Principal; governance : ?Principal; ledger : ?Principal; dapps : [Principal] };
  };

  /// The composite-query view the books cross-check reads.
  public type PoolQuery = actor {
    swap_status : shared query () -> async SwapStatus;
  };
};
