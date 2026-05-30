# Cutover: n8n static data → Supabase (staging)

This pass delivers the durable-persistence cutover as a **separate, reviewable
diff for a staging instance**. Nothing is provisioned or deployed.

## What changed

- **`db/migrations/0004_state_bridge.sql`** — the bridge:
  - `concierge.state_doc` — authoritative working document, one row per period.
  - `load_state()` — returns the active period's doc (bootstraps if none). Exact
    round-trip, so there is no load/save asymmetry risk.
  - `save_state(p_state, p_events, p_actor)` — one transaction: upsert the doc,
    append collected events to the append-only `events` log, and re-materialize
    the normalized accounting tables (`materialize()`) for export/query.
- **`n8n/concierge.supabase.workflow.json`** — the hardened workflow with the two
  god nodes cut over: state now loads/saves through Supabase instead of
  `$getWorkflowStaticData`. Produced deterministically by
  `n8n/build_supabase_workflow.py` (assertion-guarded transform).
- **`scripts/import_backup.mjs`** — one-time loader: a `c backup` JSON → a single
  `save_state()` call (with `--dry-run`).
- **`scripts/test_cutover.mjs`** — offline harness running the real transformed
  node bodies against an in-memory bridge fake (19 checks, all green).
- Fixed a latent bug while here: form-style intake split half-products
  (`2 50p` → `50 p` → parsed as `p`). Now re-merged to `50p`. Applied in the
  workflow patch and `n8n/lib/new_order.js`.

## Why this shape (not per-mutation RPCs yet)

The bot keeps its proven in-memory accounting/render logic; only *where state
lives* changes. This is the smallest safe cutover — a blind, untestable
rewrite of ~1300 lines into per-mutation RPC calls was rejected as too risky for
a first diff. The normalized tables + append-only events still give the
auditable, queryable, exportable ledger the accounting workflow needs. Handlers
can later be migrated to the `0002` per-mutation RPCs one at a time (strangler
pattern) with `save_state` materialize as the safety net.

## How the cutover wiring works (per node)

A prelude (where `this`/`$json`/`$env` are valid) builds a Supabase client and
`loadState`/`saveState`; the existing body is wrapped:

```js
let data;
async function __main() {
  data = await loadState();   // was: $getWorkflowStaticData('global')
  data.__events = [];
  /* ...all existing logic unchanged... */
}
const __out = await __main();
await saveState(data);        // persist doc + events + normalized projection
return __out;
```

`pushLog()` (router) and the callback's audit push now also append structured
rows to `data.__events`, which `save_state` writes to the append-only log.

## Staging runbook (do in order, on a Supabase BRANCH)

1. **Apply migrations** `0001 → 0002 → 0003 → 0004` to a Supabase branch.
2. **Smoke-test the bridge** in SQL:
   ```sql
   select concierge.load_state();                         -- bootstraps a period + empty doc
   select concierge.save_state(concierge.load_state(), '[]'::jsonb, 0);
   select * from concierge.state_doc;                     -- doc present
   select * from concierge.orders;                        -- materialized (empty ok)
   ```
3. **Import current state** (after a fresh `c backup` from the live bot):
   ```bash
   node scripts/import_backup.mjs concierge-backup-*.json --actor <your_tg_id> --dry-run
   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
     node scripts/import_backup.mjs concierge-backup-*.json --actor <your_tg_id>
   ```
   Verify `concierge.export_period((select id from concierge.operating_periods where status='active'))`.
4. **Configure n8n** (staging): set env `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`;
   enable env access for Code nodes; expose the `concierge` schema in Supabase
   (Settings → API), or add `public` wrapper functions for `load_state`/`save_state`.
5. **Import `concierge.supabase.workflow.json`** into staging n8n, point the
   Telegram trigger at a **test bot**, and walk the flows: new order (both modes),
   approve / 🟧 front / cancel, wallet add/sub/paid, void, undo, summary, backup.
   Confirm rows land in `concierge.*` and events accrue.
6. **Reconcile parity**: compare a staging `c summary` / `c backup` against the
   same actions on the current prod bot.
7. Only after parity: schedule the prod cutover (final `c backup` → import →
   switch the prod workflow → watch `events`).

## Offline checks already run here

- All SQL parses against PostgreSQL (PG17) via `pglast`.
- All Code nodes + scripts pass `node --check`.
- `node scripts/test_cutover.mjs` → 19/19 (load/save, persistence across
  messages, prefix-free + prompt + form/free-form routing, durable audit,
  callback approve commit, idempotent re-tap).

## Still required before prod (see also docs/PLAN.md §J)

- PL/pgSQL bodies are **not** executed here — run steps 1–6 on a branch.
- Single-operator assumption (no concurrent writers); `save_state` rewrites the
  period's operational rows each turn (fine at this volume).
- Rotate the inline Telegram/dispatch secrets and move them to credentials.
