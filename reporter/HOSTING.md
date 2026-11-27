# Price reporter: why principal authentication is enough, and what hosting needs

## Authentication
A report is an update call to the swap canister's `report(round_open, reports)`. The reporter signs the call with its
own Ed25519 key. The Internet Computer verifies that signature against the sender's self-authenticating principal
before the message runs, so the canister's `caller` is that principal. The canister accepts a report only if:
- the caller is in the reporter set (a DAO setting, at most 16, with k ≥ 3 and k > n/2 enforced in code);
- the report names the round open now, by the canister's own clock;
- the caller has not already reported for that round and pair;
- `observed_at` is no earlier than the round's open, not in the future, and no older than the report age limit.

That is sufficient, and per-report signatures would add nothing:
- **Forgery.** Without the reporter's key no message can carry its principal. A signature inside the payload would
  be made with the same key, so a stolen key forges both equally.
- **Replay.** The IC refuses a duplicate ingress message (request id, expiry). Independently of that, a report is
  valid only for the round open now, and only once per reporter per round. A replayed or delayed copy is
  "round-closed", "duplicate-report" or "late", and never changes a finalized round.
- **Relaying.** Reporters call the canister directly. No third party carries their reports, so no
  carrier-independent signature is needed.
- **Accountability.** The canister names the outlier of the latest frozen round (`frozen_outlier` in `status`).
  It is the principal that signed the call, which is what the DAO needs to remove that reporter. Older rounds keep
  only their accepted price, sample time and finalization time, not the individual reports.

## What hosting needs
One reporter per independent host. None of them may share a machine, a cloud account, a region or a key with
another.

| Need | Detail |
|---|---|
| Machine | 1 vCPU, 512 MB RAM, a few hundred MB of disk for the binary and logs. Any Linux x86-64 host. |
| Network out | HTTPS to the venues' public ticker endpoints and to the IC API boundary (`icp-api.io`). No inbound ports. |
| Venue access | Binance and OKX refuse some jurisdictions (the United States among them), so a host's region must be one where every configured venue answers. A reporter needs at least 3 answering venues per pair, otherwise it refuses to report. |
| Clock | NTP-synchronised. The reporter follows the canister's clock (`round_info`, offset from the query midpoint), so its own clock sets only TLS validity and log times. |
| Key | One Ed25519 key per reporter (`swap-reporter keygen <pem>`), mode 0600, on that host only. Its principal (`swap-reporter principal <pem>`) is what the DAO puts in the reporter set. |
| Process | `swap-reporter run <config.json>` under a supervisor that restarts it (systemd `Restart=always`). It keeps no state between runs. |
| Config | The swap canister id, `https://icp-api.io`, the pem path and, per pair, the asset pool's id, the market symbol, the decimals and at least 3 venues. `local`, `replay` and `plant` are refused unless `local` is set, and `local` is only for a replica with its own root key. |
| Monitoring | One stdout line per round with the canister's outcome per pair (`accepted`, `finalized`, `late`, `frozen`, `held`, `refused:<why>`), and stderr lines for venue errors and refusals. Alert on any round without `accepted` or `finalized`, and on `refused`. |
| Cycles | None for the reporter. Ingress update calls are paid by the swap canister: measured on PocketIC, one report costs it about 6.8 M cycles, and one round of 5 reports on 2 pairs about 61 M. At one round every 5 s that is about 1.06 T cycles a day for the feed, on top of the canister's idle tick (about 1.17 T a day). |
| Rotation | A key is replaced by a DAO `SetFeed` naming the new principal; the old key is useless from that proposal on. |
