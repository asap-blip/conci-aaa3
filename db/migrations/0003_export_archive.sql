-- ============================================================================
-- 0003_export_archive.sql
-- Export views + safe, explicit period closeout / archive.
-- ----------------------------------------------------------------------------
-- Operator's accounting is MANUAL and happens daily/weekly outside the bot.
-- The flow is:
--   1. EXPORT  — pull a period's events + operational rows (the views below /
--                concierge.export_period(p)) to a file on the VM / removable
--                storage, encrypt/offload as desired.
--   2. RECONCILE — done by a human against the export.
--   3. CLOSE   — concierge.close_period() snapshots headline totals, marks the
--                period 'closed', and opens a fresh 'active' period. Live
--                operational rows of the closed period are RETAINED until you
--                explicitly archive+purge (step 4), so close is reversible-ish
--                and never destroys data on its own.
--   4. ARCHIVE+PURGE — concierge.archive_closed_period() copies the closed
--                period's rows into concierge.archive_* tables (immutable) and
--                deletes them from the live operational tables, reclaiming space.
--                The append-only events stay queryable via the archive too.
--
-- Nothing here deletes anything implicitly. Clearing is always an explicit call.
-- ============================================================================

set search_path = concierge, public;

-- ----------------------------------------------------------------------------
-- Export views — flat, accountant-friendly projections for the ACTIVE period.
-- Pass through to export_period() for an arbitrary period.
-- ----------------------------------------------------------------------------

-- Orders flattened with item summary + computed paid/credit split.
create or replace view concierge.v_orders_export as
select
  o.period_id,
  o.human_id,
  o.status,
  o.name,
  o.price,
  o.front_amount,
  coalesce(o.price,0) - coalesce(o.front_amount,0) as cash_portion,
  o.time_label,
  o.address,
  o.intake_mode,
  o.entered_at,
  o.approved_at,
  o.voided_at,
  o.forgiven,
  coalesce((
    select string_agg(oi.qty || 'x' || oi.product, ' ' order by oi.id)
    from concierge.order_items oi where oi.order_id = o.id
  ), '') as items
from concierge.orders o;

-- Daily revenue/product rollup (per period, per Toronto day).
create or replace view concierge.v_daily_rollup as
select
  o.period_id,
  (o.approved_at at time zone 'America/Toronto')::date as day,
  count(*) filter (where o.status = 'open')            as open_jobs,
  coalesce(sum(o.price) filter (where o.status='open'),0) as revenue,
  coalesce(sum(o.front_amount) filter (where o.status='open'),0) as fronted
from concierge.orders o
where o.approved_at is not null
group by o.period_id, (o.approved_at at time zone 'America/Toronto')::date;

-- Outstanding fronts per client (current).
create or replace view concierge.v_fronts_export as
select f.period_id, f.name, f.order_human_id, f.amount, f.created_at
from concierge.fronts f
where f.amount > 0;

-- Period headline totals (the reconciliation summary).
create or replace function concierge.period_totals(p_period bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'period_id', p_period,
    'wallet', (select to_jsonb(w) from concierge.wallet w where w.period_id = p_period),
    'open_orders', (select count(*) from concierge.orders where period_id = p_period and status = 'open'),
    'pending_orders', (select count(*) from concierge.orders where period_id = p_period and status = 'pending'),
    'voided_orders', (select count(*) from concierge.orders where period_id = p_period and status = 'voided'),
    'revenue', (select coalesce(sum(price),0) from concierge.orders where period_id = p_period and status = 'open'),
    'front_out', (select coalesce(sum(amount),0) from concierge.fronts where period_id = p_period),
    'clients', (select count(*) from concierge.clients where period_id = p_period),
    'events', (select count(*) from concierge.events where period_id = p_period),
    'inventory', (select coalesce(jsonb_object_agg(product, qty),'{}'::jsonb)
                  from concierge.inventory where period_id = p_period)
  );
$$;

-- ----------------------------------------------------------------------------
-- export_period: one call returns everything needed for an external accounting
-- export of a period (events + flat orders + fronts + totals). The n8n backup
-- job (or a cron / manual psql) writes this jsonb to a file.
-- ----------------------------------------------------------------------------
create or replace function concierge.export_period(p_period bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'period',   (select to_jsonb(p) from concierge.operating_periods p where p.id = p_period),
    'totals',   concierge.period_totals(p_period),
    'orders',   coalesce((select jsonb_agg(to_jsonb(v) order by v.human_id) from concierge.v_orders_export v where v.period_id = p_period), '[]'::jsonb),
    'fronts',   coalesce((select jsonb_agg(to_jsonb(v)) from concierge.v_fronts_export v where v.period_id = p_period), '[]'::jsonb),
    'clients',  coalesce((select jsonb_agg(to_jsonb(c)) from concierge.clients c where c.period_id = p_period), '[]'::jsonb),
    'events',   coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from concierge.events e where e.period_id = p_period), '[]'::jsonb),
    'exported_at', now()
  );
$$;

-- ----------------------------------------------------------------------------
-- Archive tables (immutable copies; survive purge of live operational rows).
-- ----------------------------------------------------------------------------
create table if not exists concierge.archive_periods   (like concierge.operating_periods including all);
create table if not exists concierge.archive_orders     (like concierge.orders including all);
create table if not exists concierge.archive_order_items(like concierge.order_items including all);
create table if not exists concierge.archive_fronts     (like concierge.fronts including all);
create table if not exists concierge.archive_front_payments (like concierge.front_payments including all);
create table if not exists concierge.archive_clients    (like concierge.clients including all);
create table if not exists concierge.archive_wallet     (like concierge.wallet including all);
create table if not exists concierge.archive_inventory  (like concierge.inventory including all);
create table if not exists concierge.archive_events     (like concierge.events including all);

-- ----------------------------------------------------------------------------
-- close_period: capture totals, mark closed, open a fresh active period.
-- Does NOT delete operational rows. Returns the close summary + new period id.
-- ----------------------------------------------------------------------------
create or replace function concierge.close_period(p_actor bigint, p_new_label text default null)
returns jsonb language plpgsql as $$
declare
  v_old bigint := concierge.active_period();
  v_summary jsonb;
  v_new bigint;
  v_label text;
begin
  if v_old is null then return jsonb_build_object('ok', false, 'error', 'no_active_period'); end if;
  v_summary := concierge.period_totals(v_old);

  update concierge.operating_periods
     set status = 'closed', closed_at = now(), closed_by = p_actor, close_summary = v_summary
   where id = v_old;

  v_label := coalesce(p_new_label, to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'));
  insert into concierge.operating_periods (label, status, opened_by)
  values (v_label, 'active', p_actor)
  returning id into v_new;

  insert into concierge.wallet (period_id, cash, pay) values (v_new, 0, 0)
    on conflict (period_id) do nothing;
  insert into concierge.counters (period_id, name, value) values
    (v_new,'order',0),(v_new,'action',0),(v_new,'snippet',0)
    on conflict (period_id, name) do nothing;

  perform concierge.log_event(v_old, p_actor, 'period', v_old::text, 'period_closed', v_summary, null,
                              jsonb_build_object('new_period', v_new));
  return jsonb_build_object('ok', true, 'closed_period', v_old, 'summary', v_summary, 'new_period', v_new);
end $$;

-- ----------------------------------------------------------------------------
-- archive_closed_period: copy a CLOSED period's rows into archive_* tables,
-- then delete them from live operational tables. Explicit, irreversible-ish
-- (archive copy remains). Guards: period must be 'closed' and not the active one.
-- ----------------------------------------------------------------------------
create or replace function concierge.archive_closed_period(p_period bigint)
returns jsonb language plpgsql as $$
declare
  v_status concierge.period_status;
begin
  select status into v_status from concierge.operating_periods where id = p_period;
  if v_status is null then return jsonb_build_object('ok', false, 'error', 'no_such_period'); end if;
  if v_status <> 'closed' then return jsonb_build_object('ok', false, 'error', 'period_not_closed'); end if;

  -- copy (idempotent-ish: skip rows already archived by id)
  insert into concierge.archive_events       select * from concierge.events       where period_id = p_period
    on conflict do nothing;
  insert into concierge.archive_order_items  select oi.* from concierge.order_items oi
    join concierge.orders o on o.id = oi.order_id where o.period_id = p_period on conflict do nothing;
  insert into concierge.archive_front_payments select fp.* from concierge.front_payments fp
    join concierge.fronts f on f.id = fp.front_id where f.period_id = p_period on conflict do nothing;
  insert into concierge.archive_orders       select * from concierge.orders       where period_id = p_period on conflict do nothing;
  insert into concierge.archive_fronts       select * from concierge.fronts       where period_id = p_period on conflict do nothing;
  insert into concierge.archive_clients      select * from concierge.clients      where period_id = p_period on conflict do nothing;
  insert into concierge.archive_wallet       select * from concierge.wallet       where period_id = p_period on conflict do nothing;
  insert into concierge.archive_inventory    select * from concierge.inventory    where period_id = p_period on conflict do nothing;
  insert into concierge.archive_periods      select * from concierge.operating_periods where id = p_period on conflict do nothing;

  -- purge live rows (children first; order_items/front_payments cascade via FK
  -- but we delete explicitly to be safe across FK settings)
  delete from concierge.front_payments fp using concierge.fronts f
    where fp.front_id = f.id and f.period_id = p_period;
  delete from concierge.order_items oi using concierge.orders o
    where oi.order_id = o.id and o.period_id = p_period;
  delete from concierge.fronts        where period_id = p_period;
  delete from concierge.orders        where period_id = p_period;
  delete from concierge.clients       where period_id = p_period;
  delete from concierge.inventory     where period_id = p_period;
  delete from concierge.eta_snippets  where period_id = p_period;
  delete from concierge.front_prompts where period_id = p_period;
  delete from concierge.pending_actions where period_id = p_period;
  delete from concierge.undo_buffer   where period_id = p_period;
  delete from concierge.counters      where period_id = p_period;
  delete from concierge.wallet        where period_id = p_period;
  -- keep the operating_periods row (now also in archive) for reference; mark it
  update concierge.operating_periods set notes = coalesce(notes,'') || ' [archived]' where id = p_period;

  return jsonb_build_object('ok', true, 'archived_period', p_period);
end $$;
