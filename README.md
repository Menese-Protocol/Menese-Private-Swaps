# Private swaps between shielded pools

Source of the private swap canister, the change it makes to the shielded pools, the price reporter, and
a build that reproduces the module hashes put to the DAO's vote.

## What it does

Each shielded pool holds one ICRC token, and balances in it are notes. A swap burns notes in one pool and
creates a note in another, with no ledger transfer and no counterparty to wait for. The other side of every
swap is a reserve owned by holders who opt in to provide it.

1. **Lock.** The holder proves ownership of notes in pool X with the pools' transfer proof (Groth16), with
   the amount as its public value. The proof binds the swap canister, a one-time owner principal and the
   terms (target pool, lowest payout, nonce), so a relay can change none of them. Pool X verifies the proof,
   burns the notes, adds the amount to its reserve record and logs the lock, in one message. The swap
   canister records the lock at its own clock.
2. **Price.** The lock is priced by the first feed round that opened after it and was finalized. A round is
   finalized when k of the n reporters named by the DAO agree within the spread limit, and its price is the
   lower median of their reports. In one message the swap canister checks the round against the Exchange
   Rate Canister, runs the leg (or two legs through ICP), and checks the lowest payout and the size, depth
   and per-minute caps. It then records the payout as owed to the owner in pool Y. If any check fails, or
   no round is finalized within the timeout, the whole amount is owed back in pool X.
3. **Collect.** The owner proves a new note for exactly the owed amount. Pool Y verifies the proof, creates
   the note and takes the amount out of its reserve record. It refuses if the record is smaller, and it
   accepts each owed record at most once.

The Exchange Rate Canister never sets a price. A finalized round too far from a fresh reading pauses the
pair, and without a fresh reading nothing on that pair is priced.

| | Public | Hidden |
|---|---|---|
| Who swapped | | Hidden (zero-knowledge proof, one-time owner principal) |
| The swap's pools, size and price | Visible | |
| Where the proceeds go next | | Hidden |
| The swapper's remaining balance | | Hidden |
| Who provides liquidity | | Hidden |
| Amounts added to or taken from a reserve, and each reserve's holdings | Visible | |

## Feed rules (compiled-in limits)

- k is at least 3 and more than n/2; no reporter appears twice; the anonymous principal is refused.
- Round length is at least 2 s (default 5 s). A report whose `observed_at` predates its round's open is
  refused, so every price in a round was observed after the round opened.
- Spread freeze: a round whose reports differ by more than the spread limit (5 to 50 bps, default 50) is
  not finalized.
- Jump breaker: a move larger than the jump limit (50 to 250 bps, default 250) from the last accepted price
  is held. It is accepted only after it has stood within the confirm band (default 50 bps) for the confirm
  gap (2 rounds to 600 s, default 30 s). A held price never prices a swap.
- Every round has a deadline, and sample times are monotonic.

## Proof checks for a caller (compiled-in limits)

`leave` and `collect_receipt` verify a Groth16 proof on the caller's behalf, which costs the swap canister
about 22.4 B cycles whether the proof holds or not. `lock` and `collect` pass a proof to a pool, whose
verification costs it about 22.4 B (a lock) or 17.1 B (a collect). Each of the four has two paths.

- Paid: a calling canister that attaches at least `verify_price` cycles per proof (25 B to 1 T, default
  30 B) is verified unconditionally. `leave` and `collect_receipt` keep the attached cycles; `lock` and
  `collect` attach all of them to their call to the pool, which keeps them (`status` counts them as
  `cycles_forwarded`).
- Free (ingress, or fewer cycles attached): the argument carries `work`, at most 32 bytes. SHA-256 over
  `"picp-swap-work/v1"`, the canister id, the epoch, a digest of every other field of the argument (the
  serialization is in `canister/src/Work.mo`) and `work` must have at least `d` leading zero bits. The
  epoch counts the failed free checks, so a solution is spent by the failure it causes. `d` starts at
  `work_d_base` (default 0), rises one bit for every `work_step` failed free checks in a window (default
  4, window 60 s), up to `work_d_max` (at most 32, default 24), and falls one bit for each window with
  none. At most `fail_budget` failed free checks are run per window (1 to 64, default 4); after that the
  free path refuses before verifying until the window turns. `status` reports `d`, the epoch and the window.
- A receipt whose free collect failed waits `backoff_s` (default 30 s), doubled for each further failure,
  at most one hour, before its next free attempt; so does an owed record whose free `collect` failed
  (`owed_of` gives its `retry_after_ns`).
- Only a verifier's verdict on the proof counts as a failure. A free check holds a place in the window's
  budget while its call to the pool is awaited, so concurrent calls cannot overrun the budget.
- `lock` takes the work as a third argument, `lock(pool, args, work)`, over `"lock"`, the pool and every
  field of `args`; `collect` takes it as a field of its argument, over `"collect"` and the other fields.

`inspect` makes the free path's checks for ingress, and the method makes them again before verifying.
Every caller-sized field is checked against its bound before it is hashed or sent on: a proof is exactly
384 hex characters, 32-byte fields are 32 bytes, an ephemeral key is at most 256 bytes and a note
ciphertext at most 1,024.

## Arguments a caller sizes

Every integer in an argument a caller supplies is fixed-width (`nat64`, `nat8`). A price is
`record { hi : nat64; lo : nat64 }`, the value `hi * 2^64 + lo`, so at most 2^128 - 1, the feed's
largest price; zero is refused. The pools' `swap_*` methods take `nat64` in the same way. Return types
keep `nat`.

## The pools' hardening release

The pool source here is the live pool source with two changes on top, each a patch in `pool/`:
`HARDENING.patch`, the hardening release the pools are upgraded to first, and `SWAP-DIFF.patch`, the swap
entry points. The hardening release changes the pools' interface; clients of the pools follow it:

- `inspect` refuses, before the pool pays for them: query methods sent as updates; methods only
  governance, the administrator or the pool itself may call, from anyone else; and any argument larger
  than its method needs (256 bytes for fixed-type methods; `shield` and `confidential_transfer` sized
  from the note shape and the proof's length, or from the unshaped bounds, 2,834 and 4,466 bytes, when
  no note shape is set).
- These methods take `nat64` where they took `nat`: `claim_envelopes`, `detect_boundary_proof`,
  `detection_stream`, `pir2_enable`, `pir2_hint_chunk`, `pir2_query`, `pir2_record_stream`,
  `pir2_reindex`, `set_note_shape`, `validate_stable_state_range`, and the fee schedule's
  `unshield_bps` (`set_protocol_fee`, `dao_set_protocol_fee`, `validate_dao_set_protocol_fee`).
  `icrc3_get_blocks` keeps the ICRC-3 standard's `nat`; a canister calling it with a large `nat` costs
  the pool at most the instruction limit of a query run as an update (10.0 B cycles).
- `shield` and `confidential_transfer` have the two paths above (`pool/src/ProofGate.mo`): a calling
  canister attaching `verify_price` is verified unconditionally and the pool keeps the cycles; any other
  call may carry `work : opt blob`, SHA-256 over the pool's domain tag, the pool's id, the epoch and a
  digest of the argument (the serialization is in `ProofGate.mo`). With `work_d_base` 0 a client that
  sends no `work` passes until failures raise the difficulty. `forged_proof_guard_status` reports the
  gate; `set_proof_guard` (administrator) and `dao_set_proof_guard` (governance) set it within the same
  hard limits. The earlier cool-down and its methods are removed.

## Settings

Every setting changes only through `dao_*` methods, which refuse every caller except the SNS governance
canister named at install. Each setting's validator enforces the hard limits above. The canister installs
paused and prices nothing until a DAO proposal opens it.

## Layout

| Path | Contents |
|---|---|
| `canister/src/` | The swap canister (`Swap.mo`) and its modules: feed, pricing, books, receipts, terms, settings, the interface's fixed-width types (`Wire.mo`), the free path's work and budget (`Work.mo`) |
| `canister/test/` | `FeedTest.mo`, `BooksTest.mo` and `WorkTest.mo` (run with `moc -r`), and mutant runners that remove one guard at a time |
| `pool/src/`, `pool/icp-overrides/` | The shielded pool source with the swap entry points (ckBTC tree; the ICP tree replaces the three files in `icp-overrides/`) |
| `pool/HARDENING.patch` | The pools' hardening release, against the source of the modules the pools run today |
| `pool/SWAP-DIFF.patch` | The swap entry points, against the hardening release |
| `pool/test/` | `ProofGateTest.mo` (run with `moc -r`) and its mutant runner |
| `pool/UPSTREAM.txt` | The live pool modules that source rebuilds to |
| `reporter/` | The price reporter (Rust) and its hosting requirements (`HOSTING.md`) |
| `vendor/` | The Motoko packages the build uses: `core` 1.0.0 and `sha2` 0.1.9, with their licenses |
| `swap.did` | The swap canister's interface, as the build emits it |
| `build.sh` | The build |
| `verify-build.sh`, `MODULE-HASHES.txt` | Verification of the build against the recorded hashes |

## Build

Requirements: `moc` 1.4.1 (as `MOC=<path>` or on `PATH`), `gzip`, `sha256sum`, `patch` and `tar`.

```sh
SWAP_CANISTER_ID=<the swap canister's principal> ./build.sh [out-dir]
./build.sh --hardening [out-dir]       # with HARDENING_SRC=<pool src/ with SWAP-DIFF.patch reversed>
./build.sh --upstream [out-dir]        # with UPSTREAM_SRC=<that, with HARDENING.patch reversed as well>
```

The pool modules name the swap canister in their code (`src/SwapConfig.mo`, generated by the build), so
their hashes depend on the swap canister id. The swap module does not. Every module is compiled from a
staging directory with relative paths, so the output does not depend on where the tree is checked out.

## Verify

```sh
./verify-build.sh             # two copies of the tree at two different paths, each built and compared
./verify-build.sh --control   # the same, with one string literal changed in each module of the second copy
```

`verify-build.sh` makes two copies of the tree at two different paths and builds each one. In each copy it
checks that:
- the swap module, its gzip and `swap.did` equal `MODULE-HASHES.txt`;
- with `SWAP-DIFF.patch` reversed, the pool source rebuilds to the hardening release's modules on the
  record (the modules of the hardening upgrade);
- with `HARDENING.patch` reversed as well, it rebuilds to the module hashes the two live pools report
  (`dfx canister --network ic info <pool id>`);
- the pool modules for the given swap canister id are the same in both copies, and equal the record when it
  has a line for that id.

It exits non-zero on any difference. Neither `build.sh` nor `verify-build.sh` writes `MODULE-HASHES.txt`.

`--control` expects to fail. It changes one string literal in `canister/src/Swap.mo` and one in
`pool/src/Main.mo` of the second copy, so it shows that the comparison detects a change to compiled code.

## Tests in this tree

```sh
MOC=<moc 1.4.1>
$MOC -r --package core vendor/core@1.0.0/src canister/test/FeedTest.mo     # 219 checks
$MOC -r --package core vendor/core@1.0.0/src canister/test/BooksTest.mo    # random operations against an independent model
python3 canister/test/feed_mutants.py      # each feed guard removed in turn; FeedTest must fail on every one
python3 canister/test/books_mutants.py     # the same for pricing and books
$MOC -r --package core vendor/core@1.0.0/src --package sha2 vendor/sha2@0.1.9/src canister/test/WorkTest.mo   # digests and work against hashlib vectors; window, budget, backoff
python3 canister/test/work_mutants.py      # each rule of Work.mo removed in turn; WorkTest must fail on every one
$MOC -r --package core vendor/core@1.0.0/src --package sha2 vendor/sha2@0.1.9/src pool/test/ProofGateTest.mo   # the pools' proof gate against hashlib vectors
python3 pool/test/proofgate_mutants.py     # each rule of ProofGate.mo removed in turn; ProofGateTest must fail on every one
(cd reporter && cargo test)                # the reporter's median, disagreement and quote-currency rules
```

The end-to-end suite runs these modules on PocketIC: lock, settle, collect, join and leave with real
proofs, faulty and colluding reporters, pool upgrades from the live modules, and the DAO proposals in order
on the SNS governance and root modules. It depends on components that are not part of this tree, and it
is not included.

## Status

- The swap canister is not installed. Its id is assigned when the DAO registers it, and the pool module
  hashes for that id are added to `MODULE-HASHES.txt` once it exists.
- Reporter operators, k and n, and the pairs' depth and caps are set by DAO proposals. They are not fixed
  in this tree.

## License

MIT (`LICENSE`). The packages under `vendor/` carry their own licenses.
