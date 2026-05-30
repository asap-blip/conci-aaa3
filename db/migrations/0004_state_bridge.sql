-- ============================================================================
-- 0004_state_bridge.sql
-- Cutover bridge: durable state document + normalized projection + audit append
-- ----------------------------------------------------------------------------
-- This is the SMALLEST SAFE cutover from n8n static data to Supabase. Instead
-- of rewriting the two ~god nodes into per-mutation RPC calls (a large, blind,
-- untestable change), the bot keeps its proven in-memory logic but:
--
--   * loads its working state from concierge.state_doc (NOT static data)
--   * saves the working state back after every update, in one transaction that
--       (a) upserts the authoritative JSON document,
--       (b) appends the mutation events it collected (append-only audit), and
--       (c) re-materializes the normalized accounting tables (0001) so
--           export / reconciliation / SQL queries work on real columns.
--
-- The document is the bot's fast working copy; the normalized tables + events
-- are the accountant-facing, queryable, auditable projection. If materialize()
-- ever hiccups, the bot still runs off the document (resilient). Individual
-- handlers can later be migrated to the 0002 per-mutation RPCs incrementally
-- (strangler pattern) without another big-bang change.
--
-- load_state() round-trips exactly (read the doc), so there is no load/save
-- asymmetry risk. The one-time importer (scripts/import_backup.mjs) is just a
-- single save_state() call with a `c backup` JSON as the document.
-- ============================================================================

set search_path = concierge, public;

-- Authoritative working document, one row per period.
create table if not exists concierge.state_doc (
  period_id   bigint primary key references concierge.operating_periods(id),
  doc         jsonb       not null,
  updated_at  timestamptz not null default now()
);

-- The legacy bootstrap shape (mirrors the bot's section-1 bootstrap exactly).
create or replace function concierge.empty_state()
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'wallet', jsonb_build_object('cash', 0, 'pay', 0, 'updated_at', null),
    'inventory', jsonb_build_object('c',0,'50c',0,'p',0,'50p',0,'b',0,'50k',0,'k',0,'m',0,'s',0),
    'orders', '[]'::jsonb, 'voids', '[]'::jsonb, 'clients', '{}'::jsonb, 'front', '{}'::jsonb,
    'log', '[]'::jsonb, 'pending', '{}'::jsonb, 'pending_edits', '{}'::jsonb,
    'pending_actions', '{}'::jsonb, 'front_prompts', '{}'::jsonb, 'ui_prompts', '{}'::jsonb,
    'eta_snippets', '{}'::jsonb, 'undo_buffer', null,
    'next_order_id', 1, 'next_action_id', 1, 'next_snippet_id', 1,
    'claude_disabled', false, 'initialized', true
  );
$$;

-- ----------------------------------------------------------------------------
-- load_state(): return the active period's working document. Bootstraps an
-- active period + empty doc if none exists. Adds period_id for convenience.
-- ----------------------------------------------------------------------------
create or replace function concierge.load_state()
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_doc jsonb;
begin
  if v_period is null then
    insert into concierge.operating_periods (label, status)
    values (to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'), 'active')
    returning id into v_period;
    insert into concierge.wallet (period_id, cash, pay) values (v_period, 0, 0)
      on conflict (period_id) do nothing;
  end if;

  select doc into v_doc from concierge.state_doc where period_id = v_period;
  if v_doc is null then
    v_doc := concierge.empty_state();
    insert into concierge.state_doc (period_id, doc) values (v_period, v_doc)
      on conflict (period_id) do nothing;
  end if;

  return v_doc || jsonb_build_object('__period_id', v_period);
end $$;

-- ----------------------------------------------------------------------------
-- save_state(p_state, p_events, p_actor): persist the working doc, append the
-- events the bot collected this turn, and re-materialize normalized tables.
-- One transaction (function body is atomic).
-- ----------------------------------------------------------------------------
create or replace function concierge.save_state(p_state jsonb, p_events jsonb, p_actor bigint)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  ev jsonb;
  v_clean jsonb;
begin
  if v_period is null then raise exception 'save_state: no active period'; end if;

  -- strip transient keys before storing the document
  v_clean := (p_state - '__events') - '__period_id' - '__actor';

  insert into concierge.state_doc (period_id, doc, updated_at)
  values (v_period, v_clean, now())
  on conflict (period_id) do update set doc = excluded.doc, updated_at = now();

  -- append-only audit: write each collected event
  if p_events is not null and jsonb_typeof(p_events) = 'array' then
    for ev in select * from jsonb_array_elements(p_events) loop
      insert into concierge.events
        (period_id, actor, entity_type, entity_id, action, before_val, after_val, metadata)
      values (
        v_period,
        coalesce((ev->>'actor')::bigint, p_actor),
        coalesce(ev->>'entity_type', 'misc'),
        ev->>'entity_id',
        coalesce(ev->>'action', 'event'),
        ev->'before', ev->'after',
        coalesce(ev->'metadata', '{}'::jsonb)
      );
    end loop;
  end if;

  perform concierge.materialize(v_period, v_clean);
  return jsonb_build_object('ok', true, 'period_id', v_period);
end $$;

-- ----------------------------------------------------------------------------
-- materialize(period, doc): rebuild the normalized accounting tables for a
-- period from the working document. Best-effort projection for export/query;
-- the bot never reads these back. Idempotent (full replace of period rows).
-- ----------------------------------------------------------------------------
create or replace function concierge.materialize(p_period bigint, p_doc jsonb)
returns void language plpgsql as $$
declare
  o jsonb; it jsonb; nm text; rec jsonb; fo jsonb; ph jsonb; pa jsonb;
  v_oid bigint; v_front_id bigint;
begin
  -- wipe period operational rows (children first)
  delete from concierge.front_payments fp using concierge.fronts f
    where fp.front_id = f.id and f.period_id = p_period;
  delete from concierge.order_items oi using concierge.orders ord
    where oi.order_id = ord.id and ord.period_id = p_period;
  delete from concierge.fronts        where period_id = p_period;
  delete from concierge.orders        where period_id = p_period;
  delete from concierge.clients       where period_id = p_period;
  delete from concierge.inventory     where period_id = p_period;
  delete from concierge.pending_actions where period_id = p_period;

  -- wallet
  update concierge.wallet
     set cash = coalesce((p_doc#>>'{wallet,cash}')::int, 0),
         pay  = coalesce((p_doc#>>'{wallet,pay}')::int, 0),
         updated_at = now()
   where period_id = p_period;

  -- inventory map {product: qty}
  for nm, rec in select key, value from jsonb_each(coalesce(p_doc->'inventory','{}'::jsonb)) loop
    insert into concierge.inventory (period_id, product, qty, updated_at)
    values (p_period, nm, coalesce(rec::text::int,0), now())
    on conflict (period_id, product) do update set qty = excluded.qty, updated_at = now();
  end loop;

  -- clients map {name: {orders:[], total_spent, first_seen, last_seen}}
  for nm, rec in select key, value from jsonb_each(coalesce(p_doc->'clients','{}'::jsonb)) loop
    insert into concierge.clients (period_id, name, total_spent, first_seen, last_seen)
    values (p_period, nm, coalesce((rec->>'total_spent')::int,0),
            to_timestamp(coalesce((rec->>'first_seen')::bigint, extract(epoch from now())::bigint)),
            to_timestamp(coalesce((rec->>'last_seen')::bigint, extract(epoch from now())::bigint)))
    on conflict (period_id, name) do update
      set total_spent = excluded.total_spent, last_seen = excluded.last_seen;
  end loop;

  -- orders: open (doc.orders), voided (doc.voids), pending (doc.pending values)
  for o in select * from jsonb_array_elements(coalesce(p_doc->'orders','[]'::jsonb)) loop
    v_oid := concierge._insert_order(p_period, o, 'open');
  end loop;
  for o in select * from jsonb_array_elements(coalesce(p_doc->'voids','[]'::jsonb)) loop
    v_oid := concierge._insert_order(p_period, o, 'voided');
  end loop;
  for nm, o in select key, value from jsonb_each(coalesce(p_doc->'pending','{}'::jsonb)) loop
    v_oid := concierge._insert_order(p_period, o, 'pending');
  end loop;

  -- fronts: doc.front {name: {total, orders:[{id, amount, paid_history:[{amount,ts}]}]}}
  for nm, rec in select key, value from jsonb_each(coalesce(p_doc->'front','{}'::jsonb)) loop
    for fo in select * from jsonb_array_elements(coalesce(rec->'orders','[]'::jsonb)) loop
      insert into concierge.fronts (period_id, name, order_human_id, amount, created_at)
      values (p_period, nm, fo->>'id', coalesce((fo->>'amount')::int,0),
              to_timestamp(coalesce((fo->>'ts')::bigint, extract(epoch from now())::bigint)))
      on conflict (period_id, name, order_human_id) do update set amount = excluded.amount
      returning id into v_front_id;
      for ph in select * from jsonb_array_elements(coalesce(fo->'paid_history','[]'::jsonb)) loop
        insert into concierge.front_payments (front_id, amount, ts)
        values (v_front_id, coalesce((ph->>'amount')::int,0),
                to_timestamp(coalesce((ph->>'ts')::bigint, extract(epoch from now())::bigint)));
      end loop;
    end loop;
  end loop;

  -- pending_actions map {token: {...}}
  for nm, pa in select key, value from jsonb_each(coalesce(p_doc->'pending_actions','{}'::jsonb)) loop
    insert into concierge.pending_actions (token, period_id, type, status, payload, staged_by, staged_at, expires_at)
    values (nm, p_period, coalesce(pa->>'type','unknown'), 'staged', pa,
            (pa->>'staged_by')::bigint,
            to_timestamp(coalesce((pa->>'staged_at')::bigint, extract(epoch from now())::bigint)),
            to_timestamp(coalesce((pa->>'staged_at')::bigint, extract(epoch from now())::bigint)) + interval '30 minutes')
    on conflict (token) do update set payload = excluded.payload, status = 'staged';
  end loop;

  -- counters from next_*_id (value = next-1 so next_counter() yields next id)
  insert into concierge.counters (period_id, name, value) values
    (p_period, 'order',   greatest(0, coalesce((p_doc->>'next_order_id')::int,1)  - 1)),
    (p_period, 'action',  greatest(0, coalesce((p_doc->>'next_action_id')::int,1) - 1)),
    (p_period, 'snippet', greatest(0, coalesce((p_doc->>'next_snippet_id')::int,1)- 1))
  on conflict (period_id, name) do update set value = excluded.value;
end $$;

-- helper: insert one order (+items) from a legacy order json, return id
create or replace function concierge._insert_order(p_period bigint, o jsonb, p_status concierge.order_status)
returns bigint language plpgsql as $$
declare v_oid bigint; it jsonb;
begin
  insert into concierge.orders
    (period_id, human_id, status, name, price, time_label, address, front_amount,
     intake_mode, entered_by, entered_at, approved_by, approved_at, voided_by, voided_at, forgiven)
  values (
    p_period,
    coalesce(o->>'id', o->>'token'),
    p_status,
    lower(coalesce(o->>'name','')),
    nullif(o->>'price','')::int,
    o->>'time',
    lower(coalesce(o->>'address','')),
    coalesce((o->>'front_amount')::int, 0),
    o->>'intake_mode',
    (o->>'entered_by')::bigint,
    to_timestamp(coalesce((o->>'entered_at')::bigint, extract(epoch from now())::bigint)),
    (o->>'approved_by')::bigint,
    case when o ? 'approved_at' then to_timestamp((o->>'approved_at')::bigint) end,
    (o->>'voided_by')::bigint,
    case when o ? 'voided_at' then to_timestamp((o->>'voided_at')::bigint) end,
    coalesce((o->>'forgiven')::boolean, false)
  )
  on conflict (period_id, human_id) do update
    set status = excluded.status, name = excluded.name, price = excluded.price,
        time_label = excluded.time_label, address = excluded.address,
        front_amount = excluded.front_amount
  returning id into v_oid;

  delete from concierge.order_items where order_id = v_oid;
  for it in select * from jsonb_array_elements(coalesce(o->'items','[]'::jsonb)) loop
    insert into concierge.order_items (order_id, product, qty)
    values (v_oid, it->>'product', coalesce((it->>'qty')::int, 1));
  end loop;
  return v_oid;
end $$;
