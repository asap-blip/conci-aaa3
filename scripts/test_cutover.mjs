// ============================================================================
// test_cutover.mjs — offline proof of the Supabase cutover wiring.
//
// Runs the ACTUAL transformed Code + Callback Handler node bodies from
// concierge.supabase.workflow.json against an in-memory fake of the state
// bridge (load_state / save_state) and a fake dispatch ETA. Proves:
//   * loadState/saveState are called and state persists across messages
//   * commands render, mutations land in the persisted doc
//   * the durable __events stream is populated (audit)
//   * callback approve commits + is idempotent on re-tap
//
// This does NOT replace applying the SQL to a Supabase branch (PL/pgSQL is not
// executed here) — it validates the n8n-side wiring deterministically.
// ============================================================================
import fs from 'node:fs';

const wf = JSON.parse(fs.readFileSync('n8n/concierge.supabase.workflow.json', 'utf8'));
const nodes = Object.fromEntries(wf.nodes.map((n) => [n.name, n]));
const ROUTER = nodes['Code'].parameters.jsCode;
const CALLBACK = nodes['Callback Handler'].parameters.jsCode;
const PARSE = nodes['Parse Response'].parameters.jsCode;
const USER = 7865010991;

function emptyState() {
  return {
    wallet: { cash: 0, pay: 0, updated_at: null },
    inventory: { c: 0, '50c': 0, p: 0, '50p': 0, b: 0, '50k': 0, k: 0, m: 0, s: 0 },
    orders: [], voids: [], clients: {}, front: {}, log: [], pending: {}, pending_edits: {},
    pending_actions: {}, front_prompts: {}, ui_prompts: {}, eta_snippets: {}, undo_buffer: null,
    next_order_id: 1, next_action_id: 1, next_snippet_id: 1, claude_disabled: false, initialized: true,
  };
}

// Shared fake store (simulates Supabase across messages).
const store = { doc: emptyState(), events: [] };
const clone = (x) => JSON.parse(JSON.stringify(x));

// Mock the n8n Code-node context: this.helpers.httpRequest (json:true -> parsed body).
function makeCtx() {
  return { helpers: { httpRequest: async (opts) => {
    const url = String(opts.url);
    if (url.endsWith('/rpc/load_state')) return { ...clone(store.doc), __period_id: 1 };
    if (url.endsWith('/rpc/save_state')) {
      const s = clone(opts.body.p_state); delete s.__events; delete s.__period_id; delete s.__actor;
      store.doc = s;
      for (const e of opts.body.p_events || []) store.events.push(e);
      return { ok: true, period_id: 1 };
    }
    // dispatch ETA: graceful-failure branch
    if (url.includes('concierge-eta')) return { ok: false, error: 'no location ping yet -- tap concierge ping on phone' };
    throw new Error('unexpected url ' + url);
  } } };
}

const ENV = { SUPABASE_URL: 'https://fake.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'fake-key',
  DISPATCH_ETA_URL: 'https://fake/webhook/concierge-eta-test', DISPATCH_SECRET: 'fake-secret' };

async function run(body, json, dollar) {
  const fn = new Function('$json', '$env', '$', '__ctx',
    'return (async function(){\n' + body + '\n}).call(__ctx);');
  return fn(json, ENV, dollar || (() => ({ item: { json: {} } })), makeCtx());
}
const msg = (text) => ({ message: { message_id: Math.floor(Math.random() * 1e6), text, chat: { id: USER }, from: { id: USER } } });
const cbq = (data, message_id) => ({ callback_query: { id: 'cb' + Math.random(), data, message: { message_id, chat: { id: USER } }, from: { id: USER } } });

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('PASS', name); }
  else { fail++; console.log('FAIL', name, extra !== undefined ? JSON.stringify(extra) : ''); }
}
const txt = (r) => (r && r[0] && r[0].json && (r[0].json.text || '')) || '';

(async () => {
  // 1. wallet (read)
  let r = await run(ROUTER, msg('wallet'));
  check('wallet renders', txt(r).includes('WALLET'), txt(r));

  // 2. new -> two-mode menu
  r = await run(ROUTER, msg('new'));
  const kb = r[0].json.telegram_body && r[0].json.telegram_body.reply_markup;
  check('new order menu', JSON.stringify(kb).includes('new_order:freeform') && JSON.stringify(kb).includes('new_order:form'));

  // 3. wallet add 50 (prefix-free) -> persists + audit event
  r = await run(ROUTER, msg('wallet add 50'));
  check('wallet add persisted', store.doc.wallet.cash === 50, store.doc.wallet);
  check('wallet add audited', store.events.some((e) => e.action === 'wallet_add'), store.events.map(e=>e.action));

  // 4. prompt flow: tap Add then answer 200
  r = await run(ROUTER, msg('Add'));
  check('Add stages prompt', !!store.doc.ui_prompts[USER] && store.doc.ui_prompts[USER].type === 'wallet_add');
  r = await run(ROUTER, msg('200'));
  check('prompt answer adds cash', store.doc.wallet.cash === 250, store.doc.wallet);
  check('prompt cleared', !store.doc.ui_prompts[USER]);

  // 5. free-form intake -> needs parsing (Claude), prefix-stripped parse_text
  r = await run(ROUTER, msg('maya 2 50p 65 10pm 4520 papineau'));
  check('freeform -> needs_parsing', r[0].json.needs_parsing === true);
  check('freeform parse_text set', r[0].json.parse_text === 'maya 2 50p 65 10pm 4520 papineau', r[0].json.parse_text);

  // 6. form-style intake -> pending order card persisted
  r = await run(ROUTER, msg('maya\norder: 2 50p\naddress: 4520 papineau\nprice: 65\ntime: 10pm'));
  const tok = r[0].json.token;
  check('form stages pending', !!tok && !!store.doc.pending[tok], Object.keys(store.doc.pending));
  check('form parsed price', store.doc.pending[tok] && store.doc.pending[tok].price === 65, store.doc.pending[tok]);
  const approveCb = JSON.stringify(r[0].json.telegram_body.reply_markup).includes('approve:' + tok);
  check('form card has approve button', approveCb);

  // 7. callback approve -> commit + inventory/cash/pay + audit
  const cashBefore = store.doc.wallet.cash, payBefore = store.doc.wallet.pay;
  r = await run(CALLBACK, cbq('approve:' + tok, 4321));
  check('approve commits order', store.doc.orders.some((o) => o.id === tok), store.doc.orders.map(o=>o.id));
  check('approve adds price to cash', store.doc.wallet.cash === cashBefore + 65, store.doc.wallet.cash);
  check('approve accrues pay +20', store.doc.wallet.pay === payBefore + 20, store.doc.wallet.pay);
  check('approve decremented inventory 50p', store.doc.inventory['50p'] === -2, store.doc.inventory['50p']);
  check('approve audited', store.events.some((e) => e.action === 'order_approved'));

  // 7b. FREE-FORM end-to-end through Parse Response (the bridge split-brain fix):
  //     router emits needs_parsing -> (fake Claude) -> Parse Response stages a
  //     pending order in Supabase -> approve commits it.
  const ff = await run(ROUTER, msg('jay 1 c 80 4520 papineau'));
  const upstream = ff[0].json; // { chat_id, user_id, raw_text/parse_text, needs_parsing }
  const fakeClaude = { content: [{ text: JSON.stringify({ name: 'jay', items: [{ product: 'c', qty: 1 }], price: 80, time: null, address: '4520 papineau' }) }] };
  const dollar = (name) => name === 'Needs Parsing?' ? { item: { json: upstream } } : { item: { json: {} } };
  const pr = await run(PARSE, fakeClaude, dollar);
  const ffTok = pr[0].json.token;
  check('freeform parsed -> pending in Supabase', !!ffTok && !!store.doc.pending[ffTok], Object.keys(store.doc.pending));
  check('freeform pending audited', store.events.some((e) => e.action === 'order_pending'));
  const ffCashBefore = store.doc.wallet.cash;
  await run(CALLBACK, cbq('approve:' + ffTok, 9001));
  check('freeform order approvable end-to-end', store.doc.orders.some((o) => o.id === ffTok), store.doc.orders.map(o=>o.id));
  check('freeform approve adds cash', store.doc.wallet.cash === ffCashBefore + 80, store.doc.wallet.cash);

  // 8. idempotent re-tap: same approve must NOT double-charge
  const cashAfter = store.doc.wallet.cash, payAfter = store.doc.wallet.pay;
  r = await run(CALLBACK, cbq('approve:' + tok, 4321));
  check('re-tap no double cash', store.doc.wallet.cash === cashAfter, store.doc.wallet.cash);
  check('re-tap no double pay', store.doc.wallet.pay === payAfter, store.doc.wallet.pay);

  // 9. PURGE wallet — 2-step: stage -> step1 ✅ -> step2 ✅ erases from SB doc
  store.doc.wallet = { cash: 500, pay: 80, updated_at: null };
  let pr2 = await run(ROUTER, msg('purge wallet'));
  const pTok = pr2[0].json.token;
  check('purge stages action', !!pTok && store.doc.pending_actions[pTok] && store.doc.pending_actions[pTok].type === 'purge' && store.doc.pending_actions[pTok].stage === 1, store.doc.pending_actions);
  check('purge step1 card has purge_next', JSON.stringify(pr2[0].json.telegram_body.reply_markup).includes('purge_next:' + pTok));
  let pr3 = await run(CALLBACK, cbq('purge_next:' + pTok, 7001));
  check('purge step1 -> stage 2', store.doc.pending_actions[pTok] && store.doc.pending_actions[pTok].stage === 2);
  check('purge step2 card emitted (FINAL CONFIRM + purge_apply)', /FINAL CONFIRM/.test(pr3[0].json.confirm_card_text || '') && JSON.stringify(pr3[0].json.confirm_card_markup).includes('purge_apply:' + pTok));
  check('purge not yet applied (wallet intact)', store.doc.wallet.cash === 500 && store.doc.wallet.pay === 80, store.doc.wallet);
  await run(CALLBACK, cbq('purge_apply:' + pTok, 7001));
  check('purge applied: wallet zeroed in SB doc', store.doc.wallet.cash === 0 && store.doc.wallet.pay === 0, store.doc.wallet);
  check('purge action consumed', !store.doc.pending_actions[pTok]);
  check('purge audited', store.events.some((e) => e.action === 'purge_wallet_applied'));

  // 10. CANCEL leaves data untouched (purge front -> discard at step 1)
  store.doc.front = { jay: { total: 40, orders: [{ id: 'ord-9', amount: 40, ts: 1, paid_history: [] }] } };
  let pf = await run(ROUTER, msg('purge front'));
  const fTok2 = pf[0].json.token;
  await run(CALLBACK, cbq('discard_action:' + fTok2, 7002));
  check('cancel removes pending purge', !store.doc.pending_actions[fTok2]);
  check('cancel leaves front data intact', store.doc.front.jay && store.doc.front.jay.total === 40, store.doc.front);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR', e); process.exit(2); });
