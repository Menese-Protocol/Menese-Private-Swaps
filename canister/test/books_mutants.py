#!/usr/bin/env python3
"""Teeth for the books: each mutant breaks one rounding, guard or transition in a copy of the
canister sources, and BooksTest must fail on it. A mutant BooksTest survives is a rule without a test.
Run from swap/: python3 canister/test/books_mutants.py"""
import os, shutil, subprocess, sys, tempfile

MOC = os.environ.get("MOC", "moc")
here = os.path.dirname(os.path.abspath(__file__))
swap = os.path.dirname(os.path.dirname(here))

M = [
    ("Pricing.mo", "fee rounded down", "ceilDiv(gross * fee_bps, BPS)", "gross * fee_bps / BPS"),
    ("Pricing.mo", "protocol part rounded up", "let protocol = fee * protocol_share_bps / BPS;", "let protocol = ceilDiv(fee * protocol_share_bps, BPS);"),
    ("Pricing.mo", "shares rounded up", "(net * total_shares / reserve_value, 0, fee)", "(ceilDiv(net * total_shares, reserve_value), 0, fee)"),
    ("Pricing.mo", "leave part rounded up", "if (total_shares == 0) 0 else holdings * shares / total_shares", "if (total_shares == 0) 0 else ceilDiv(holdings * shares, total_shares)"),
    ("Pricing.mo", "no locked first shares", "public let LOCKED_SHARES : Nat = 1_000;", "public let LOCKED_SHARES : Nat = 0;"),
    ("Pricing.mo", "join fee kept by the joiner", "if (fee >= value) return (0, 0, fee);\n    let net = value - fee;", "if (fee >= value) return (0, 0, fee);\n    let net = value;"),
    ("Pricing.mo", "asset to ICP rounded up", "public func assetToIcp(amount : Nat, price : Nat) : Nat { amount * price / SCALE };", "public func assetToIcp(amount : Nat, price : Nat) : Nat { ceilDiv(amount * price, SCALE) };"),
    ("Books.mo", "refund owes nothing", "    a.pending -= amount;\n    a.owed += amount;\n  };", "    a.pending -= amount;\n  };"),
    ("Books.mo", "lowest payout ignored", 'if (out < minOut) return #refund("below-lowest-payout");', ""),
    ("Books.mo", "zero payout filled", 'if (out == 0) return #refund("payout-zero");', ""),
    ("Books.mo", "ICP fee drawn without ICP", 'if (icpHeld < icpProtocol) return #refund("reserve-short");', ""),
    ("Books.mo", "size cap without the protocol part", "if (payOut * 10_000 > payHeld", "if (out * 10_000 > payHeld"),
    ("Books.mo", "no ICP depth", 'if (icpHeld < pv.settings.min_depth_icp) return #refund("pair-too-shallow");', ""),
    ("Books.mo", "minute cap ignores this swap", "if (used + l.volume > pv.settings.minute_cap_icp)", "if (used > pv.settings.minute_cap_icp)"),
    ("Books.mo", "sell fee not booked", "      icp.held -= f.out + f.icp_protocol;\n      icp.fees += f.icp_protocol;\n      icp.owed += f.out;", "      icp.held -= f.out + f.icp_protocol;\n      icp.owed += f.out;"),
    ("Books.mo", "two-leg ICP fee not drawn", "      icp.held -= f.icp_protocol;\n      icp.fees += f.icp_protocol;\n      dst.held", "      icp.fees += f.icp_protocol;\n      dst.held"),
    ("Books.mo", "minute never resets (swaps)", "    let minute = now / MINUTE_NS;\n    for (l in f.legs.vals()) {\n      let ab = asset(s, l.pair);\n      if (ab.minute != minute) { ab.minute := minute; ab.minute_volume := 0 };", "    let minute = now / MINUTE_NS;\n    for (l in f.legs.vals()) {\n      let ab = asset(s, l.pair);\n      if (ab.minute != minute) { ab.minute := minute };"),
    ("Books.mo", "fewest shares ignored", 'if (shares < minShares) return #refund("below-fewest-shares");', ""),
    ("Books.mo", "pair cap ignores the join", "asset(s, i).held + amount, price) > cap", "asset(s, i).held, price) > cap"),
    ("Books.mo", "leave owes nothing", "      a.held -= part;\n      a.owed += part;", "      a.held -= part;"),
    ("Books.mo", "DAO sale ICP not due", "    icp.fees += f.icp_protocol;\n    icp.dao_due += f.out;", "    icp.fees += f.icp_protocol;\n    icp.owed += f.out;"),
    ("Books.mo", "sweep not recorded", "a.sweeping -= amount; a.swept += amount };", "a.sweeping -= amount };"),
    ("Books.mo", "payout not recorded", "a.paying -= amount; a.paid += amount };", "a.paying -= amount };"),
    ("Books.mo", "DAO leave keeps its shares", "    s.shares.dao -= shares;\n    s.shares.total -= shares;", "    s.shares.dao -= shares;"),
    ("Books.mo", "absorb lost", "    a.pending -= amount;\n    a.held += amount;\n  };\n\n  // ----", "    a.pending -= amount;\n  };\n\n  // ----"),
]

def run(src_dir):
    r = subprocess.run([MOC, "-r", "--package", "core", os.path.join(swap, "vendor/core@1.0.0/src"),
                        os.path.join(src_dir, "test/BooksTest.mo")], capture_output=True, text=True)
    out = r.stdout + r.stderr
    return "checks PASS" in out and r.returncode == 0, out

ok, out = run(os.path.join(swap, "canister"))
if not ok:
    print("BooksTest fails on the unmutated source:\n" + out[-2000:]); sys.exit(1)
survivors = []
for f, name, old, new in M:
    tmp = tempfile.mkdtemp()
    try:
        shutil.copytree(os.path.join(swap, "canister/src"), os.path.join(tmp, "src"))
        shutil.copytree(os.path.join(swap, "canister/test"), os.path.join(tmp, "test"))
        p = os.path.join(tmp, "src", f)
        s = open(p).read()
        n = s.count(old)
        if n != 1:
            print(f"MUTANT {name}: pattern found {n} times"); sys.exit(2)
        open(p, "w").write(s.replace(old, new))
        passed, out = run(tmp)
        fail = [l for l in out.splitlines() if "FAIL" in l or "error" in l.lower()]
        print(f"{'SURVIVED' if passed else 'killed  '}  {name}: {fail[0].strip()[:120] if fail else ''}", flush=True)
        if passed:
            survivors.append(name)
    finally:
        shutil.rmtree(tmp)
print(f"{len(M) - len(survivors)}/{len(M)} mutants killed")
sys.exit(1 if survivors else 0)
