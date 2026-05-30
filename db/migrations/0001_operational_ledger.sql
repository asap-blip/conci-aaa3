-- ============================================================================
-- 0001_operational_ledger.sql
-- Concierge / dispatch bot — durable operational ledger (schema)
-- ----------------------------------------------------------------------------
-- Design intent (per operator):
--   * Supabase Postgres is the DURABLE, but TEMPORARY, operational source of
--     truth for an active operating period (a day / a week).
--   * Accounting/reconciliation happens MANUALLY, outside the bot, against
--     exported data.
--   * Everything important is also written to an APPEND-ONLY event log so the
--     full mutation history of a period can be exported and audited.
--   * After reconciliation, an operating period is CLOSED: its operational
--     rows are archived (copied out / snapshotted) and the live tables can be
--     cleared safely and explicitly. This is NOT a forever-ledger.
--
-- This file is schema only (tables, types, indexes, constraints, seed of the
-- first operating period). Mutation logic lives in 0002; export/archive in 0003.
--
-- All objects live in schema `concierge` to keep them isolated and easy to
-- export / drop as a unit.
-- ============================================================================

create schema if not exists concierge;

set search_path = concierge, public;

-- ----------------------------------------------------------------------------
-- Enums (kept small and explicit)
-- ----------------------------------------------------------------------------

-- Order lifecycle. `pending` = staged, awaiting operator confirm.
do $$ begin
  create type concierge.order_status as enum ('pending', 'open', 'voided', 'cancelled');
exception when duplicate_object then null; end $$;

-- Pending action lifecycle for inline-button confirm/apply flows.
do $$ begin
  create type concierge.action_status as enum ('staged', 'consumed', 'discarded', 'expired');
exception when duplicate_object then null; end $$;

-- Operating period lifecycle.
do $$ begin
  create type concierge.period_status as enum ('active', 'closing', 'closed');
exception when duplicate_object then null; end $$;

-- ----------------------------------------------------------------------------
-- Operating periods
-- ----------------------------------------------------------------------------
-- An operating period is the unit of "open the register / close the register".
-- Exactly one period is `active` at a time. All operational rows carry the
-- period_id they belong to, which makes daily/weekly export + safe clearing a
-- single scoped operation.
-- ----------------------------------------------------------------------------
create table if not exists concierge.operating_periods (
  id            bigint generated always as identity primary key,
  label         text        not null,                 -- e.g. '2026-05-30' or '2026-W22'
  status        concierge.period_status not null default 'active',
  opened_at     timestamptz not null default now(),
  opened_by     bigint,                               -- telegram user id
  closed_at     timestamptz,
  closed_by     bigint,
  notes         text,
  -- snapshot of headline totals captured at close, for quick reconciliation
  close_summary jsonb
);

-- Only one active period at a time.
create unique index if not exists operating_periods_one_active
  on concierge.operating_periods (status)
  where status = 'active';

-- ----------------------------------------------------------------------------
-- Append-only event log  (THE audit trail / history spine)
-- ----------------------------------------------------------------------------
-- Every important mutation appends exactly one row here, in the same
-- transaction as the state change (see 0002). This table is INSERT-ONLY:
-- updates and deletes are blocked by trigger below. It is the artifact you
-- export for accounting and the thing you trust when projections look wrong.
-- ----------------------------------------------------------------------------
create table if not exists concierge.events (
  id          bigint generated always as identity primary key,
  period_id   bigint      not null references concierge.operating_periods(id),
  ts          timestamptz not null default now(),
  actor       bigint,                                 -- telegram user id that caused it
  entity_type text        not null,                   -- 'order' | 'wallet' | 'pay' | 'front' | 'inventory' | 'client' | 'period' | 'eta' | 'action'
  entity_id   text,                                   -- e.g. 'ord-12', client name, product key, action token
  action      text        not null,                   -- 'order_created' | 'order_approved' | ...
  before_val  jsonb,                                  -- relevant prior values (nullable)
  after_val   jsonb,                                  -- relevant new values (nullable)
  metadata    jsonb       not null default '{}'::jsonb
);

create index if not exists events_period_ts_idx on concierge.events (period_id, ts);
create index if not exists events_entity_idx     on concierge.events (entity_type, entity_id);
create index if not exists events_action_idx      on concierge.events (action);

-- Enforce append-only: block UPDATE/DELETE on events.
create or replace function concierge.block_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'concierge.events is append-only (% blocked)', tg_op;
end $$;

drop trigger if exists events_no_update on concierge.events;
create trigger events_no_update before update or delete on concierge.events
  for each row execute function concierge.block_mutation();

-- ----------------------------------------------------------------------------
-- Wallet (singleton per active period)
-- ----------------------------------------------------------------------------
-- Mirrors the bot's existing model exactly:
--   total = cash - pay
--   cash  = gross taken in
--   pay   = accrual that grows by PAY_PER_ORDER on each committed order
-- One row per operating period.
-- ----------------------------------------------------------------------------
create table if not exists concierge.wallet (
  period_id   bigint primary key references concierge.operating_periods(id),
  cash        integer     not null default 0,
  pay         integer     not null default 0,
  updated_at  timestamptz,
  constraint wallet_pay_nonneg check (pay >= 0)
);

-- ----------------------------------------------------------------------------
-- Inventory (one row per product per period)
-- ----------------------------------------------------------------------------
-- Valid products are enforced in application + RPC layer (kept as text here so
-- adding a product is a data change, not a schema migration).
-- ----------------------------------------------------------------------------
create table if not exists concierge.inventory (
  period_id   bigint  not null references concierge.operating_periods(id),
  product     text    not null,
  qty         integer not null default 0,
  updated_at  timestamptz,
  primary key (period_id, product)
);

-- ----------------------------------------------------------------------------
-- Clients (per period operational view; reconciliation is manual/external)
-- ----------------------------------------------------------------------------
create table if not exists concierge.clients (
  period_id    bigint  not null references concierge.operating_periods(id),
  name         text    not null,                      -- lowercase first name (matches bot)
  total_spent  integer not null default 0,
  first_seen   timestamptz,
  last_seen    timestamptz,
  primary key (period_id, name)
);

-- ----------------------------------------------------------------------------
-- Orders + line items
-- ----------------------------------------------------------------------------
-- `human_id` is the operator-facing 'ord-N' string (unique within a period).
-- Items are normalized into order_items so summaries/tallies are pure SQL.
-- ----------------------------------------------------------------------------
create table if not exists concierge.orders (
  id            bigint generated always as identity primary key,
  period_id     bigint      not null references concierge.operating_periods(id),
  human_id      text        not null,                 -- 'ord-12'
  status        concierge.order_status not null default 'pending',
  name          text        not null,                 -- client name (lowercase)
  price         integer,                              -- nullable: '[no price]'
  time_label    text,                                 -- nullable reservation time; null = ASAP
  address       text        not null,
  front_amount  integer     not null default 0,
  intake_mode   text,                                 -- 'freeform' | 'form' | 'edit'
  entered_by    bigint,
  entered_at    timestamptz not null default now(),
  approved_by   bigint,
  approved_at   timestamptz,
  voided_by     bigint,
  voided_at     timestamptz,
  forgiven      boolean     not null default false,
  forgiven_by   bigint,
  forgiven_at   timestamptz,
  unique (period_id, human_id),
  constraint orders_front_nonneg check (front_amount >= 0)
);

create index if not exists orders_period_status_idx on concierge.orders (period_id, status);
create index if not exists orders_name_idx           on concierge.orders (period_id, name);

create table if not exists concierge.order_items (
  id        bigint generated always as identity primary key,
  order_id  bigint  not null references concierge.orders(id) on delete cascade,
  product   text    not null,
  qty       integer not null,
  constraint order_items_qty_pos check (qty > 0)
);

create index if not exists order_items_order_idx on concierge.order_items (order_id);

-- ----------------------------------------------------------------------------
-- Fronts (outstanding client credit) + payment history
-- ----------------------------------------------------------------------------
-- A "front" is money a client owes on a specific order. `amount` is the
-- CURRENT outstanding balance for that order's front (decremented as paid).
-- front_payments is append-only payment history per front entry.
-- ----------------------------------------------------------------------------
create table if not exists concierge.fronts (
  id          bigint generated always as identity primary key,
  period_id   bigint  not null references concierge.operating_periods(id),
  name        text    not null,
  order_human_id text not null,                       -- 'ord-N' this front is against
  amount      integer not null,                       -- current outstanding on this front
  created_at  timestamptz not null default now(),
  unique (period_id, name, order_human_id),
  constraint fronts_amount_nonneg check (amount >= 0)
);

create index if not exists fronts_period_name_idx on concierge.fronts (period_id, name);

create table if not exists concierge.front_payments (
  id        bigint generated always as identity primary key,
  front_id  bigint  not null references concierge.fronts(id) on delete cascade,
  amount    integer not null,
  ts        timestamptz not null default now(),
  constraint front_payments_amount_pos check (amount > 0)
);

-- ----------------------------------------------------------------------------
-- Pending actions (DURABLE callback/confirm state)  — see 0002 for idempotency
-- ----------------------------------------------------------------------------
-- Every inline-button mutation stages a row here BEFORE the card is sent.
-- The callback handler loads by token, checks status + expiry, applies, and
-- marks consumed. Because this is durable, confirm/apply survives a restart
-- and duplicate taps are idempotent (status flips staged -> consumed once).
-- ----------------------------------------------------------------------------
create table if not exists concierge.pending_actions (
  token        text        primary key,               -- 'act-N' (also used in callback_data)
  period_id    bigint      not null references concierge.operating_periods(id),
  type         text        not null,                   -- 'paid' | 'void' | 'forgive' | 'front_set' | 'reset_soft' | 'reset_hard'
  status       concierge.action_status not null default 'staged',
  payload      jsonb       not null,                   -- everything needed to apply (allocation preview, amounts, ids)
  staged_by    bigint,
  staged_at    timestamptz not null default now(),
  expires_at   timestamptz not null,                  -- staged_at + TTL
  consumed_at  timestamptz,
  consumed_by  bigint,
  result       jsonb                                  -- cached result text for idempotent re-taps
);

create index if not exists pending_actions_period_status_idx
  on concierge.pending_actions (period_id, status);

-- ----------------------------------------------------------------------------
-- Ephemeral UI state (prompts + keyboard interaction hints)
-- ----------------------------------------------------------------------------
-- Short-lived, may expire. Kept in Postgres (not n8n static data) only so that
-- a reply that lands minutes later still resolves after a restart. Rows are
-- safe to wipe at any time.
-- ----------------------------------------------------------------------------
create table if not exists concierge.ui_prompts (
  chat_id     bigint      primary key,                -- one staged prompt per chat
  type        text        not null,                   -- 'wallet_add' | 'wallet_sub' | 'wallet_paid' | 'new_order_freeform' | 'new_order_form'
  staged_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  staged_by   bigint,
  metadata    jsonb       not null default '{}'::jsonb
);

-- reply-to-bot front prompts keyed by the bot message id being replied to
create table if not exists concierge.front_prompts (
  message_id  bigint      primary key,
  period_id   bigint      not null references concierge.operating_periods(id),
  order_human_id text     not null,
  name        text,
  price       integer,
  staged_at   timestamptz not null default now(),
  expires_at  timestamptz not null
);

-- ----------------------------------------------------------------------------
-- ETA snippets (derived presentation text, kept only for the copy button)
-- ----------------------------------------------------------------------------
create table if not exists concierge.eta_snippets (
  id          text        primary key,                -- 'snip-N'
  period_id   bigint      not null references concierge.operating_periods(id),
  text        text        not null,
  created_at  timestamptz not null default now(),
  last_tapped_at timestamptz
);

-- ----------------------------------------------------------------------------
-- Undo buffer (last reversible commit). Single row per period; intended to
-- survive restart so `undo` still works within its 5 min window.
-- ----------------------------------------------------------------------------
create table if not exists concierge.undo_buffer (
  period_id   bigint primary key references concierge.operating_periods(id),
  type        text   not null,                        -- 'order_commit'
  payload     jsonb  not null,                        -- snapshot needed to reverse
  ts          timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- Per-period monotonic counters (ord-N, act-N, snip-N) — replaces the
-- next_order_id / next_action_id / next_snippet_id ints in static data.
-- ----------------------------------------------------------------------------
create table if not exists concierge.counters (
  period_id   bigint not null references concierge.operating_periods(id),
  name        text   not null,                        -- 'order' | 'action' | 'snippet'
  value       integer not null default 0,
  primary key (period_id, name)
);

-- ----------------------------------------------------------------------------
-- Bootstrap: ensure exactly one active period exists, plus its wallet row and
-- counters. Idempotent — safe to run repeatedly.
-- ----------------------------------------------------------------------------
do $$
declare
  v_period bigint;
begin
  select id into v_period from concierge.operating_periods where status = 'active' limit 1;
  if v_period is null then
    insert into concierge.operating_periods (label, status)
    values (to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'), 'active')
    returning id into v_period;
  end if;

  insert into concierge.wallet (period_id, cash, pay)
  values (v_period, 0, 0)
  on conflict (period_id) do nothing;

  insert into concierge.counters (period_id, name, value) values
    (v_period, 'order', 0),
    (v_period, 'action', 0),
    (v_period, 'snippet', 0)
  on conflict (period_id, name) do nothing;
end $$;
