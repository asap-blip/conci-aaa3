# conci-aaa3 — concierge / dispatch bot hardening

Targeted hardening + operator-UX cleanup for the n8n Telegram concierge bot.
**This pass is artifacts only — nothing is provisioned or deployed.**

## Layout

```
docs/PLAN.md                          full A–J plan: audit, product changes,
                                      persistence model, data model, mutation
                                      rules, callback safety, migration, risks
db/README.md                          DB runbook: export / close / archive
db/migrations/0001_operational_ledger.sql   schema + append-only events + pending_actions
db/migrations/0002_mutation_rpcs.sql         deterministic accounting + callback RPCs
db/migrations/0003_export_archive.sql        export views + close/archive
n8n/concierge.original.workflow.json   baseline workflow (version control)
n8n/concierge.hardened.workflow.json   patched workflow (operator UX)
n8n/patch_workflow.py                  deterministic, assertion-guarded patcher
n8n/lib/*.js                           Code-node source modules
```

## What changed in this pass

- **Operator UX (shipped in the hardened workflow):** new 3×3 reply keyboard
  (Wallet/Jobs/Front · Add/Sub/Paid · Summary/Backup/New Order), **no `c`
  prefix**, **New Order** entry point with Free-form + Form-style modes, Claude
  removed from the operator surface (kept internal). Legacy `c …` still works
  during transition.
- **Durable persistence (shipped as validated SQL + modules):** Supabase Postgres
  schema with normalized operational tables, an append-only audit/event log, a
  durable `pending_actions` table with idempotent consume, and an
  export → close → archive lifecycle for manual daily/weekly accounting.

## Verification done here

- SQL: grammar-validated against PostgreSQL (PG17) via `pglast`.
- n8n Code nodes: pass `node --check`.
- Patch: each edit is assertion-guarded; routing simulated.

Runtime validation against a Supabase branch + staging n8n is still required —
see `docs/PLAN.md` §J.
