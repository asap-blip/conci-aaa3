# Concierge hardening + operator UX cleanup

Status: **artifacts only, committed to `claude/modest-mendel-SCFto`. Nothing
provisioned, nothing deployed.** SQL is grammar-validated with `pglast` (PG17);
all n8n Code nodes pass `node --check`. Runtime validation against a Supabase
branch + staging n8n instance is still required before go-live (see J).

---

## A. Current audit

**State storage.** 100% in n8n `$getWorkflowStaticData('global')` — one in-memory
object: `wallet, inventory, orders, voids, clients, front, pending,
pending_edits, pending_actions, front_prompts, ui_prompts, eta_snippets,
undo_buffer, log`, plus `next_order_id / next_action_id / next_snippet_id`. No
external store. The only export is the manual `c backup` JSON to DM. This is the
single point of failure the task targets.

**Operator command surface (before).** Everything prefixed `c …`:
`c wallet[/add/sub/set/reset]`, `c wallet pay …`, `c wallet paid`, `c jobs[/reset[/hard]]`,
`c inv[/add/set/reset]`, `c front[/<name>/ord-N/void]`, `c client(s)`, `c summary`,
`c backup`, `c undo`, `c cancel`, `c void`, `c edit`, `c eta`, `c claude on/off`,
`c kb/keyboard`, plus form-style and free-form intake.

**Keyboard (before).** 3×3: `💰 wallet / 📋 jobs / 🟧 front` · `➕ add / ➖ sub / 💵 paid`
· `📊 summary / 💾 backup / 🤖 claude`. No New Order; Claude exposed.

**Where `c` was enforced.** (1) the `If` gate node ternary, (2) the dispatch
tables, (3) the form parser (`firstLineParts[0]==='c'`), (4) the Claude path
(`raw_text.substring(2)`), (5) the staged-prompt cancel check.

**Where Claude was exposed.** `c claude on/off/status`, the `🤖 claude` button,
and free-form fall-through to the Anthropic API.

**Callbacks.** All in the Callback Handler node; staged state in
`pending_actions[act-N]` / `pending[ord-N]` held only in static data. Duplicate
taps guarded only by in-memory "not found / already handled" checks — not
durable, not transactional.

**Old core vs add-ons.** Order lifecycle + wallet/pay + fronts + clients +
summary/backup/undo/reset/edit/void = original concierge. ETA/dispatch (`c eta`,
auto-ETA on approval, `eta_snippets`, copy-snippet) = the v7.6 external bolt-on.

**Risky coupling.** Two ~god nodes (router ~1.3k lines, callback handler) both
mutate accounting state directly; `+$20 pay` magic number duplicated across 4
mutation sites; Telegram bot token + dispatch secret inlined in plaintext; intake
logic tightly coupled to the `c` prefix in five places.

---

## B. Product changes to implement

**Keyboard (after) — exact 3×3, persistent reply keyboard:**

| | | |
|---|---|---|
| Wallet | Jobs | Front |
| Add | Sub | Paid |
| Summary | Backup | New Order |

No Claude button. (`n8n/lib/keyboard.js`, applied in `Code` node.)

**Command surface (after).** Prefix-free. Plain words route to the same
handlers: `wallet`, `jobs`, `front`, `add`, `sub`, `paid`, `summary`, `backup`,
`new`. Still available (typed or via buttons/cards): `inv`, `clients`, `client`,
`eta`, `undo`, `void`, `edit`, `cancel`, `front …`, `kb`, plus period `close` /
`export` (mapped to RPCs). Legacy `c …` still accepted during transition
(`ALLOW_LEGACY_C_PREFIX = true`).

**New Order behavior.** Tapping **New Order** (or typing `new`) posts an inline
menu with two buttons — **Free-form** and **Form-style** — and example text for
each. Choosing one stages an intake prompt; the operator's next message is parsed
in that mode and converges on the existing pending-order card
(approve / 🟧 front / cancel). Free-form tries the deterministic tokenizer first
and only falls back to Claude internally; Form-style is deterministic only and
now also reads an optional `price:` line. `time:` blank = ASAP.

**Operator-facing text.** Help rewritten prefix-free with a NEW ORDER section and
no Claude/`c` references. Form template documented as
`name / order: / address: / price: / time:`.

---

## C. Persistence model

**Durable (Supabase Postgres — source of truth for the active period):** orders +
items + status, inventory, wallet (cash/pay), fronts + payment history, clients /
balances, staged `pending_actions`, the append-only `events` audit log, operating
periods, per-period counters, undo buffer.

**Ephemeral (Postgres, expirable; safe to wipe):** `ui_prompts` (one-step prompt
context), `front_prompts` (reply-to-bot front capture), `eta_snippets` (copy-button
text). Kept in Postgres rather than static data only so a late reply still
resolves after a restart, but they carry `expires_at` and are never authoritative.

**Derived (recomputed, never stored as truth):** summary/rollup output
(`v_orders_export`, `v_daily_rollup`, `period_totals`), overview cards, ETA
presentation text (raw ETA values come from the dispatch service).

**Storage choice — why Supabase Postgres.** It's already connected; it gives real
transactional accounting, an enforceable append-only audit table, and trivial
export (`export_period()` → one JSON, or plain SQL/`COPY`). It matches the
operator's manual-reconciliation + daily/weekly export-then-archive workflow far
better than n8n Data Tables (weak for audit/transactions) or a JSON-blob snapshot
(the operator explicitly rejected snapshot-as-primary-ledger).

---

## D. Data model

See `db/migrations/0001_operational_ledger.sql`. Schema `concierge`:

- `operating_periods(id, label, status, opened/closed_*, close_summary)` — one
  `active` at a time (partial unique index).
- `events(id, period_id, ts, actor, entity_type, entity_id, action, before_val,
  after_val, metadata)` — **append-only** (UPDATE/DELETE blocked by trigger).
- `wallet(period_id PK, cash, pay, updated_at)` — `total = cash - pay`,
  `pay >= 0`.
- `inventory(period_id, product, qty)` PK `(period_id, product)`.
- `clients(period_id, name, total_spent, first_seen, last_seen)`.
- `orders(id, period_id, human_id 'ord-N', status enum, name, price nullable,
  time_label, address, front_amount, intake_mode, entered/approved/voided/forgiven_*)`.
- `order_items(order_id, product, qty>0)`.
- `fronts(period_id, name, order_human_id, amount>=0)` + `front_payments(front_id, amount>0, ts)`.
- `pending_actions(token PK 'act-N', period_id, type, status enum, payload jsonb,
  staged/consumed_*, expires_at, result jsonb)`.
- `ui_prompts(chat_id PK, type, expires_at, …)`, `front_prompts(message_id PK …)`,
  `eta_snippets(id 'snip-N', …)`, `undo_buffer(period_id PK, type, payload, ts)`,
  `counters(period_id, name, value)`.
- Archive mirrors: `archive_*` tables (0003).

---

## E. Mutation rules

All in `db/migrations/0002_mutation_rpcs.sql`; each runs in one transaction,
updates operational tables for the active period, and appends one `events` row.
The n8n layer does **no money math** — it calls one RPC and renders the result.

- **new order intake** → `new_order(actor,name,items,price,time,address,mode)`:
  inserts a `pending` order + items, `order_created` event, returns the card json.
- **approve order** → `approve_order(actor,human,arm_front,msg_id)`: pending→open,
  inventory−, cash+price, **pay+20** (single constant `pay_per_order()`), client
  upsert, set undo buffer, optional durable front prompt; `order_approved`.
  Idempotent (already-open returns without re-applying).
- **cancel pending** → `cancel_pending`: pending→cancelled; `order_cancelled`.
- **void order** → `void_order`: restock, cash−price, **pay−20** (floored at 0),
  reverse front, reduce client spend by paid portion; open→voided; `order_voided`.
- **edit order** → `edit_order(actor,human,changes)`: re-balances inventory/cash/
  client for open orders; `order_edited` with before/after snapshots.
- **set front** → `set_front`: clamps `0..price`, upserts front row, adjusts client
  spend by delta; `front_set`.
- **mark paid** → `mark_paid`: FIFO allocation across the client's fronts, writes
  `front_payments`, decrements order front_amount; `payment_applied`.
- **forgive** → `forgive_front`: deletes the front, flags order forgiven, cash
  unchanged; `front_forgiven`.
- **wallet add/sub/set/reset** → `wallet_cash(op,amount)`; **pay** →
  `wallet_pay(op,amount)` (never negative). Events `wallet_*` / `pay_*`.
- **inventory add/set/reset_one/reset_all** → `inventory_adjust(op,changes)`;
  `inventory_*`.
- **undo** → `undo_last`: reverses last commit within 5 min via void path;
  `undo_applied`.
- **reset** → `period_reset(mode)`: soft = void open orders; hard = + cancel
  pending + reset ord counter (keeps wallet/inventory/clients/fronts, matching
  today). Distinct from period *close*.
- **callback apply/discard** → `consume_action` / `discard_action` (see F).

---

## F. Callback safety model

1. **Create.** Before sending a confirm card, the bot calls
   `stage_action(actor, type, payload)` → inserts a `pending_actions` row
   (`status='staged'`, `expires_at = now()+30min`) and returns `act-N`.
2. **Send.** The inline button carries `apply_<type>:act-N` / `discard_action:act-N`.
3. **Validate + apply.** On tap, `consume_action(actor, 'act-N')` selects the row
   `FOR UPDATE`, checks status + expiry, dispatches to the matching mutation RPC,
   marks `status='consumed'`, and **caches the result jsonb**.
4. **Idempotent re-taps.** A second tap on a `consumed` token returns the cached
   `result` instead of re-applying. Expired tokens flip to `expired` and return an
   error. Discard flips to `discarded`. Every transition appends an event.

This removes the reliance on in-memory callback payloads: confirm/apply survives a
restart, and double-taps can't double-charge.

---

## G. Files / workflows / nodes to change

Created in this pass:
- `db/migrations/0001_operational_ledger.sql` — schema + append-only events + pending_actions.
- `db/migrations/0002_mutation_rpcs.sql` — mutation + pending-action RPCs.
- `db/migrations/0003_export_archive.sql` — export views + close/archive.
- `db/README.md` — export / closeout / archive runbook.
- `n8n/lib/keyboard.js`, `router_normalize.js`, `new_order.js`, `persistence.js` — Code-node source modules.
- `n8n/concierge.original.workflow.json` — baseline under version control.
- `n8n/concierge.hardened.workflow.json` — patched workflow (operator UX).
- `n8n/patch_workflow.py` — deterministic, assertion-guarded patcher.

n8n nodes changed in the hardened workflow: `If` (gate → auth-only), `Code`
(keyboard, button map, prefix-free routing, New Order, help, form `price:`,
Claude internalized), `Callback Handler` (`new_order` action), `Claude Parser`
(`parse_text`).

Staged for the tested cutover (modules ready, not yet wired into the god nodes):
the Supabase-RPC persistence swap inside `Code` / `Callback Handler` (replace
static-data reads/writes with `makeLedger(db,actor)` calls).

---

## H. Code changes

Implemented and verified in this pass (see files above):
- Operator UX fully reworked in `concierge.hardened.workflow.json` (keyboard,
  gate, prefix-free routing, New Order two-mode, Claude internalized, help).
- Complete durable backend SQL (schema, RPCs, export/archive) — grammar-valid.
- Persistence/keyboard/intake modules — `node --check` clean.

Deliberately **not** done blind (see I/J): the line-by-line replacement of
static-data access in the two god nodes with `db.rpc(...)` calls. That is the one
change that can't be safely validated without a running n8n + Supabase, so it is
delivered as ready modules + this plan rather than spliced in untested.

---

## I. Migration / compatibility notes

- **Existing state.** Current static-data state is not auto-migrated. On cutover,
  run `c backup` on the live bot, then a one-time loader maps that JSON into the
  Supabase tables for the first `active` period (a small import script against the
  RPCs; not included here because it should run once, supervised). Until cutover,
  the hardened workflow still runs on static data — only the UX changed.
- **`c` prefix.** Kept as a temporary internal compatibility path
  (`ALLOW_LEGACY_C_PREFIX = true`); operator-facing surface no longer requires it.
  Flip to `false` to hard-disable once muscle memory fades.
- **Claude.** Removed from the operator surface entirely (no buttons/commands).
  Retained strictly internally as the free-form fall-back parser, tried only after
  the deterministic tokenizer fails. `data.claude_disabled` defaults false.
- **Bootstrap.** `0001` seeds exactly one `active` period + its wallet/counter
  rows, idempotently.

---

## J. Risk notes (honest limitations)

1. **Not runtime-tested.** SQL is grammar-validated (`pglast` PG17) but
   PL/pgSQL bodies and the RPC behavior are **not** executed here (no DB/Docker in
   this sandbox). Apply `0001–0003` to a Supabase **branch** and run the smoke
   tests before touching prod.
2. **God-node RPC cutover is staged, not shipped.** The hardened workflow still
   persists to static data; durability lands only when the persistence modules are
   wired into `Code` / `Callback Handler` on a staging instance. Doing it blind
   risked a split-brain between Supabase and static data, which is worse than
   either — hence staged.
3. **Concurrency.** The model assumes a single operator (serialized Telegram
   updates). `consume_action` uses `FOR UPDATE`, but the per-execution
   load→mutate→write pattern is not safe under true concurrent writers.
4. **Secrets.** The live bot token + dispatch secret are still inline in the
   original workflow. Move them to n8n credentials / `$env` and rotate them — out
   of scope for this pass but important.
5. **Free-form parser drift.** The local tokenizer covers the canonical shape; odd
   inputs still fall back to Claude. Behavior should be spot-checked against real
   historical messages.
6. **Archive is explicit and irreversible-ish.** `archive_closed_period` purges
   live rows after copying to `archive_*`. Always `export_period` to external
   storage first (the runbook enforces this ordering).
