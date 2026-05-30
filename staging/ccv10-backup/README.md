# ccv10 staging backup (pre-reset)

Captured **2026-05-30** from Supabase project **ccv10** (`tludtcrrumfghzjbwcso`)
before repurposing it as the disposable concierge **staging** target. Logical
(JSON) backup via SQL — this is a safety net, not a physical `pg_dump`.

## Files

| File | Contents | Rows |
|---|---|---|
| `concierge_schema_data.json` | Full data of the **old** `concierge` schema (the model being dropped) | 104 (command_log 81, trips 9, inventory 9, drivers 2, driver_assignments 2, finance_wallet 1; alerts/fronts/trip_legs/eta_snapshots/staged_prompts/finance_transactions empty) |
| `public_app_tables_data.redacted.json` | Non-empty `public.*` app tables (NOT being dropped under the recommended plan; kept for completeness) | 23 (config_kv 8, client_area_snapshots 6, location_pings 4, drivers 3, scopes 2) |
| `schema_manifest.json` | Column definitions for all `concierge.*` (incl. views) and the `public` app tables | 167 + 187 columns |

## Redactions (security)

The committed `public_app_tables_data.redacted.json` has secrets masked:
- `public.drivers.ping_secret` → `REDACTED`
- `public.client_area_snapshots.map_url` Mapbox `access_token=pk.…` → `REDACTED`

The raw values are **not** in git. They remain live in ccv10 until reset — if
you need the real `ping_secret`/Mapbox token, copy them from the live DB before
the reset. (Neither belongs to anything the new concierge staging needs.)

## Not included

- `public.spatial_ref_sys` (8,500 rows) — standard PostGIS reference data,
  regenerable, intentionally excluded.
- Supabase-managed schemas (`auth`, `storage`, `realtime`, `vault`,
  `supabase_migrations`, `graphql`, `extensions`, `pgbouncer`) — untouched.

## Reset safety check (recorded)

Dependency scan confirmed the only objects depending on `concierge.*` are their
own auto-managed TOAST tables. **No `public` object and no foreign key outside
`concierge` depends on it**, so `DROP SCHEMA concierge CASCADE` is isolated.
