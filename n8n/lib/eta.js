// ============================================================================
// eta.js — shared, reusable ETA / dispatch module (pure logic, no network)
// ----------------------------------------------------------------------------
// Used by the standalone ETA workflow (n8n/eta.workflow.json) and designed to be
// reused by the main concierge workflow later. Network I/O (the dispatch service
// + reading concierge active jobs from Supabase) happens in the workflow's Code
// node; this module only does parsing, payload assembly, and card rendering.
//
// The actual GPS/routing lives in the external dispatch service (NOT here):
//   POST {address, auth[, driver]} ->
//     { ok, eta_minutes, arrival_label, client_eta_minutes, client_arrival_label,
//       distance_km, maps_url, location_stale, error }
//
// v1 stacked ETA is append-to-end only (no route optimization) and the cumulative
// timing is a clearly-labeled estimate. See docs/ETA.md.
// ============================================================================

var ETA_DRIVERS = ['T', 'FISTON'];
var ETA_PRODUCTS = ['c', '50c', 'p', '50p', 'b', '50k', 'k', 'm', 's'];

// ---- input parsing ---------------------------------------------------------
// Operator sends (Mode 1):
//   eta
//   maya
//   2×p            (or "2 p", "2x p", "2p")
//   4444 sherbrooke
//   [10pm]         (optional)
function etaParseInput(rawText) {
  var lines = String(rawText || '').split('\n').map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; });
  // drop a leading "eta" trigger word (line may be just "eta")
  if (lines.length && lines[0].toLowerCase() === 'eta') { lines.shift(); }
  else if (lines.length && lines[0].toLowerCase().indexOf('eta ') === 0) { lines[0] = lines[0].slice(4).trim(); }
  if (lines.length < 3) {
    return { ok: false, error: 'format:\neta\n<name>\n<items>\n<address>\n[time]' };
  }
  var client = lines[0].toLowerCase();
  var itemsParsed = etaParseItems(lines[1]);
  var address = lines[2].toLowerCase();
  var time = lines[3] || null;
  if (itemsParsed.length === 0) { return { ok: false, error: 'no valid products in "' + lines[1] + '"\nvalid: ' + ETA_PRODUCTS.join(', ') }; }
  if (!address) { return { ok: false, error: 'missing address' }; }
  return { ok: true, client: client, items_parsed: itemsParsed, items: etaItemsToStr(itemsParsed), address: address, time: time };
}

function etaParseItems(line) {
  var s = String(line || '').toLowerCase().replace(/×/g, ' ').replace(/,/g, ' ').replace(/(\d+)\s*x\s*/g, '$1 ').replace(/(\d+)([a-z])/g, '$1 $2');
  var toks = etaMergeHalf(s.split(/\s+/).filter(Boolean));
  var items = [], i = 0;
  while (i < toks.length) {
    var q = parseInt(toks[i], 10);
    if (!isNaN(q) && toks[i + 1] && ETA_PRODUCTS.indexOf(toks[i + 1]) >= 0) { items.push({ product: toks[i + 1], qty: q }); i += 2; }
    else if (ETA_PRODUCTS.indexOf(toks[i]) >= 0) { items.push({ product: toks[i], qty: 1 }); i += 1; }
    else { i += 1; }
  }
  return items;
}
function etaMergeHalf(toks) {
  var out = [];
  for (var i = 0; i < toks.length; i++) {
    if (toks[i] === '50' && (toks[i + 1] === 'p' || toks[i + 1] === 'c' || toks[i + 1] === 'k')) { out.push('50' + toks[i + 1]); i++; }
    else { out.push(toks[i]); }
  }
  return out;
}
function etaItemsToStr(items) {
  return items.map(function (it) { return it.qty + '×' + it.product; }).join(' ');
}

// ---- presentation helpers --------------------------------------------------
function etaMapsUrl(addr) {
  if (!addr) { return ''; }
  var full = addr;
  if (!/montreal|laval|brossard|quebec|qc/i.test(addr)) { full = addr + ', Montreal, QC, Canada'; }
  return 'https://maps.google.com/?q=' + encodeURIComponent(full).replace(/%20/g, '+');
}
function etaSnippet(minutes, arrivalLabel) {
  return 'on my way, ~' + minutes + ' min — arriving ' + arrivalLabel;
}
// format "now + minutes" as "3:47 a.m." in the operator's timezone
function etaArrivalLabel(minutes, nowMs) {
  var d = new Date((nowMs || Date.now()) + minutes * 60000);
  var s = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit', hour12: true }).format(d);
  return s.replace(/\bAM\b/, 'a.m.').replace(/\bPM\b/, 'p.m.');
}

// ---- payload assembly ------------------------------------------------------
// parsed   : from etaParseInput
// driver   : 'T' | 'FISTON'
// dispatch : the dispatch response for the NEW stop (or {failed:true,error})
// queue    : [{client,address,minutes}] active jobs for this driver (sorted asc), may be []
function etaBuildPayload(parsed, driver, dispatch, queue, nowMs) {
  var ok = !!(dispatch && dispatch.ok);
  var p = {
    ok: ok, mode: (queue && queue.length > 0) ? 'stacked' : 'direct',
    client: parsed.client, items: parsed.items, items_parsed: parsed.items_parsed,
    address: parsed.address, driver: driver, maps_url: ok ? (dispatch.maps_url || etaMapsUrl(parsed.address)) : etaMapsUrl(parsed.address),
    internal: ok ? { minutes: dispatch.eta_minutes, arrival_label: dispatch.arrival_label } : null,
    client_eta: (ok && dispatch.client_eta_minutes !== undefined) ? { minutes: dispatch.client_eta_minutes, arrival_label: dispatch.client_arrival_label } : null,
    snippet: null, queue: queue || [], stacked: null,
    apply: { wired: false, order_draft: { client: parsed.client, items_parsed: parsed.items_parsed, address: parsed.address, driver: driver } },
    dispatch_ok: ok, error: ok ? null : (dispatch && dispatch.error) || 'dispatch unavailable',
    generated_at: Math.floor((nowMs || Date.now()) / 1000)
  };
  if (p.client_eta) { p.snippet = etaSnippet(p.client_eta.minutes, p.client_eta.arrival_label); }
  else if (ok) { p.snippet = etaSnippet(p.internal.minutes, p.internal.arrival_label); }
  if (ok && p.mode === 'stacked') {
    var last = queue[queue.length - 1];
    var added = p.internal.minutes;                 // v1 append-to-end proxy (direct ETA to new stop)
    var total = (last.minutes || 0) + added;        // labeled approximate
    p.stacked = { after: last.client, added_minutes: added, total_minutes: total,
                  arrival_label: etaArrivalLabel(total, nowMs), approximate: true };
  }
  return p;
}

// ---- card rendering --------------------------------------------------------
function etaRenderText(p) {
  if (!p.ok) {
    return 'QUICK ETA — failed\nClient: ' + p.client + '\nTo: ' + p.address + '\nDriver: ' + p.driver + '\n⚠ ' + p.error;
  }
  if (p.mode === 'stacked') { return etaRenderStacked(p); }
  var L = ['QUICK ETA',
    'Client: ' + p.client, 'Order: ' + p.items, 'To: ' + p.address, 'Driver: ' + p.driver,
    'Internal: ' + p.internal.minutes + ' min · arriving ' + p.internal.arrival_label];
  if (p.client_eta) { L.push('Client: ~' + p.client_eta.minutes + ' min · arriving ' + p.client_eta.arrival_label); }
  L.push('Maps: ' + p.maps_url);
  L.push('Client copy');
  L.push(p.snippet);
  return L.join('\n');
}
function etaRenderStacked(p) {
  var L = ['QUICK ETA · STACKED',
    'Client: ' + p.client, 'Order: ' + p.items, 'Driver: ' + p.driver, 'New stop: ' + p.address,
    'Current queue'];
  if (!p.queue || p.queue.length === 0) {
    L.push('none');
    L.push('Direct arrival');
    L.push('~' + p.internal.minutes + ' min');
    L.push('ETA: ' + p.internal.arrival_label);
    return L.join('\n');
  }
  for (var i = 0; i < p.queue.length; i++) { L.push((i + 1) + '. ' + p.queue[i].client + ' · ' + p.queue[i].minutes + ' min'); }
  L.push('If added after current jobs:');
  L.push(p.client + ' · +~' + p.stacked.added_minutes + ' min after ' + p.stacked.after + '  (est)');
  L.push('Arriving in ~' + p.stacked.total_minutes + ' min');
  L.push('ETA: ' + p.stacked.arrival_label);
  return L.join('\n');
}
// inline-keyboard rows (driver choice + apply/cancel). qid keys the staged quote.
function etaButtons(qid, driver) {
  return [
    [ { text: (driver === 'T' ? '🟢 T' : 'T'), callback_data: 'eta_drv:' + qid + ':T' },
      { text: (driver === 'FISTON' ? '🟢 FISTON' : 'FISTON'), callback_data: 'eta_drv:' + qid + ':FISTON' } ],
    [ { text: '✅ Apply as order', callback_data: 'eta_apply:' + qid },
      { text: '❌ Cancel', callback_data: 'eta_cancel:' + qid } ]
  ];
}

if (typeof module !== 'undefined') {
  module.exports = { ETA_DRIVERS, ETA_PRODUCTS, etaParseInput, etaParseItems, etaItemsToStr,
    etaMapsUrl, etaSnippet, etaArrivalLabel, etaBuildPayload, etaRenderText, etaRenderStacked, etaButtons };
}
