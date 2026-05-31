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
  await run(CALLBACK, cbq('setdrv:' + tok + ':T', 4321)); // driver now required before approve
  r = await run(CALLBACK, cbq('approve:' + tok, 4321));
  check('approve commits order', store.doc.orders.some((o) => o.id === tok), store.doc.orders.map(o=>o.id));
  check('approve adds price to cash', store.doc.wallet.cash === cashBefore + 65, store.doc.wallet.cash);
  check('approve accrues pay +20', store.doc.wallet.pay === payBefore + 20, store.doc.wallet.pay);
  // inventory split: approve no longer decrements Main; in-jobs is computed
  const _itv = await run(ROUTER, msg('inv t'));
  check('approve -> computed in-jobs (no Main decrement)',
    (store.doc.inventory['50p'] || 0) === 0 && /50p · 0 - 2 = -2/.test(_itv[0].json.text),
    { main50p: store.doc.inventory['50p'], t: _itv[0].json.text });
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
  await run(CALLBACK, cbq('setdrv:' + ffTok + ':T', 9001)); // driver required before approve
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

  // 11. DRIVER selection (select-only -> approve persists; require before approve)
  const dord = await run(ROUTER, msg('lola\norder: 1 c\naddress: 1 rue test\nprice: 30'));
  const dtok = dord[0].json.token;
  check('pending card has driver buttons', JSON.stringify(dord[0].json.telegram_body.reply_markup).includes('setdrv:' + dtok + ':T'));
  check('pending card shows Driver: —', /Driver: —/.test(dord[0].json.text), dord[0].json.text);
  const r2 = await run(CALLBACK, cbq('approve:' + dtok, 8100));
  check('approve blocked without driver', !!store.doc.pending[dtok] && !store.doc.orders.some((o) => o.id === dtok));
  check('block re-render warns', /pick a driver first/.test(r2[0].json.edit_markup_text || ''));
  const r3 = await run(CALLBACK, cbq('setdrv:' + dtok + ':FISTON', 8100));
  check('setdrv sets pending driver', store.doc.pending[dtok] && store.doc.pending[dtok].driver === 'FISTON');
  check('setdrv re-renders in place', /Driver: FISTON/.test(r3[0].json.edit_markup_text || '') && JSON.stringify(r3[0].json.edit_markup).includes('approve:' + dtok));
  check('setdrv did NOT approve', !store.doc.orders.some((o) => o.id === dtok));
  await run(CALLBACK, cbq('approve:' + dtok, 8100));
  const dcommit = store.doc.orders.find((o) => o.id === dtok);
  check('approved order persists driver', !!dcommit && dcommit.driver === 'FISTON', dcommit);
  check('driver shows in jobs', /FISTON/.test(await run(ROUTER, msg('jobs')).then((r) => r[0].json.text)));

  // 12. INVENTORY split: buckets, transfer, computed in-jobs, void auto-restore
  store.doc.orders = [];
  store.doc.inventory = { c: 10 }; store.doc.inv_t = {}; store.doc.inv_fiston = {};
  const mv = await run(ROUTER, msg('inv'));
  check('main stock view', /MAIN STOCK/.test(mv[0].json.text) && /c · 10 - 0 = 10/.test(mv[0].json.text), mv[0].json.text);
  const tr = await run(ROUTER, msg('transfer t c=4'));
  check('transfer Main->T', store.doc.inventory.c === 6 && store.doc.inv_t.c === 4, { main: store.doc.inventory.c, t: store.doc.inv_t.c });
  check('T stock after transfer', /T STOCK/.test(tr[0].json.text) && /c · 4 - 0 = 4/.test(tr[0].json.text), tr[0].json.text);
  check('total unchanged by transfer', /c · 10 - 0 = 10/.test((await run(ROUTER, msg('inv total')))[0].json.text));
  const io = await run(ROUTER, msg('zed\norder: 1 c\naddress: 9 test\nprice: 10'));
  const iotok = io[0].json.token;
  await run(CALLBACK, cbq('setdrv:' + iotok + ':T', 9200));
  await run(CALLBACK, cbq('approve:' + iotok, 9200));
  check('T in-jobs counts approved order', /c · 4 - 1 = 3/.test((await run(ROUTER, msg('inv t')))[0].json.text));
  check('Main not consumed by T order', /c · 6 - 0 = 6/.test((await run(ROUTER, msg('inv')))[0].json.text));
  check('total reflects in-jobs', /c · 10 - 1 = 9/.test((await run(ROUTER, msg('inv total')))[0].json.text));
  const vc = await run(ROUTER, msg('void ' + iotok));
  const vtok = vc[0].json.token;
  await run(CALLBACK, cbq('apply_void:' + vtok, 9200));
  check('void auto-restores T (computed)', /c · 4 - 0 = 4/.test((await run(ROUTER, msg('inv t')))[0].json.text));
  await run(CALLBACK, cbq('apply_void:' + vtok, 9200)); // repeat
  check('no double-restore on repeat void', /c · 4 - 0 = 4/.test((await run(ROUTER, msg('inv t')))[0].json.text));
  await run(ROUTER, msg('return t c=2'));
  check('return T->Main', store.doc.inv_t.c === 2 && store.doc.inventory.c === 8, { t: store.doc.inv_t.c, main: store.doc.inventory.c });

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR', e); process.exit(2); });
