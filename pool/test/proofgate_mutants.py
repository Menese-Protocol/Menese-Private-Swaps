#!/usr/bin/env python3
"""Teeth for ProofGate.mo: each mutant removes or weakens one rule in a copy of the pool sources, and
ProofGateTest must fail on it. A mutant ProofGateTest survives is a rule without a test.
Run from swap/: python3 pool/test/proofgate_mutants.py"""
import os, shutil, subprocess, sys, tempfile

MOC = os.environ.get("MOC", "moc")
here = os.path.dirname(os.path.abspath(__file__))
swap = os.path.dirname(os.path.dirname(here))

M = [
    ("length prefix", "public func field(d : Sha256.Digest, b : Blob) { u32be(d, b.size()); d.writeBlob(b) };", "public func field(d : Sha256.Digest, b : Blob) { d.writeBlob(b) };"),
    ("null subaccount same as present", "switch (b) { case (?v) { u8(d, 1); field(d, v) }; case null u8(d, 0) };", "switch (b) { case (?v) { field(d, v) }; case null {} };"),
    ("null time same as present", "switch (x) { case (?v) { u8(d, 1); u64be(d, v) }; case null u8(d, 0) };", "switch (x) { case (?v) { u64be(d, v) }; case null {} };"),
    ("shield value not bound", "    u64be(d, a.value);\n", ""),
    ("shield nonce not bound", "    field(d, a.client_nonce);\n", ""),
    ("shield tag not bound", "    text(d, \"shield\");\n", ""),
    ("transfer nullifier not bound", "    field(d, a.nullifier_2);\n", ""),
    ("transfer output not bound", "    output(d, a.output_2);\n", ""),
    ("transfer value not bound", "    u64be(d, a.v_pub_out);\n", ""),
    ("recipient owner not bound", "case (?r) { u8(d, 1); field(d, Principal.toBlob(r.owner)); optField(d, r.subaccount) };", "case (?r) { u8(d, 1); optField(d, r.subaccount) };"),
    ("envelope not bound", "    optField(d, a.claim_envelope);\n", ""),
    ("domain not bound", "    text(d, domain);\n", ""),
    ("canister not bound", "    field(d, Principal.toBlob(self));\n", ""),
    ("epoch not bound", "    u64be(d, Nat64.fromNat(epoch));\n", ""),
    ("epoch never advances", "    g.epoch += 1;\n", ""),
    ("work size bound", "    if (work.size() > MAX_WORK_BYTES) return false;\n", ""),
    ("difficulty ignored", "d == 0 or leadingZeroBits(workHash(domain, self, epoch, argDigest, work)) >= d", "true"),
    ("zero bits miscounted", "while (y < 0x80) { n += 1; y <<= 1 };", "while (y < 0x40) { n += 1; y <<= 1 };"),
    ("difficulty never rises", "    if (g.failures % c.step == 0) g.d := Nat.min(clamp(g.d, c) + 1, c.d_max);\n", ""),
    ("budget never spent", "spent = g.failures >= c.budget", "spent = false"),
    ("difficulty never falls", "let quiet = if (g.failures == 0) elapsed else elapsed - 1;", "let quiet = 0;"),
    ("falls even after failures", "let quiet = if (g.failures == 0) elapsed else elapsed - 1;", "let quiet = elapsed;"),
    ("no clamp", "func clamp(d : Nat, c : Config) : Nat = Nat.min(Nat.max(d, c.d_base), c.d_max);", "func clamp(d : Nat, c : Config) : Nat = d;"),
    ("window never turns", "    if (now < g.window_start_ns + c.window_ns) {", "    if (true) {"),
    ("backoff never doubles", "ns *= 2;", "ns *= 1;"),
    ("backoff uncapped", "Nat64.fromNat(Nat.min(ns, Nat64.toNat(MAX_BACKOFF_NS)))", "Nat64.fromNat(ns)"),
]

def run(pool_dir):
    r = subprocess.run([MOC, "-r", "--package", "core", os.path.join(swap, "vendor/core@1.0.0/src"),
                        "--package", "sha2", os.path.join(swap, "vendor/sha2@0.1.9/src"),
                        os.path.join(pool_dir, "test/ProofGateTest.mo")], capture_output=True, text=True)
    out = r.stdout + r.stderr
    return "checks PASS" in out and r.returncode == 0, out

ok, out = run(os.path.join(swap, "pool"))
if not ok:
    print("ProofGateTest fails on the unmutated source:\n" + out); sys.exit(1)
survivors = []
for name, old, new in M:
    tmp = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(tmp, "src"))
        shutil.copy(os.path.join(swap, "pool/src/ProofGate.mo"), os.path.join(tmp, "src/ProofGate.mo"))
        shutil.copytree(os.path.join(swap, "pool/test"), os.path.join(tmp, "test"))
        p = os.path.join(tmp, "src/ProofGate.mo")
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
