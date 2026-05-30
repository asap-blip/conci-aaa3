// ============================================================================
// import_backup.mjs — one-time loader: `c backup` JSON  ->  Supabase
// ----------------------------------------------------------------------------
// The bot's `c backup` command DMs the full static-data document. That document
// is exactly the shape concierge.save_state() expects, so importing is a single
// save_state() call: it stores the working doc, appends an `imported` audit
// event, and materializes the normalized accounting tables for the active
// period.
//
// Usage:
//   SUPABASE_URL=https://<ref>.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=<service key> \
//   node scripts/import_backup.mjs path/to/concierge-backup-YYYY-MM-DD.json [--actor <telegram_id>] [--dry-run]
//
// --dry-run prints what would be sent (no network). Run it first.
//
// Pre-req: migrations 0001–0004 applied; an `active` operating period exists
// (load_state()/bootstrap creates one). Run against a Supabase BRANCH first.
// ============================================================================
import fs from 'node:fs';

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const dry = args.includes('--dry-run');
const actorIdx = args.indexOf('--actor');
const actor = actorIdx >= 0 ? Number(args[actorIdx + 1]) : null;

if (!file) { console.error('usage: node scripts/import_backup.mjs <backup.json> [--actor <id>] [--dry-run]'); process.exit(1); }

const raw = fs.readFileSync(file, 'utf8');
let doc;
try { doc = JSON.parse(raw); } catch (e) { console.error('backup is not valid JSON:', e.message); process.exit(1); }

// sanity: the backup must look like a concierge state document
const need = ['wallet', 'inventory', 'orders'];
const missing = need.filter((k) => !(k in doc));
if (missing.length) { console.error('does not look like a concierge backup; missing:', missing.join(', ')); process.exit(1); }

// tag an import marker event so the audit trail shows where this state came from
const events = [{
  actor, entity_type: 'period', entity_id: 'import', action: 'imported',
  metadata: { source_file: file.split('/').pop(), orders: (doc.orders || []).length,
              pending: Object.keys(doc.pending || {}).length, cash: doc.wallet && doc.wallet.cash },
}];

const body = { p_state: doc, p_events: events, p_actor: actor };

if (dry) {
  console.log('[dry-run] would POST save_state with:');
  console.log('  orders:', (doc.orders || []).length, '| pending:', Object.keys(doc.pending || {}).length,
    '| clients:', Object.keys(doc.clients || {}).length, '| fronts:', Object.keys(doc.front || {}).length);
  console.log('  wallet:', JSON.stringify(doc.wallet));
  console.log('  next_order_id:', doc.next_order_id, '| next_action_id:', doc.next_action_id);
  console.log('  event:', JSON.stringify(events[0]));
  process.exit(0);
}

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) { console.error('set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY'); process.exit(1); }

const res = await fetch(url.replace(/\/+$/, '') + '/rest/v1/rpc/save_state', {
  method: 'POST',
  headers: {
    apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json',
    'Accept-Profile': 'concierge', 'Content-Profile': 'concierge',
  },
  body: JSON.stringify(body),
});
const out = await res.text();
if (!res.ok) { console.error('import failed', res.status, out); process.exit(1); }
console.log('import ok:', out);
