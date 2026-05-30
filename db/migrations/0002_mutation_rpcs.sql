-- ============================================================================
-- 0002_mutation_rpcs.sql
-- Deterministic accounting mutations + durable pending-action handling.
-- ----------------------------------------------------------------------------
-- All money/state transitions live here, in ONE place, as small explicit
-- functions. Each function:
--   * runs in a single transaction (function body is atomic),
--   * mutates the operational tables for the ACTIVE period,
--   * appends exactly one (or a few) rows to concierge.events,
--   * returns a jsonb result the n8n layer turns into a Telegram card.
--
-- The n8n Code nodes do NOT do arithmetic on money. They format input, call
-- one RPC, and render the result. This keeps the bot lean and keeps accounting
-- boring and auditable.
--
-- Constants (kept here so they live next to the logic that uses them):
--   PAY_PER_ORDER = 20   -- accrual added to wallet.pay per committed order
--   ACTION_TTL    = 30 min
--   UNDO_TTL      = 5 min
-- ============================================================================

set search_path = concierge, public;

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------

create or replace function concierge.active_period()
returns bigint language sql stable as $$
  select id from concierge.operating_periods where status = 'active' limit 1;
$$;

create or replace function concierge.pay_per_order()
returns integer language sql immutable as $$ select 20 $$;

-- next value of a per-period counter (ord-/act-/snip-)
create or replace function concierge.next_counter(p_period bigint, p_name text)
returns integer language plpgsql as $$
declare v integer;
begin
  insert into concierge.counters (period_id, name, value)
  values (p_period, p_name, 1)
  on conflict (period_id, name) do update set value = concierge.counters.value + 1
  returning value into v;
  return v;
end $$;

-- append one event (single choke point for the audit log)
create or replace function concierge.log_event(
  p_period bigint, p_actor bigint, p_entity_type text, p_entity_id text,
  p_action text, p_before jsonb, p_after jsonb, p_meta jsonb default '{}'::jsonb
) returns void language sql as $$
  insert into concierge.events
    (period_id, actor, entity_type, entity_id, action, before_val, after_val, metadata)
  values
    (p_period, p_actor, p_entity_type, p_entity_id, p_action, p_before, p_after, coalesce(p_meta,'{}'::jsonb));
$$;

-- assemble an order as jsonb (items inlined) for event snapshots / results
create or replace function concierge.order_json(p_order_id bigint)
returns jsonb language sql stable as $$
  select to_jsonb(o) || jsonb_build_object(
    'items',
    coalesce((select jsonb_agg(jsonb_build_object('product', oi.product, 'qty', oi.qty) order by oi.id)
              from concierge.order_items oi where oi.order_id = o.id), '[]'::jsonb)
  )
  from concierge.orders o where o.id = p_order_id;
$$;

-- ----------------------------------------------------------------------------
-- NEW ORDER intake (stage a pending order)
-- p_items: jsonb array of {product, qty}
-- Returns the staged order json (with human_id) for the confirm card.
-- ----------------------------------------------------------------------------
create or replace function concierge.new_order(
  p_actor bigint, p_name text, p_items jsonb, p_price integer,
  p_time text, p_address text, p_intake_mode text
) returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_n      integer;
  v_human  text;
  v_oid    bigint;
  it       jsonb;
begin
  if v_period is null then raise exception 'no active operating period'; end if;
  v_n := concierge.next_counter(v_period, 'order');
  v_human := 'ord-' || v_n;

  insert into concierge.orders
    (period_id, human_id, status, name, price, time_label, address, intake_mode, entered_by)
  values
    (v_period, v_human, 'pending', lower(p_name), p_price, nullif(p_time,''), lower(p_address),
     coalesce(p_intake_mode,'freeform'), p_actor)
  returning id into v_oid;

  for it in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    insert into concierge.order_items (order_id, product, qty)
    values (v_oid, it->>'product', (it->>'qty')::int);
  end loop;

  perform concierge.log_event(v_period, p_actor, 'order', v_human, 'order_created',
                              null, concierge.order_json(v_oid),
                              jsonb_build_object('intake_mode', p_intake_mode));
  return concierge.order_json(v_oid);
end $$;

-- ----------------------------------------------------------------------------
-- APPROVE order (pending -> open). Optionally arm a front prompt (from 🟧).
-- Decrement inventory, add price to cash, accrue pay, update client, set undo.
-- Idempotent: if the order is already open, returns its json without re-applying.
-- ----------------------------------------------------------------------------
create or replace function concierge.approve_order(
  p_actor bigint, p_human text, p_arm_front boolean default false, p_message_id bigint default null
) returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_o concierge.orders%rowtype;
  it concierge.order_items%rowtype;
begin
  select * into v_o from concierge.orders
    where period_id = v_period and human_id = p_human;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'human_id', p_human); end if;
  if v_o.status = 'open' then
    return jsonb_build_object('ok', true, 'already', true, 'order', concierge.order_json(v_o.id));
  end if;
  if v_o.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'bad_status', 'status', v_o.status);
  end if;

  -- inventory down
  for it in select * from concierge.order_items where order_id = v_o.id loop
    insert into concierge.inventory (period_id, product, qty, updated_at)
    values (v_period, it.product, -it.qty, now())
    on conflict (period_id, product) do update
      set qty = concierge.inventory.qty - it.qty, updated_at = now();
  end loop;

  -- cash up (if priced) + pay accrual
  update concierge.wallet
     set cash = cash + coalesce(v_o.price, 0),
         pay  = pay + concierge.pay_per_order(),
         updated_at = now()
   where period_id = v_period;

  -- client
  insert into concierge.clients (period_id, name, total_spent, first_seen, last_seen)
  values (v_period, v_o.name, coalesce(v_o.price,0), now(), now())
  on conflict (period_id, name) do update
    set total_spent = concierge.clients.total_spent + coalesce(v_o.price,0),
        last_seen = now();

  update concierge.orders
     set status = 'open', approved_by = p_actor, approved_at = now()
   where id = v_o.id;

  -- undo buffer (single per period)
  insert into concierge.undo_buffer (period_id, type, payload, ts)
  values (v_period, 'order_commit',
          jsonb_build_object('human_id', v_o.human_id, 'order', concierge.order_json(v_o.id)), now())
  on conflict (period_id) do update set type = excluded.type, payload = excluded.payload, ts = excluded.ts;

  -- optional front prompt arming (durable)
  if p_arm_front and p_message_id is not null then
    insert into concierge.front_prompts (message_id, period_id, order_human_id, name, price, expires_at)
    values (p_message_id, v_period, v_o.human_id, v_o.name, v_o.price, now() + interval '30 minutes')
    on conflict (message_id) do update
      set order_human_id = excluded.order_human_id, name = excluded.name,
          price = excluded.price, expires_at = excluded.expires_at;
  end if;

  perform concierge.log_event(v_period, p_actor, 'order', v_o.human_id,
    case when p_arm_front then 'order_approved_front_pending' else 'order_approved' end,
    null, concierge.order_json(v_o.id), '{}'::jsonb);

  return jsonb_build_object('ok', true, 'order', concierge.order_json(v_o.id), 'armed_front', p_arm_front);
end $$;

-- ----------------------------------------------------------------------------
-- CANCEL pending order
-- ----------------------------------------------------------------------------
create or replace function concierge.cancel_pending(p_actor bigint, p_human text)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_o concierge.orders%rowtype;
begin
  select * into v_o from concierge.orders where period_id = v_period and human_id = p_human;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_o.status <> 'pending' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update concierge.orders set status = 'cancelled' where id = v_o.id;
  perform concierge.log_event(v_period, p_actor, 'order', p_human, 'order_cancelled', null, null, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'human_id', p_human);
end $$;

-- ----------------------------------------------------------------------------
-- VOID an open order (reverse inventory, cash, pay, fronts, client spend)
-- ----------------------------------------------------------------------------
create or replace function concierge.void_order(p_actor bigint, p_human text)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_o concierge.orders%rowtype;
  it concierge.order_items%rowtype;
  v_front concierge.fronts%rowtype;
  v_paid_portion integer;
begin
  select * into v_o from concierge.orders where period_id = v_period and human_id = p_human;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_o.status <> 'open' then return jsonb_build_object('ok', false, 'error', 'not_open'); end if;

  -- restock
  for it in select * from concierge.order_items where order_id = v_o.id loop
    update concierge.inventory set qty = qty + it.qty, updated_at = now()
      where period_id = v_period and product = it.product;
  end loop;

  -- cash down, pay down by accrual
  update concierge.wallet
     set cash = cash - coalesce(v_o.price,0),
         pay  = greatest(0, pay - concierge.pay_per_order()),
         updated_at = now()
   where period_id = v_period;

  -- reverse any front for this order
  select * into v_front from concierge.fronts
    where period_id = v_period and name = v_o.name and order_human_id = p_human;
  if found then
    update concierge.fronts set amount = 0 where id = v_front.id; -- balance cleared
    delete from concierge.fronts where id = v_front.id;
  end if;

  -- client spend reversal = paid portion (price - front_amount)
  v_paid_portion := coalesce(v_o.price,0) - coalesce(v_o.front_amount,0);
  update concierge.clients
     set total_spent = greatest(0, total_spent - v_paid_portion)
   where period_id = v_period and name = v_o.name;

  update concierge.orders
     set status = 'voided', voided_by = p_actor, voided_at = now()
   where id = v_o.id;

  perform concierge.log_event(v_period, p_actor, 'order', p_human, 'order_voided',
    concierge.order_json(v_o.id), null,
    jsonb_build_object('front_reversed', coalesce(v_o.front_amount,0)));
  return jsonb_build_object('ok', true, 'order', concierge.order_json(v_o.id));
end $$;

-- ----------------------------------------------------------------------------
-- EDIT an order (apply a parsed diff to a pending or open order)
-- p_changes: jsonb with any of {name, items, price, time, address}; null/absent
-- keys are left unchanged. Re-balances inventory/cash/client for open orders.
-- ----------------------------------------------------------------------------
create or replace function concierge.edit_order(p_actor bigint, p_human text, p_changes jsonb)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_o concierge.orders%rowtype;
  v_before jsonb;
  it jsonb;
  v_old_price integer;
  v_new_price integer;
  v_old_name text;
  v_new_name text;
begin
  select * into v_o from concierge.orders where period_id = v_period and human_id = p_human;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_o.status not in ('pending','open') then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;

  v_before := concierge.order_json(v_o.id);
  v_old_price := coalesce(v_o.price, 0);
  v_old_name  := v_o.name;

  -- For OPEN orders, restock old items first (we re-decrement new items below).
  if v_o.status = 'open' and p_changes ? 'items' and jsonb_typeof(p_changes->'items') = 'array' then
    update concierge.inventory i set qty = i.qty + oi.qty, updated_at = now()
      from concierge.order_items oi
     where oi.order_id = v_o.id and i.period_id = v_period and i.product = oi.product;
  end if;

  -- apply scalar field changes
  if p_changes ? 'name'    and p_changes->>'name'    is not null then v_o.name := lower(p_changes->>'name'); end if;
  if p_changes ? 'price'                                        then v_o.price := nullif(p_changes->>'price','')::int; end if;
  if p_changes ? 'time'                                         then v_o.time_label := nullif(p_changes->>'time',''); end if;
  if p_changes ? 'address' and p_changes->>'address' is not null then v_o.address := lower(p_changes->>'address'); end if;

  update concierge.orders
     set name = v_o.name, price = v_o.price, time_label = v_o.time_label, address = v_o.address
   where id = v_o.id;

  -- replace items if provided
  if p_changes ? 'items' and jsonb_typeof(p_changes->'items') = 'array'
     and jsonb_array_length(p_changes->'items') > 0 then
    delete from concierge.order_items where order_id = v_o.id;
    for it in select * from jsonb_array_elements(p_changes->'items') loop
      insert into concierge.order_items (order_id, product, qty)
      values (v_o.id, it->>'product', (it->>'qty')::int);
    end loop;
    -- re-decrement for open orders
    if v_o.status = 'open' then
      for it in select * from jsonb_array_elements(p_changes->'items') loop
        insert into concierge.inventory (period_id, product, qty, updated_at)
        values (v_period, it->>'product', -((it->>'qty')::int), now())
        on conflict (period_id, product) do update
          set qty = concierge.inventory.qty - (it->>'qty')::int, updated_at = now();
      end loop;
    end if;
  end if;

  -- cash + client re-balance for open orders (price delta / name move)
  if v_o.status = 'open' then
    v_new_price := coalesce(v_o.price, 0);
    v_new_name  := v_o.name;
    update concierge.wallet set cash = cash + (v_new_price - v_old_price), updated_at = now()
      where period_id = v_period;
    if v_old_name = v_new_name then
      update concierge.clients set total_spent = greatest(0, total_spent + (v_new_price - v_old_price)), last_seen = now()
        where period_id = v_period and name = v_new_name;
    else
      update concierge.clients set total_spent = greatest(0, total_spent - v_old_price)
        where period_id = v_period and name = v_old_name;
      insert into concierge.clients (period_id, name, total_spent, first_seen, last_seen)
      values (v_period, v_new_name, v_new_price, now(), now())
      on conflict (period_id, name) do update
        set total_spent = concierge.clients.total_spent + v_new_price, last_seen = now();
    end if;
  end if;

  perform concierge.log_event(v_period, p_actor, 'order', p_human, 'order_edited',
                              v_before, concierge.order_json(v_o.id), '{}'::jsonb);
  return jsonb_build_object('ok', true, 'order', concierge.order_json(v_o.id));
end $$;

-- ----------------------------------------------------------------------------
-- SET FRONT on an order (mark part of an order as client credit)
-- ----------------------------------------------------------------------------
create or replace function concierge.set_front(p_actor bigint, p_human text, p_amount integer)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_o concierge.orders%rowtype;
  v_old integer;
  v_delta integer;
begin
  select * into v_o from concierge.orders where period_id = v_period and human_id = p_human;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_o.price is null then return jsonb_build_object('ok', false, 'error', 'no_price'); end if;
  if p_amount < 0 or p_amount > v_o.price then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;

  v_old := coalesce(v_o.front_amount, 0);
  v_delta := p_amount - v_old;

  update concierge.orders set front_amount = p_amount where id = v_o.id;

  if p_amount = 0 then
    delete from concierge.fronts where period_id = v_period and name = v_o.name and order_human_id = p_human;
  else
    insert into concierge.fronts (period_id, name, order_human_id, amount)
    values (v_period, v_o.name, p_human, p_amount)
    on conflict (period_id, name, order_human_id) do update set amount = excluded.amount;
  end if;

  -- fronted money is not "spent" by the client yet: reduce client spend by delta
  update concierge.clients set total_spent = greatest(0, total_spent - v_delta)
    where period_id = v_period and name = v_o.name;

  perform concierge.log_event(v_period, p_actor, 'front', p_human, 'front_set',
    jsonb_build_object('amount', v_old), jsonb_build_object('amount', p_amount),
    jsonb_build_object('name', v_o.name));
  return jsonb_build_object('ok', true, 'human_id', p_human, 'name', v_o.name, 'new_front', p_amount,
                            'front_total', (select coalesce(sum(amount),0) from concierge.fronts
                                            where period_id = v_period and name = v_o.name));
end $$;

-- ----------------------------------------------------------------------------
-- MARK PAID (allocate a payment across a client's fronts, FIFO)
-- ----------------------------------------------------------------------------
create or replace function concierge.mark_paid(p_actor bigint, p_name text, p_amount integer)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_name text := lower(p_name);
  v_remaining integer;
  v_applied integer := 0;
  f concierge.fronts%rowtype;
  v_apply integer;
begin
  if not exists (select 1 from concierge.fronts where period_id = v_period and name = v_name and amount > 0) then
    return jsonb_build_object('ok', false, 'error', 'no_fronts', 'name', v_name);
  end if;
  v_remaining := p_amount;
  for f in select * from concierge.fronts
            where period_id = v_period and name = v_name and amount > 0
            order by created_at, id loop
    exit when v_remaining <= 0;
    v_apply := least(v_remaining, f.amount);
    insert into concierge.front_payments (front_id, amount) values (f.id, v_apply);
    update concierge.fronts set amount = amount - v_apply where id = f.id;
    update concierge.orders set front_amount = greatest(0, front_amount - v_apply)
      where period_id = v_period and human_id = f.order_human_id;
    v_remaining := v_remaining - v_apply;
    v_applied := v_applied + v_apply;
  end loop;
  delete from concierge.fronts where period_id = v_period and name = v_name and amount = 0;

  update concierge.clients set total_spent = total_spent + v_applied, last_seen = now()
    where period_id = v_period and name = v_name;

  perform concierge.log_event(v_period, p_actor, 'front', v_name, 'payment_applied',
    null, jsonb_build_object('applied', v_applied),
    jsonb_build_object('requested', p_amount));
  return jsonb_build_object('ok', true, 'name', v_name, 'applied', v_applied,
                            'front_total', (select coalesce(sum(amount),0) from concierge.fronts
                                            where period_id = v_period and name = v_name));
end $$;

-- ----------------------------------------------------------------------------
-- FORGIVE a front (write off a fronted order; cash unchanged)
-- ----------------------------------------------------------------------------
create or replace function concierge.forgive_front(p_actor bigint, p_name text, p_human text)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_name text := lower(p_name);
  f concierge.fronts%rowtype;
begin
  select * into f from concierge.fronts
    where period_id = v_period and name = v_name and order_human_id = p_human;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_front'); end if;

  delete from concierge.fronts where id = f.id;
  update concierge.orders
     set forgiven = true, forgiven_by = p_actor, forgiven_at = now(), front_amount = 0
   where period_id = v_period and human_id = p_human;

  perform concierge.log_event(v_period, p_actor, 'front', p_human, 'front_forgiven',
    jsonb_build_object('amount', f.amount), null, jsonb_build_object('name', v_name));
  return jsonb_build_object('ok', true, 'name', v_name, 'human_id', p_human, 'amount', f.amount,
                            'front_total', (select coalesce(sum(amount),0) from concierge.fronts
                                            where period_id = v_period and name = v_name));
end $$;

-- ----------------------------------------------------------------------------
-- WALLET cash add / sub / set / reset
-- p_op: 'add' | 'sub' | 'set' | 'reset'
-- ----------------------------------------------------------------------------
create or replace function concierge.wallet_cash(p_actor bigint, p_op text, p_amount integer default 0)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_before integer;
  v_after integer;
begin
  select cash into v_before from concierge.wallet where period_id = v_period;
  v_after := case p_op
    when 'add'   then v_before + p_amount
    when 'sub'   then v_before - p_amount
    when 'set'   then p_amount
    when 'reset' then 0
    else v_before end;
  update concierge.wallet set cash = v_after, updated_at = now() where period_id = v_period;
  perform concierge.log_event(v_period, p_actor, 'wallet', 'cash', 'wallet_' || p_op,
    jsonb_build_object('cash', v_before), jsonb_build_object('cash', v_after), '{}'::jsonb);
  return jsonb_build_object('ok', true, 'cash', v_after);
end $$;

-- WALLET pay add / sub / set / reset (pay can never go negative)
create or replace function concierge.wallet_pay(p_actor bigint, p_op text, p_amount integer default 0)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_before integer;
  v_after integer;
begin
  select pay into v_before from concierge.wallet where period_id = v_period;
  v_after := case p_op
    when 'add'   then v_before + p_amount
    when 'sub'   then greatest(0, v_before - p_amount)
    when 'set'   then greatest(0, p_amount)
    when 'reset' then 0
    else v_before end;
  update concierge.wallet set pay = v_after, updated_at = now() where period_id = v_period;
  perform concierge.log_event(v_period, p_actor, 'pay', 'pay', 'pay_' || p_op,
    jsonb_build_object('pay', v_before), jsonb_build_object('pay', v_after), '{}'::jsonb);
  return jsonb_build_object('ok', true, 'pay', v_after);
end $$;

-- ----------------------------------------------------------------------------
-- INVENTORY add / set / reset
-- p_changes: jsonb object {product: qty, ...}; for reset_all pass null.
-- p_op: 'add' | 'set' | 'reset_one' | 'reset_all'
-- ----------------------------------------------------------------------------
create or replace function concierge.inventory_adjust(p_actor bigint, p_op text, p_changes jsonb)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  k text;
  v integer;
begin
  if p_op = 'reset_all' then
    update concierge.inventory set qty = 0, updated_at = now() where period_id = v_period;
  elsif p_op = 'reset_one' then
    for k in select jsonb_object_keys(p_changes) loop
      update concierge.inventory set qty = 0, updated_at = now() where period_id = v_period and product = k;
    end loop;
  else
    for k, v in select key, value::int from jsonb_each_text(p_changes) loop
      insert into concierge.inventory (period_id, product, qty, updated_at)
      values (v_period, k, case when p_op='add' then v else v end, now())
      on conflict (period_id, product) do update
        set qty = case when p_op='add' then concierge.inventory.qty + v else v end,
            updated_at = now();
    end loop;
  end if;
  perform concierge.log_event(v_period, p_actor, 'inventory', null, 'inventory_' || p_op,
                              null, p_changes, '{}'::jsonb);
  return jsonb_build_object('ok', true,
    'inventory', (select coalesce(jsonb_object_agg(product, qty), '{}'::jsonb)
                  from concierge.inventory where period_id = v_period));
end $$;

-- ----------------------------------------------------------------------------
-- UNDO last commit (within UNDO_TTL = 5 min)
-- ----------------------------------------------------------------------------
create or replace function concierge.undo_last(p_actor bigint)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  u concierge.undo_buffer%rowtype;
  v_order jsonb;
  v_human text;
begin
  select * into u from concierge.undo_buffer where period_id = v_period;
  if not found then return jsonb_build_object('ok', false, 'error', 'nothing'); end if;
  if now() - u.ts > interval '5 minutes' then
    delete from concierge.undo_buffer where period_id = v_period;
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;
  if u.type <> 'order_commit' then
    return jsonb_build_object('ok', false, 'error', 'unknown_type');
  end if;
  v_order := u.payload->'order';
  v_human := v_order->>'human_id';
  -- reverse by voiding the open order (reuses void logic, but mark cancelled not voided)
  perform concierge.void_order(p_actor, v_human);
  -- voiding logs order_voided; additionally mark it as undo for the audit trail
  delete from concierge.undo_buffer where period_id = v_period;
  perform concierge.log_event(v_period, p_actor, 'order', v_human, 'undo_applied', v_order, null, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'human_id', v_human);
end $$;

-- ============================================================================
-- DURABLE PENDING ACTIONS (callback safety)
-- ============================================================================

-- Stage a pending action and return its token. TTL = 30 min.
create or replace function concierge.stage_action(
  p_actor bigint, p_type text, p_payload jsonb
) returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_n integer;
  v_token text;
begin
  v_n := concierge.next_counter(v_period, 'action');
  v_token := 'act-' || v_n;
  insert into concierge.pending_actions (token, period_id, type, status, payload, staged_by, expires_at)
  values (v_token, v_period, p_type, 'staged', coalesce(p_payload,'{}'::jsonb), p_actor,
          now() + interval '30 minutes');
  perform concierge.log_event(v_period, p_actor, 'action', v_token, 'action_staged',
                              null, p_payload, jsonb_build_object('type', p_type));
  return jsonb_build_object('ok', true, 'token', v_token);
end $$;

-- Consume a pending action: validate status + expiry, dispatch to the matching
-- mutation, mark consumed, cache the result. Idempotent: a second tap with the
-- same token returns the cached result instead of re-applying.
create or replace function concierge.consume_action(p_actor bigint, p_token text)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  a concierge.pending_actions%rowtype;
  v_res jsonb;
  pl jsonb;
begin
  select * into a from concierge.pending_actions where token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_action'); end if;
  if a.status = 'consumed' then
    return coalesce(a.result, jsonb_build_object('ok', true, 'already', true));
  end if;
  if a.status <> 'staged' then
    return jsonb_build_object('ok', false, 'error', a.status::text);
  end if;
  if now() > a.expires_at then
    update concierge.pending_actions set status = 'expired' where token = p_token;
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;

  pl := a.payload;
  v_res := case a.type
    when 'void'       then concierge.void_order(p_actor, pl->>'order_human_id')
    when 'forgive'    then concierge.forgive_front(p_actor, pl->>'name', pl->>'order_human_id')
    when 'front_set'  then concierge.set_front(p_actor, pl->>'order_human_id', (pl->>'amount')::int)
    when 'paid'       then concierge.mark_paid(p_actor, pl->>'name', (pl->>'amount')::int)
    when 'reset_soft' then concierge.period_reset(p_actor, 'soft')
    when 'reset_hard' then concierge.period_reset(p_actor, 'hard')
    else jsonb_build_object('ok', false, 'error', 'unknown_type')
  end;

  update concierge.pending_actions
     set status = 'consumed', consumed_at = now(), consumed_by = p_actor, result = v_res
   where token = p_token;
  perform concierge.log_event(v_period, p_actor, 'action', p_token, 'action_consumed', null, v_res,
                              jsonb_build_object('type', a.type));
  return v_res;
end $$;

-- Discard a staged action.
create or replace function concierge.discard_action(p_actor bigint, p_token text)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  a concierge.pending_actions%rowtype;
begin
  select * into a from concierge.pending_actions where token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_action'); end if;
  if a.status <> 'staged' then return jsonb_build_object('ok', true, 'already', true); end if;
  update concierge.pending_actions set status = 'discarded' where token = p_token;
  perform concierge.log_event(v_period, p_actor, 'action', p_token, 'action_discarded',
                              null, null, jsonb_build_object('type', a.type));
  return jsonb_build_object('ok', true, 'type', a.type);
end $$;

-- ----------------------------------------------------------------------------
-- period_reset: soft = clear open orders only; hard = clear orders + pending +
-- reset ord counter. Wallet/inventory/clients/fronts kept (matches bot today).
-- NOTE: this is the in-period "jobs reset", distinct from period_close in 0003.
-- ----------------------------------------------------------------------------
create or replace function concierge.period_reset(p_actor bigint, p_mode text)
returns jsonb language plpgsql as $$
declare
  v_period bigint := concierge.active_period();
  v_open integer;
  v_pending integer;
begin
  select count(*) into v_open from concierge.orders where period_id = v_period and status = 'open';
  if p_mode = 'soft' then
    update concierge.orders set status = 'voided', voided_at = now(), voided_by = p_actor
      where period_id = v_period and status = 'open';
    perform concierge.log_event(v_period, p_actor, 'period', null, 'reset_soft',
      jsonb_build_object('open', v_open), null, '{}'::jsonb);
    return jsonb_build_object('ok', true, 'cleared', v_open);
  else
    select count(*) into v_pending from concierge.orders where period_id = v_period and status = 'pending';
    update concierge.orders set status = 'voided', voided_at = now(), voided_by = p_actor
      where period_id = v_period and status = 'open';
    update concierge.orders set status = 'cancelled'
      where period_id = v_period and status = 'pending';
    update concierge.counters set value = 0 where period_id = v_period and name = 'order';
    perform concierge.log_event(v_period, p_actor, 'period', null, 'reset_hard',
      jsonb_build_object('open', v_open, 'pending', v_pending), null, '{}'::jsonb);
    return jsonb_build_object('ok', true, 'cleared_open', v_open, 'cleared_pending', v_pending);
  end if;
end $$;
