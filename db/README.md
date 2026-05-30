# Concierge operational ledger — DB runbook

Supabase Postgres is the **durable but temporary** operational source of truth
for one *operating period* (a day or a week). Accounting/reconciliation is
**manual**, done outside the bot against exports. This is an operational ledger
with an explicit export → close → archive lifecycle, **not** a forever ledger.

## Migrations

Apply in order to a Supabase **branch** first, then promote:

```
0001_operational_ledger.sql   schema + append-only events + pending_actions + bootstrap
0002_mutation_rpcs.sql         deterministic accounting + durable callback RPCs
0003_export_archive.sql        export views + close/archive functions
```

`concierge.events` is append-only (UPDATE/DELETE blocked by trigger). All money
math lives in the `0002` RPC functions; the bot only calls RPCs.

## Daily / weekly lifecycle

```
   ┌─ open ─┐        operate          ┌─ export ─┐   reconcile   ┌─ close ─┐   ┌─ archive+purge ─┐
   │ active │ ───────────────────────▶│ to file  │ ────(human)──▶│ period  │──▶│ live rows gone, │
   └────────┘   orders/wallet/fronts  └──────────┘               └─────────┘   │ archive_* kept  │
                                                                                └─────────────────┘
```

### 1. Export (daily or weekly, before closing)

One call returns everything for a period (events + flat orders + fronts + clients
+ totals) as JSON — write it to the VM / removable storage, then encrypt/offload:

```sql
select concierge.export_period( (select id from concierge.operating_periods where status='active') );
```

Or pull flat tables for a spreadsheet:

```sql
select * from concierge.v_orders_export where period_id = :p;   -- one row per order
select * from concierge.v_daily_rollup  where period_id = :p;   -- revenue/day
select * from concierge.v_fronts_export where period_id = :p;   -- outstanding credit
select * from concierge.events where period_id = :p order by id; -- full audit trail
```

CSV from the CLI:

```bash
psql "$SUPABASE_DB_URL" -c "\copy (select * from concierge.v_orders_export where period_id=$P) to 'orders_$P.csv' csv header"
```

### 2. Reconcile

Human step, outside the bot, against the export.

### 3. Close

Captures headline totals into `operating_periods.close_summary`, marks the period
`closed`, and opens a fresh `active` period. **Does not delete anything.**

```sql
select concierge.close_period(:actor_telegram_id, '2026-W23');  -- label optional
```

### 4. Archive + purge (explicit, after a verified export)

Copies the closed period's rows into immutable `archive_*` tables, then deletes
them from the live operational tables to keep the active set small:

```sql
select concierge.archive_closed_period(:closed_period_id);
```

Guards: the period must be `closed` (not the active one). Archived rows remain
queryable via `concierge.archive_*`. **Always export first** — purge is not meant
to be reversed.

## What is archived vs what stays active

| Data | During active period | After close | After archive+purge |
|---|---|---|---|
| orders / items / fronts / payments | live | live (closed) | in `archive_*`, removed from live |
| wallet / inventory / clients | live | live (closed) | in `archive_*`, removed from live |
| events (audit) | live, append-only | live | copied to `archive_events`, removed from live |
| pending_actions / ui_prompts / front_prompts / eta_snippets / undo | live | stale | purged |
| operating_periods row | active | closed | kept, tagged `[archived]` |

## In-period reset vs period close

- `concierge.period_reset('soft'|'hard')` — the bot's "jobs reset": clears
  orders only (keeps wallet/inventory/clients/fronts). Same semantics as today.
- `close_period` / `archive_closed_period` — the accounting closeout above. These
  are different operations; reset never archives.

## Config (n8n side)

Set in n8n environment / credentials — never inline:

```
SUPABASE_URL                https://<ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY   <service role key>   # server-side only
```

Expose the `concierge` schema in Supabase (Settings → API → Exposed schemas) so
PostgREST can reach the RPCs, or add thin `public` wrapper functions.
