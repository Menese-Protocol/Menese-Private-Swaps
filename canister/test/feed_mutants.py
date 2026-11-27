#!/usr/bin/env python3
"""Teeth for every Feed guard: each mutant removes or weakens one rule in a copy of the canister
sources, and FeedTest must fail on it. A mutant FeedTest survives is a guard without a test.
Run from swap/: python3 canister/test/feed_mutants.py"""
import os, shutil, subprocess, sys, tempfile

MOC = os.environ.get("MOC", "moc")
here = os.path.dirname(os.path.abspath(__file__))
swap = os.path.dirname(os.path.dirname(here))

M = [
    ("k floor", 'if (s.k < MIN_K) return ?"REJECT:feed-k-below-3";', ''),
    ("k floor constant", 'public let MIN_K : Nat = 3;', 'public let MIN_K : Nat = 2;'),
    ("k majority", 'if (2 * s.k <= n) return ?"REJECT:feed-k-not-majority";', ''),
    ("k above n", 'if (s.k > n) return ?"REJECT:feed-k-above-n";', ''),
    ("duplicate reporter in set", 'if (Principal.equal(s.reporters[i], s.reporters[j])) return ?"REJECT:feed-duplicate-reporter";', ''),
    ("anonymous reporter", 'if (Principal.isAnonymous(s.reporters[i])) return ?"REJECT:feed-anonymous-reporter";', ''),
    ("round floor", 'if (s.round_ns < 2_000_000_000 or', 'if (s.round_ns < 1_000_000_000 or'),
    ("spread cap", 's.spread_bps > MAX_SPREAD_BPS', 's.spread_bps > 10_000'),
    ("jump cap", 's.jump_bps > MAX_JUMP_BPS', 's.jump_bps > 10_000'),
    ("deadline within round", 's.deadline_ns > s.round_ns', 's.deadline_ns > 10 * s.round_ns'),
    ("not a reporter", 'if (not isReporter(s, reporter)) return #refused("REJECT:not-a-reporter");', ''),
    ("closed round", 'if (round_open < open) return #refused("REJECT:round-closed");', ''),
    ("future round", 'if (round_open > open) return #refused("REJECT:round-future");', ''),
    ("round rewinds", 'case (?a) { if (open < a.open_ns) return #refused("REJECT:round-rewinds") };', 'case (?_) {};'),
    ("deadline", 'if (f.cur_status == #open) return #refused("REJECT:round-deadline");', ''),
    ("late after finalize", 'if (f.cur_status != #open) {\n      f.late_count += 1;\n      return #late;\n    };', ''),
    ("duplicate report", 'if (Principal.equal(r.reporter, reporter)) return #refused("REJECT:duplicate-report");', ''),
    ("observed before round", 'if (observed_at < open) return #refused("REJECT:observed-before-round");', ''),
    ("observed in future", 'if (observed_at > now) return #refused("REJECT:observed-in-future");', ''),
    ("stale report", 'if (now - observed_at > s.max_report_age_ns) return #refused("REJECT:report-stale");', ''),
    ("report sample rewinds", 'case (?a) { if (observed_at < a.sample_ns) return #refused("REJECT:sample-time-rewinds") };', 'case (?_) {};'),
    ("spread freeze", 'if (not within(p, median, s.spread_bps)) {', 'if (false and not within(p, median, s.spread_bps)) {'),
    ("quorum", 'if (prices.size() < s.k) return #accepted_report;', 'if (prices.size() < 2) return #accepted_report;'),
    ("lower median -> upper", 'sorted[(sorted.size() - 1) / 2]', 'sorted[sorted.size() / 2]'),
    ("jump breaker", 'if (within(c.price, lastPrice, s.jump_bps)) return true;\n        f.hold', 'return true;\n        f.hold'),
    ("confirm gap", 'if (c.sample_ns >= h.since_ns + s.jump_gap_ns) {', 'if (true) {'),
    ("confirm gap on open times", 'if (c.sample_ns >= h.since_ns + s.jump_gap_ns) {', 'if (c.open_ns >= h.since_ns + s.jump_gap_ns) {'),
    ("held price follows the agreeing rounds", 'f.hold := ?{ h with price = c.price }; // the chain goes on', '// the chain goes on'),
    ("a break keeps the clock", 'f.hold := ?{ price = c.price; since_ns = c.sample_ns }; // the chain broke', 'f.hold := ?{ price = c.price; since_ns = h.since_ns }; // the chain broke'),
    ("confirm band", 'if (within(c.price, h.price, s.confirm_bps)) {', 'if (true) {'),
    ("next round after lock", 'if (a.open_ns > lock_ns) {', 'if (a.open_ns >= lock_ns) {'),
    ("finalized by deadline", 'return if (a.finalized_ns <= deadline_ns) #round(a) else #never;', 'return #round(a);'),
    ("evicted window", 'if (f.evicted_through > lock_ns) return #never;', ''),
    ("no round past deadline", 'if (now > deadline_ns) #never else #wait', '#wait'),
]

def run(src_dir):
    r = subprocess.run([MOC, "-r", "--package", "core", os.path.join(swap, "vendor/core@1.0.0/src"),
                        os.path.join(src_dir, "test/FeedTest.mo")], capture_output=True, text=True)
    out = r.stdout + r.stderr
    return "checks PASS" in out and r.returncode == 0, out

ok, out = run(os.path.join(swap, "canister"))
if not ok:
    print("FeedTest fails on the unmutated source:\n" + out); sys.exit(1)
survivors = []
for name, old, new in M:
    tmp = tempfile.mkdtemp()
    try:
        shutil.copytree(os.path.join(swap, "canister/src"), os.path.join(tmp, "src"))
        shutil.copytree(os.path.join(swap, "canister/test"), os.path.join(tmp, "test"))
        p = os.path.join(tmp, "src/Feed.mo")
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
