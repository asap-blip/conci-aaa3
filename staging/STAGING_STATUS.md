# Staging status — ccv10 (`tludtcrrumfghzjbwcso`)

Updated 2026-05-30. **Staging only. Not production.**

## Applied (verified)

- Pre-reset backup captured → `staging/ccv10-backup/`.
- `DROP SCHEMA concierge CASCADE` (old trips/drivers model) — `public`, PostGIS,
  and Supabase-managed schemas left untouched (confirmed: 20 public tables +
  `spatial_ref_sys` intact).
- Migrations applied as tracked migrations, in order:
  `concierge_0001_operational_ledger`, `_0002_mutation_rpcs`,
  `_0003_export_archive`, `_0004_state_bridge`.
- Object inventory: 25 tables, 3 views, 31 functions in `concierge`.

## Runtime smoke tests (PL/pgSQL actually executed — clears the "never run" risk)

- **Bridge path (what the bot uses):** `save_state` of a crafted "approved
  maya 2×50p $65" doc → `materialize` produced exact normalized rows;
  **doc wallet == table wallet (parity)**; `50p` preserved qty 2; inventory −2;
  client $65; append-only `order_approved` event written; counters correct.
- **RPC path (staged future):** `new_order → approve_order → set_front →
  mark_paid → void_order` all returned `ok:true`.
- **Reset to pristine** afterwards: active period #1, 0 orders / 0 events /
  0 fronts / 0 clients / 0 inventory / 0 state_doc, wallet 0/0, counters 0.

## Required config before the bot works (one gate)

PostgREST does not expose the `concierge` schema by default, so the workflow's
`Accept-Profile: concierge` RPC calls would 404. Expose it (staging):
- Dashboard → Settings → API → **Exposed schemas** → add `concierge`; **or**
- SQL: `alter role authenticator set pgrst.db_schemas = 'public, graphql_public, concierge'; notify pgrst, 'reload config';`

## Note

`concierge.*` tables have RLS disabled. Acceptable for a **service-role-only**
staging bot (no anon access). Revisit before production.
