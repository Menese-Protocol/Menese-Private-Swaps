#!/usr/bin/env python3
"""Teeth for Work.mo: each mutant removes or weakens one rule in a copy of the canister sources, and
WorkTest must fail on it. A mutant WorkTest survives is a rule without a test.
Run from swap/: python3 canister/test/work_mutants.py"""
import os, shutil, subprocess, sys, tempfile

MOC = os.environ.get("MOC", "moc")
here = os.path.dirname(os.path.abspath(__file__))
swap = os.path.dirname(os.path.dirname(here))

M = [
    ("length prefix", "func field(d : Sha256.Digest, b : Blob) { u32be(d, b.size()); d.writeBlob(b) };", "func field(d : Sha256.Digest, b : Blob) { d.writeBlob(b) };"),
    ("owner not bound", "    field(d, Principal.toBlob(owner));\n", ""),
    ("nullifier not bound", "    field(d, s.nullifier_2);\n", ""),
    ("value not bound", "    u64be(d, s.v_pub_out);\n", ""),
    ("receipt id not bound", "    u64be(d, receipt_id);\n", ""),
    ("note count not bound", "    u32be(d, notes.size());\n", ""),
    ("canister not bound", "    field(d, Principal.toBlob(self));\n", ""),
    ("epoch not bound", "    u64be(d, Nat64.fromNat(epoch));\n", ""),
    ("epoch never advances", "    g.epoch += 1;\n", ""),
    ("work size bound", "    if (work.size() > MAX_WORK_BYTES) return false;\n", ""),
    ("difficulty ignored", "d == 0 or leadingZeroBits(workHash(self, epoch, argDigest, work)) >= d", "true"),
    ("zero bits miscounted", "while (y < 0x80) { n += 1; y <<= 1 };", "while (y < 0x40) { n += 1; y <<= 1 };"),
    ("difficulty never rises", "    if (g.failures % c.step == 0) g.d := Nat.min(clamp(g.d, c) + 1, c.d_max);\n", ""),
    ("failures not counted against the budget", "spent = g.failures + g.inflight >= c.budget", "spent = g.inflight >= c.budget"),
    ("in-flight attempts not counted", "spent = g.failures + g.inflight >= c.budget", "spent = g.failures >= c.budget"),
    ("in-flight attempts forgotten when the window turns", "spent = g.inflight >= c.budget", "spent = false"),
    ("hold does nothing", "public func hold(g : Gate) { g.inflight += 1 };", "public func hold(g : Gate) { ignore g };"),
    ("release does nothing", "public func release(g : Gate) { if (g.inflight > 0) g.inflight -= 1 };", "public func release(g : Gate) { ignore g };"),
    ("any refusal counted as a verdict", "    for (v in VERIFIER_VERDICTS.vals()) { if (v == t) return true };\n    false\n", "    ignore t;\n    true\n"),
    ("a verdict not counted", "\"REJECT:pairing-check\", ", ""),
    ("lock: pool not bound", "    field(d, Principal.toBlob(pool));\n", ""),
    ("lock: owner not bound", "    field(d, Principal.toBlob(a.owner));\n", ""),
    ("lock: terms not bound", "    field(d, a.terms);\n", ""),
    ("lock: fee not bound", "    u64be(d, a.fee);\n", ""),
    ("collect: record not bound", "    u64be(d, a.owed_id);\n", ""),
    ("collect: ciphertext not bound", "    field(d, a.note_ciphertext);\n    field(d, Text.encodeUtf8(a.proof_hex));\n    d.sum()", "    field(d, Text.encodeUtf8(a.proof_hex));\n    d.sum()"),
    ("difficulty never falls", "let quiet = if (g.failures == 0) elapsed else elapsed - 1;", "let quiet = 0;"),
    ("falls even after failures", "let quiet = if (g.failures == 0) elapsed else elapsed - 1;", "let quiet = elapsed;"),
    ("no clamp", "func clamp(d : Nat, c : Config) : Nat = Nat.min(Nat.max(d, c.d_base), c.d_max);", "func clamp(d : Nat, c : Config) : Nat = d;"),
    ("window never turns", "    if (now < g.window_start_ns + c.window_ns) {", "    if (true) {"),
    ("backoff never doubles", "ns *= 2;", "ns *= 1;"),
    ("backoff uncapped", "Nat64.fromNat(Nat.min(ns, Nat64.toNat(MAX_BACKOFF_NS)))", "Nat64.fromNat(ns)"),
]

def run(src_dir):
    r = subprocess.run([MOC, "-r", "--package", "core", os.path.join(swap, "vendor/core@1.0.0/src"),
                        "--package", "sha2", os.path.join(swap, "vendor/sha2@0.1.9/src"),
                        os.path.join(src_dir, "test/WorkTest.mo")], capture_output=True, text=True)
    out = r.stdout + r.stderr
    return "checks PASS" in out and r.returncode == 0, out

ok, out = run(os.path.join(swap, "canister"))
if not ok:
    print("WorkTest fails on the unmutated source:\n" + out); sys.exit(1)
survivors = []
for name, old, new in M:
    tmp = tempfile.mkdtemp()
    try:
        shutil.copytree(os.path.join(swap, "canister/src"), os.path.join(tmp, "src"))
        shutil.copytree(os.path.join(swap, "canister/test"), os.path.join(tmp, "test"))
        p = os.path.join(tmp, "src/Work.mo")
        s = open(p).read()
        n = s.count(old)
        if n != 1:
            print(f"MUTANT {name}: pattern found {n} times"); sys.exit(2)
        open(p, "w").write(s.replace(old, new))
        passed, out = run(tmp)
        fail = [l for l in out.splitlines() if "FAIL" in l or "error" in l.lower()]
        print(f"{'SURVIVED' if passed else 'killed  '}  {name}: {fail[0].strip()[:110] if fail else ''}")
        if passed:
            survivors.append(name)
    finally:
        shutil.rmtree(tmp)
print(f"{len(M) - len(survivors)}/{len(M)} mutants killed")
sys.exit(1 if survivors else 0)
