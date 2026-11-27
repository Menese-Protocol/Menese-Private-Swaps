#!/usr/bin/env bash
# Verifies the build against MODULE-HASHES.txt. Two copies of this tree, at two different paths, are each
# built with build.sh; in each copy:
#   - the swap module, its gzip and swap.did must equal the record;
#   - the pool source with pool/SWAP-DIFF.patch reversed must rebuild to the hardening release's module
#     hashes recorded (the modules of proposals H1 and H2);
#   - that source with pool/HARDENING.patch reversed as well must rebuild to the live pool module hashes
#     recorded (the hashes `dfx canister --network ic info <pool id>` reports);
#   - the pool modules for SWAP_CANISTER_ID must be identical in both copies, and equal the record when it
#     has a line for that id.
# Neither this script nor build.sh writes MODULE-HASHES.txt.
#
#   ./verify-build.sh              exit 0 only if every comparison holds
#   ./verify-build.sh --control    one string literal changed in Swap.mo and in the pool's Main.mo of the
#                                  second copy; exit 0 only if every comparison of that copy fails and the
#                                  first copy still passes
#
# SWAP_CANISTER_ID defaults to 37pka-5h777-77777-7777q-cai, a synthetic id (bytes FF FF FF FF FF FF FF FF
# 01 01, the last id of the whole range, which no subnet is assigned) used only to check that the pool build
# is deterministic.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
record="$here/MODULE-HASHES.txt"
control=0
if [[ "${1:-}" == "--control" ]]; then control=1; shift; fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--control]"; exit 2; }
id="${SWAP_CANISTER_ID:-37pka-5h777-77777-7777q-cai}"
for t in gzip sha256sum patch tar; do command -v "$t" >/dev/null || { echo "$t is required"; exit 2; }; done
[[ -f "$record" ]] || { echo "missing $record"; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
copies=("$work/a" "$work/second/copy/at/a/longer/path")

copy() {
  mkdir -p "$1"
  ( cd "$here" && tar --exclude=./out --exclude=./.git --exclude=./reporter/target -cf - . ) | ( cd "$1" && tar -xf - )
}

tamper() { # tamper <file> <literal> <replacement>: the literal must occur exactly once
  local n; n="$(grep -c -F -- "$2" "$1" || true)"
  [[ "$n" == 1 ]] || { echo "control: $2 occurs $n times in $1 (expected 1)"; exit 2; }
  sed -i "s/$2/$3/" "$1"
}

build() { # build <copy>: out/ (swap and pools for $id), out-hardening/ (pools with the swap diff reversed)
  # and out-upstream/ (pools with both patches reversed)
  local d="$1"
  SWAP_CANISTER_ID="$id" "$d/build.sh" "$d/out" >/dev/null
  mkdir -p "$d/hardening" "$d/upstream"
  cp -r "$d/pool" "$d/hardening/pool"
  ( cd "$d/hardening" && patch -s -R -p1 < "$d/pool/SWAP-DIFF.patch" )
  HARDENING_SRC="$d/hardening/pool/src" "$d/build.sh" --hardening "$d/out-hardening" >/dev/null
  cp -r "$d/hardening/pool" "$d/upstream/pool"
  ( cd "$d/upstream" && patch -s -R -p1 < "$d/pool/HARDENING.patch" )
  UPSTREAM_SRC="$d/upstream/pool/src" "$d/build.sh" --upstream "$d/out-upstream" >/dev/null
  cp "$d/out-hardening/"hardening-*.wasm "$d/out-hardening/"hardening-*.wasm.gz "$d/out/"
  cp "$d/out-upstream/"upstream-*.wasm "$d/out-upstream/"upstream-*.wasm.gz "$d/out/"
}

recorded() { # recorded <file> [id]: the hash on the record for that file, or empty
  awk -v f="$1" -v want="${2:-}" '
    /^#/ || NF < 2 { next }
    $2 == f && ((want == "" && NF == 2) || (want != "" && $3 == "swap=" want)) { print $1 }' "$record"
}

check() { # check <copy> <label>: prints one line per comparison, returns the number that failed
  local d="$1" label="$2" bad=0 f want got
  for f in swap.wasm swap.wasm.gz swap.did hardening-ckbtc.wasm hardening-icp.wasm hardening-ckbtc.wasm.gz hardening-icp.wasm.gz \
    upstream-ckbtc.wasm upstream-icp.wasm; do
    want="$(recorded "$f")"
    [[ -n "$want" ]] || { echo "  $label $f: no line in the record"; bad=$((bad + 1)); continue; }
    got="$(sha256sum "$d/out/$f" | cut -d' ' -f1)"
    if [[ "$got" == "$want" ]]; then echo "  $label $f: $got matches"; else echo "  $label $f: $got DIFFERS (record $want)"; bad=$((bad + 1)); fi
  done
  if ! cmp -s "$d/out/swap.did" "$d/swap.did"; then echo "  $label swap.did: build output differs from the shipped swap.did"; bad=$((bad + 1)); fi
  for f in pool-ckbtc.wasm pool-icp.wasm pool-ckbtc.wasm.gz pool-icp.wasm.gz; do
    want="$(recorded "$f" "$id")"
    got="$(sha256sum "$d/out/$f" | cut -d' ' -f1)"
    if [[ -z "$want" ]]; then
      echo "  $label $f for $id: $got (no line in the record for this id)"
    elif [[ "$got" == "$want" ]]; then echo "  $label $f for $id: $got matches"
    else echo "  $label $f for $id: $got DIFFERS (record $want)"; bad=$((bad + 1)); fi
  done
  return "$bad"
}

copy "${copies[0]}"
copy "${copies[1]}"
if [[ "$control" == 1 ]]; then
  tamper "${copies[1]}/canister/src/Swap.mo" '"REJECT:below-smallest-swap"' '"REJECT:below-smallest-swaq"'
  tamper "${copies[1]}/pool/src/Main.mo" '"REJECT:claim-envelope-length"' '"REJECT:claim-envelope-lengti"'
fi
for d in "${copies[@]}"; do build "$d"; done

echo "copy 1: ${copies[0]#$work/}"
bad1=0; check "${copies[0]}" "copy 1" || bad1=$?
echo "copy 2: ${copies[1]#$work/}"
bad2=0; check "${copies[1]}" "copy 2" || bad2=$?

pools_differ=0
for f in pool-ckbtc.wasm pool-icp.wasm; do
  cmp -s "${copies[0]}/out/$f" "${copies[1]}/out/$f" || { echo "  $f for $id differs between the two copies"; pools_differ=$((pools_differ + 1)); }
done

if [[ "$control" == 0 ]]; then
  if [[ "$bad1" == 0 && "$bad2" == 0 && "$pools_differ" == 0 ]]; then
    echo "VERIFIED: both copies reproduce the record, and the pool modules for $id agree"
    exit 0
  fi
  echo "NOT VERIFIED: $bad1 failed in copy 1, $bad2 in copy 2, $pools_differ pool modules differ between copies"
  exit 1
fi
# control: copy 1 must pass; in copy 2, swap.wasm, swap.wasm.gz, the four hardening files and both upstream
# modules must differ, and both pool modules must differ from copy 1's (swap.did is unchanged by a literal
# inside a method body).
if [[ "$bad1" == 0 && "$bad2" -ge 8 && "$pools_differ" == 2 ]]; then
  echo "CONTROL PASSED: the copy with changed literals was refused ($bad2 record mismatches, both pool modules differ); the unchanged copy matched"
  exit 0
fi
echo "CONTROL FAILED: copy 1 had $bad1 mismatches, copy 2 had $bad2 (expected at least 8), $pools_differ pool modules differed (expected 2)"
exit 1
