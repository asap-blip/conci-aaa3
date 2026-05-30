// ============================================================================
// new_order.js  —  single entry point with two intake modes
// ----------------------------------------------------------------------------
// "New Order" (keyboard) or typing `new` opens an inline menu offering:
//   * Free-form  -> stage ui_prompt 'new_order_freeform'
//   * Form-style -> stage ui_prompt 'new_order_form'
//
// The operator's NEXT message in that chat is interpreted as the order text in
// the chosen mode. Both modes converge on the SAME staged-order path:
//   parse -> concierge.new_order(...) RPC -> pending order card (approve / front / cancel)
//
// Free-form parsing: try the deterministic local tokenizer first (handles the
// canonical "name qtyxproduct price time address" shape). Only if that fails do
// we fall back to the internal Claude parser. Claude is never operator-visible.
//
// Form-style parsing: deterministic only (labelled lines). No AI.
// ============================================================================

const VALID_PRODUCTS = ['c', '50c', 'p', '50p', 'b', '50k', 'k', 'm', 's'];

// ---- Form-style ------------------------------------------------------------
// First line = name. Then labelled lines: order:, address:, price:, time:.
// time may be blank/absent = ASAP.
function parseForm(rawText) {
  const lines = (rawText || '').split('\n');
  const name = (lines[0] || '').trim().toLowerCase();
  let orderLine = null, addressLine = null, priceLine = null, timeLine = null;
  for (let i = 1; i < lines.length; i++) {
    const ln = lines[i].trim();
    let m;
    if ((m = ln.match(/^order\s*:\s*(.*)$/i)))   orderLine = m[1].trim();
    else if ((m = ln.match(/^address\s*:\s*(.*)$/i))) addressLine = m[1].trim();
    else if ((m = ln.match(/^price\s*:\s*(.*)$/i)))   priceLine = m[1].trim();
    else if ((m = ln.match(/^time\s*:\s*(.*)$/i)))    timeLine = m[1].trim();
  }
  if (!name || orderLine === null || addressLine === null) {
    return { ok: false, error: 'form needs a name, an order: line and an address: line' };
  }
  const items = parseItems(orderLine);
  if (items.length === 0) {
    return { ok: false, error: 'no valid products in order: line\nvalid: ' + VALID_PRODUCTS.join(', ') };
  }
  const price = priceLine ? toIntOrNull(priceLine) : null;
  const time = (timeLine && !/^[\[<].*[\]>]$/.test(timeLine)) ? timeLine : null;
  return { ok: true, mode: 'form', name, items, price, time, address: addressLine.toLowerCase() };
}

// ---- Free-form (deterministic tokenizer) -----------------------------------
// Shape: <name> [<qty> <product> ...] [<price>] [<time>] <address...>
// Mirrors the existing bot's tolerant tokenizer; returns null fields when
// genuinely ambiguous (never guesses price vs address number).
function parseFreeformLocal(rawText) {
  let s = (rawText || '').trim().toLowerCase().replace(/,/g, ' ');
  s = s.replace(/(\d+)([a-z])/g, '$1 $2'); // split 2c -> 2 c
  const toks = s.split(/\s+/).filter(Boolean);
  if (toks.length === 0) return { ok: false };

  const name = toks.shift();
  const items = [];
  // leading items block
  while (toks.length) {
    const t = toks[0];
    const q = parseInt(t, 10);
    if (!isNaN(q) && toks[1] && VALID_PRODUCTS.indexOf(toks[1]) >= 0) {
      items.push({ product: toks[1], qty: q }); toks.splice(0, 2); continue;
    }
    if (VALID_PRODUCTS.indexOf(t) >= 0) { items.push({ product: t, qty: 1 }); toks.shift(); continue; }
    break;
  }
  if (items.length === 0) return { ok: false };

  // price = a standalone 2-4 digit number NOT immediately followed by a street word
  let price = null, time = null;
  const STREET = /(rue|av|ave|avenue|boul|blvd|bd|ch|chemin|st|saint|sainte|place)/;
  for (let i = 0; i < toks.length; i++) {
    if (/^\d{2,4}$/.test(toks[i]) && !(toks[i + 1] && STREET.test(toks[i + 1]))) {
      // make sure the remainder still has an address after removing this
      if (toks.slice(i + 1).some((x) => /[a-z]/.test(x))) { price = parseInt(toks[i], 10); toks.splice(i, 1); break; }
    }
  }
  // time like 10pm / 22:00 / 11:30pm
  for (let i = 0; i < toks.length; i++) {
    if (/^\d{1,2}(:\d{2})?(am|pm)?$/.test(toks[i]) && /(am|pm|:)/.test(toks[i])) { time = toks[i]; toks.splice(i, 1); break; }
  }
  const address = toks.join(' ').trim();
  if (!address) return { ok: false };
  return { ok: true, mode: 'freeform', name, items, price, time, address };
}

// ---- shared item parser ----------------------------------------------------
function parseItems(orderLine) {
  let s = (orderLine || '').toLowerCase().replace(/,/g, ' ').replace(/(\d+)([a-z])/g, '$1 $2');
  const toks = s.split(/\s+/).filter(Boolean);
  const items = [];
  let i = 0;
  while (i < toks.length) {
    const q = parseInt(toks[i], 10);
    if (!isNaN(q) && toks[i + 1] && VALID_PRODUCTS.indexOf(toks[i + 1]) >= 0) { items.push({ product: toks[i + 1], qty: q }); i += 2; }
    else if (VALID_PRODUCTS.indexOf(toks[i]) >= 0) { items.push({ product: toks[i], qty: 1 }); i += 1; }
    else i += 1;
  }
  return items;
}

function toIntOrNull(v) { const n = parseInt(v, 10); return isNaN(n) ? null : n; }

if (typeof module !== 'undefined') {
  module.exports = { parseForm, parseFreeformLocal, parseItems, VALID_PRODUCTS };
}
