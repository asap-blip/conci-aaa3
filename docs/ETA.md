# ETA module (standalone) — `eta.workflow.json`

A **separate** dispatch/ETA workflow. It does **not** modify or depend on the
concierge order workflow (the three `concierge.*.workflow.json` files are
untouched). Designed to be reused by the concierge later via a clean payload.

## Files
- `n8n/lib/eta.js` — shared pure logic (parse, payload, card render, snippet, stacking). Reusable; offline-tested.
- `n8n/eta.workflow.json` — the standalone workflow (own ETA bot).
- `n8n/build_eta_workflow.py` — deterministic builder (embeds `eta.js` + network glue).

## Architecture (B = hybrid)
Separate n8n workflow (own Telegram bot) + shared JS module. GPS/routing stays
in the **existing external dispatch service** (not duplicated). Quote staging
lives in this workflow's own static data (ephemeral — quick quotes only).

## Config (n8n env / credentials)
- `ETA_BOT_TOKEN` — a **separate** test/ETA Telegram bot (raw HTTP sends use it).
- `ETA Trigger` node: set the **telegramApi credential** for that bot (placeholder `REPLACE_WITH_ETA_BOT_CREDENTIAL` on import).
- `DISPATCH_ETA_URL`, `DISPATCH_SECRET` — same dispatch service the concierge uses.
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — read-only, to read the driver's active jobs from `concierge.state_doc` for stacked mode (optional; absent ⇒ direct mode only).

## Operator flow
**Mode 1 — direct quote.** Send:
```
eta
maya
2×p
4444 sherbrooke
```
→
```
QUICK ETA
Client: maya
Order: 2×p
To: 4444 sherbrooke
Driver: T
Internal: 18 min · arriving 3:42 a.m.
Client: ~23 min · arriving 3:47 a.m.
Maps: https://maps.google.com/?q=4444+sherbrooke
Client copy
on my way, ~23 min — arriving 3:47 a.m.
```
Buttons: `[T] [FISTON]` · `[✅ Apply as order] [❌ Cancel]`.

**Mode 2 — stacked.** Tapping a driver re-quotes; if that driver has active jobs
(read from concierge state) the card switches to:
```
QUICK ETA · STACKED
Client: maya
Order: 2×p
Driver: T
New stop: 4444 sherbrooke
Current queue
1. sara · 8 min
2. adam · 19 min
If added after current jobs:
maya · +~14 min after adam  (est)
Arriving in ~33 min
ETA: 3:57 a.m.
```
No queue for the chosen driver ⇒ direct arrival card.

## D. ETA payload contract (reusable hand-off)
```
{ ok, mode:'direct'|'stacked', client, items, items_parsed:[{product,qty}], address,
  driver:'T'|'FISTON', maps_url,
  internal:{minutes,arrival_label}, client_eta:{minutes,arrival_label}|null, snippet,
  queue:[{client,address,minutes}],
  stacked:{after,added_minutes,total_minutes,arrival_label,approximate:true}|null,
  apply:{ wired:false, order_draft:{client,items_parsed,address,driver} },
  dispatch_ok, error, generated_at }
```
The concierge can later read `apply.order_draft` to create/approve a real order.

## E. Stacked computation (v1, append-to-end)
For the selected driver: read active jobs (`state_doc.doc.orders`, `status:'open'`,
`driver`=selected), get each stop's **direct** ETA from dispatch, sort ascending;
the new stop is appended after the last ⇒ `total ≈ lastQueueMinutes + newStopDirectETA`,
arrival = now + total. No route optimization.

## F. Real vs temporary in v1
- **Fully working:** input parsing; direct ETA card (internal + client buffered +
  maps + client-copy snippet) via the proven dispatch contract; T/FISTON re-quote
  (in-place edit); graceful dispatch/Supabase failure (shows a reason, never crashes).
- **Real but APPROXIMATE:** stacked queue listing + per-stop direct ETAs are real
  (from concierge state); the cumulative `+X after Y / total` is a **labeled
  append-to-end estimate**. Precise multi-stop timing needs a dispatch upgrade
  (arbitrary-origin / multi-stop) — not done here.
- **Forward-compat (depends on dispatch):** the request sends `driver`; per-driver
  ETA differences only appear if the dispatch service uses per-driver GPS. If it
  ignores `driver`, both drivers return the same point ETA.
- **Explicit NO-OP:** `✅ Apply as order` does **not** create an order. It replies
  "Apply as order is NOT wired yet (no-op)" and surfaces `apply.order_draft` for
  later wiring into the concierge.

## Verification done
`n8n/lib/eta.js` offline self-test (parse + both card layouts + snippet + stacking)
matches the examples above; both Code nodes pass `node --check`; `eta.workflow.json`
is valid JSON with no secrets. **Not** runtime-tested against a live ETA bot /
dispatch / Supabase — import into staging with a test ETA bot and validate.

## G. Not touched
No change to `concierge.original/hardened/supabase.workflow.json`, the DB, or
inventory/wallet/order logic.
