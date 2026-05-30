// ============================================================================
// persistence.js  —  Supabase (PostgREST) client for n8n Code nodes
// ----------------------------------------------------------------------------
// Thin, explicit wrapper around Supabase's auto-generated REST API. Every
// business mutation is a single RPC call to a function defined in
// db/migrations/0002_mutation_rpcs.sql / 0003_export_archive.sql, so the n8n
// side does NO money arithmetic — it formats input, calls one RPC, renders the
// jsonb result.
//
// Config comes from n8n environment / credentials (NEVER inline secrets):
//   SUPABASE_URL              e.g. https://<ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY service role key (server-side only)
//
// In a Code node these are read via $env (Settings > set "Environment" access)
// or injected by an HTTP Request node credential. Example usage at the top of
// the router / callback Code node:
//
//   const db = makeDb({ url: $env.SUPABASE_URL, key: $env.SUPABASE_SERVICE_ROLE_KEY,
//                       http: this.helpers.httpRequest.bind(this.helpers) });
//   const r  = await db.rpc('approve_order', { p_actor: userId, p_human: token });
//
// All rpc() calls target the `concierge` schema functions. PostgREST exposes
// schema functions at /rest/v1/rpc/<fn>; set the function search via the
// `Content-Profile`/`Accept-Profile` headers to the concierge schema.
// ============================================================================

function makeDb(cfg) {
  const base = cfg.url.replace(/\/+$/, '');
  const http = cfg.http; // this.helpers.httpRequest
  const headers = {
    'apikey': cfg.key,
    'Authorization': 'Bearer ' + cfg.key,
    'Content-Type': 'application/json',
    // expose + write to the concierge schema (Supabase must allow it in
    // Settings > API > Exposed schemas, or use the public-schema wrappers).
    'Accept-Profile': 'concierge',
    'Content-Profile': 'concierge',
  };
  const timeout = cfg.timeout || 8000;

  // Call a Postgres function. Returns the parsed jsonb body.
  async function rpc(fn, args) {
    const res = await http({
      method: 'POST',
      url: base + '/rest/v1/rpc/' + fn,
      headers,
      body: args || {},
      json: true,
      timeout,
    });
    return res;
  }

  // Read rows from a table/view with a PostgREST query string.
  async function select(path) {
    return http({
      method: 'GET',
      url: base + '/rest/v1/' + path,
      headers,
      json: true,
      timeout,
    });
  }

  return { rpc, select };
}

// ---------------------------------------------------------------------------
// Convenience facade mapping operator actions -> RPC names + arg shapes.
// Keeps call sites in the workflow short and uniform.
// ---------------------------------------------------------------------------
function makeLedger(db, actor) {
  const A = { p_actor: actor };
  return {
    // intake
    newOrder: (o) => db.rpc('new_order', { ...A, p_name: o.name, p_items: o.items,
      p_price: o.price, p_time: o.time, p_address: o.address, p_intake_mode: o.mode }),
    // lifecycle
    approve:    (human, armFront, msgId) => db.rpc('approve_order', { ...A, p_human: human, p_arm_front: !!armFront, p_message_id: msgId || null }),
    cancel:     (human) => db.rpc('cancel_pending', { ...A, p_human: human }),
    edit:       (human, changes) => db.rpc('edit_order', { ...A, p_human: human, p_changes: changes }),
    // fronts / money
    setFront:   (human, amount) => db.rpc('set_front', { ...A, p_human: human, p_amount: amount }),
    markPaid:   (name, amount) => db.rpc('mark_paid', { ...A, p_name: name, p_amount: amount }),
    forgive:    (name, human) => db.rpc('forgive_front', { ...A, p_name: name, p_human: human }),
    walletCash: (op, amount) => db.rpc('wallet_cash', { ...A, p_op: op, p_amount: amount || 0 }),
    walletPay:  (op, amount) => db.rpc('wallet_pay', { ...A, p_op: op, p_amount: amount || 0 }),
    inventory:  (op, changes) => db.rpc('inventory_adjust', { ...A, p_op: op, p_changes: changes || {} }),
    undo:       () => db.rpc('undo_last', A),
    // durable pending actions (callback safety)
    stageAction:   (type, payload) => db.rpc('stage_action', { ...A, p_type: type, p_payload: payload }),
    consumeAction: (token) => db.rpc('consume_action', { ...A, p_token: token }),
    discardAction: (token) => db.rpc('discard_action', { ...A, p_token: token }),
    // period / export
    closePeriod:   (label) => db.rpc('close_period', { ...A, p_new_label: label || null }),
    exportPeriod:  (periodId) => db.rpc('export_period', { p_period: periodId }),
    // reads for display cards
    selOrders:   (periodId, status) => db.select('orders?period_id=eq.' + periodId + (status ? '&status=eq.' + status : '') + '&order=human_id'),
    selWallet:   (periodId) => db.select('wallet?period_id=eq.' + periodId),
    selFronts:   (periodId) => db.select('fronts?period_id=eq.' + periodId + '&amount=gt.0'),
  };
}

if (typeof module !== 'undefined') {
  module.exports = { makeDb, makeLedger };
}
