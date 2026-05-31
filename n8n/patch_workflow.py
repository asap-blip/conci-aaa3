#!/usr/bin/env python3
"""
patch_workflow.py — produce concierge.hardened.workflow.json from the original.

Scope of changes (operator-surface ONLY; accounting engine untouched):
  1. New 3x3 reply keyboard (no Claude, with New Order).
  2. Plain-label button map (+ New Order 'menu' type).
  3. Prefix-free routing: known command words work without 'c'; legacy 'c x'
     still accepted during transition.
  4. New Order entry point -> inline two-mode menu (Free-form / Form-style),
     both modes converge on existing intake.
  5. Form parser: prefix-optional name + reads a `price:` line.
  6. Claude kept INTERNAL only: removed `c claude on/off/status` operator
     commands and the Claude keyboard button; free-form still parses internally.
  7. Auth gate keeps the user-id whitelist but drops the 'c'-prefix requirement.
  8. Help text rewritten prefix-free, Claude removed.
  9. Callback handler: handle `new_order:freeform|form` by staging an intake prompt.

Every edit asserts its anchor matched exactly once so a drift in the source
fails loudly instead of silently mis-patching.
"""
import json, re, sys

SRC = 'n8n/concierge.original.workflow.json'
DST = 'n8n/concierge.hardened.workflow.json'

d = json.load(open(SRC))
nodes = {n['name']: n for n in d['nodes']}
code = nodes['Code']['parameters']['jsCode']

def replace_once(haystack, old, new, label):
    c = haystack.count(old)
    assert c == 1, f"[{label}] expected 1 match, got {c}"
    return haystack.replace(old, new, 1)

def sub_once(haystack, pattern, new, label, flags=re.S):
    matches = re.findall(pattern, haystack, flags)
    assert len(matches) == 1, f"[{label}] expected 1 regex match, got {len(matches)}"
    return re.sub(pattern, lambda m: new, haystack, count=1, flags=flags)

# --- 1+2. Replace REPLY_KEYBOARD + BUTTON_COMMANDS literals -------------------
code = sub_once(code, r'var REPLY_KEYBOARD = \{.*?\n\};',
"""var REPLY_KEYBOARD = {
  keyboard: [
    [ { text: 'Wallet' },  { text: 'Jobs' },   { text: 'Front' } ],
    [ { text: 'Add' },     { text: 'Sub' },    { text: 'Paid' } ],
    [ { text: 'Summary' }, { text: 'Backup' }, { text: 'New Order' } ]
  ],
  resize_keyboard: true,
  is_persistent: true,
  selective: false
};""", "REPLY_KEYBOARD")

code = sub_once(code, r'var BUTTON_COMMANDS = \{.*?\n\};',
"""var BUTTON_COMMANDS = {
  'Wallet':    { type: 'direct', cmd: 'c wallet' },
  'Jobs':      { type: 'direct', cmd: 'c jobs' },
  'Front':     { type: 'direct', cmd: 'c front' },
  'Summary':   { type: 'direct', cmd: 'c summary' },
  'Backup':    { type: 'direct', cmd: 'c backup' },
  'Add':       { type: 'prompt', prompt_type: 'wallet_add',  prompt_text: 'how much to add to cash?\\n(reply with a number, or tap any other button to cancel)' },
  'Sub':       { type: 'prompt', prompt_type: 'wallet_sub',  prompt_text: 'how much to withdraw from cash?\\n(reply with a number, or tap any other button to cancel)' },
  'Paid':      { type: 'prompt', prompt_type: 'wallet_paid', prompt_text: 'who paid? format: <name> [amount]\\nexample: jay 100  (or just: jay for full)\\n(or tap any other button to cancel)' },
  'New Order': { type: 'menu', menu: 'new_order' }
};""", "BUTTON_COMMANDS")

# --- define COMMAND_HEADS + emitNewOrderMenu near top (after validProducts) ---
code = replace_once(code,
"var validProducts = ['c','50c','p','50p','b','50k','k','m','s'];",
"""var validProducts = ['c','50c','p','50p','b','50k','k','m','s'];

// Operator command words (prefix-free). Used by the gate-free router to tell a
// command from order intake. Each maps to an existing 'c xxx' dispatch key.
var COMMAND_HEADS = ['wallet','jobs','front','inv','client','clients','summary','backup','undo','cancel','void','edit','eta','kb','keyboard','cmd','commands','new'];""",
"COMMAND_HEADS")

# emitNewOrderMenu helper: add right after emitWithKeyboard's closing (anchor on
# the stagePromptAndEmit comment that follows emitWithKeyboard).
code = replace_once(code,
"// v7.5.2: stage a prompt server-side and send a plain message (no force_reply).",
"""// Inline two-mode New Order menu. Pure presentation; the operator's choice
// stages an intake prompt (handled in the callback handler).
function emitNewOrderMenu() {
  var menuText = [
    'NEW ORDER',
    '\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500\\u2500',
    'pick an intake mode:',
    '',
    '\\u2022 Free-form (one line):',
    '   maya 2 50p 65 10pm 4520 papineau',
    '',
    '\\u2022 Form-style (multi-line):',
    '   maya',
    '   order: 2 50p',
    '   address: 4520 papineau',
    '   price: 65',
    '   time: 10pm   (blank = asap)'
  ].join('\\n');
  return [{ json: {
    chat_id: chatId, text: menuText, is_callback: false, has_card: true, needs_parsing: false,
    telegram_body: { chat_id: chatId, text: menuText, reply_markup: { inline_keyboard: [[
      { text: 'Free-form',  callback_data: 'new_order:freeform' },
      { text: 'Form-style', callback_data: 'new_order:form' }
    ]] } }
  } }];
}

// v7.5.2: stage a prompt server-side and send a plain message (no force_reply).""",
"emitNewOrderMenu")

# --- 3. §4 staged-prompt cancel detection: head-aware + menu taps ------------
code = replace_once(code,
"""  var isCommand = text.indexOf('c ') === 0 || text === 'c';
  var isDirectButtonTap = !!(BUTTON_COMMANDS[rawText] && BUTTON_COMMANDS[rawText].type === 'direct');
  var isPromptButtonTap = !!(BUTTON_COMMANDS[rawText] && BUTTON_COMMANDS[rawText].type === 'prompt');

  if (isCommand || isDirectButtonTap || isPromptButtonTap) {""",
"""  var __h = text.split(/\\s+/)[0];
  var isCommand = text.indexOf('c ') === 0 || text === 'c' || COMMAND_HEADS.indexOf(__h) >= 0;
  var isDirectButtonTap = !!(BUTTON_COMMANDS[rawText] && BUTTON_COMMANDS[rawText].type === 'direct');
  var isPromptButtonTap = !!(BUTTON_COMMANDS[rawText] && BUTTON_COMMANDS[rawText].type === 'prompt');
  var isMenuButtonTap   = !!(BUTTON_COMMANDS[rawText] && BUTTON_COMMANDS[rawText].type === 'menu');

  if (isCommand || isDirectButtonTap || isPromptButtonTap || isMenuButtonTap) {""",
"prompt-cancel-detection")

# new_order prompt answers: clear and fall through to intake
code = replace_once(code,
"""    } else {
      // Unknown staged type (shouldn't happen). Clear and route normally.
      delete data.ui_prompts[chatId];
    }""",
"""    } else if (promptType === 'new_order_freeform' || promptType === 'new_order_form') {
      // The message itself is the order text (either intake mode). Clear the
      // prompt and let normal intake (form parser / free-form) handle it.
      delete data.ui_prompts[chatId];
    } else {
      // Unknown staged type (shouldn't happen). Clear and route normally.
      delete data.ui_prompts[chatId];
    }""",
"new_order-prompt-answer")

# --- 4. §4c button tap: handle 'menu' ---------------------------------------
code = replace_once(code,
"""  } else if (btn.type === 'prompt') {
    return stagePromptAndEmit(btn.prompt_type, btn.prompt_text);
  }
}""",
"""  } else if (btn.type === 'prompt') {
    return stagePromptAndEmit(btn.prompt_type, btn.prompt_text);
  } else if (btn.type === 'menu' && btn.menu === 'new_order') {
    return emitNewOrderMenu();
  }
}""",
"button-menu-branch")

# --- 5. prefix-free normalization right before dispatch ----------------------
code = replace_once(code,
"// ===== 7. DISPATCH ===========================================================",
"""// ===== 6b. PREFIX-FREE NORMALIZATION (operator UX) ===========================
// Operator words work without the legacy 'c' prefix. We canonicalize a bare
// command ("wallet", "front 12 40", "new") to the existing 'c xxx' form so the
// dispatch tables below are unchanged. Legacy 'c xxx' still works during
// transition. Anything whose first word is not a known command is order intake.
(function () {
  var head = text.split(/\\s+/)[0];
  var isLegacy = (text === 'c' || text.indexOf('c ') === 0);
  if (!isLegacy && COMMAND_HEADS.indexOf(head) >= 0) {
    text = 'c ' + text;
    rawText = 'c ' + rawText;
  }
})();

// ===== 7. DISPATCH ===========================================================""",
"normalize-shim")

# add 'c new' exact command + cmd_newOrderMenu (register in exactCommands)
code = replace_once(code,
"  'c clients':          cmd_clients\n};",
"  'c clients':          cmd_clients,\n  'c new':              emitNewOrderMenu\n};",
"exact-new")

# --- 6. remove Claude operator commands from exactCommands -------------------
code = replace_once(code,
"""  'c claude on':        cmd_claudeOn,
  'c claude off':       cmd_claudeOff,
  'c claude':           cmd_claudeStatus,
""",
"",  # drop them entirely from the operator surface
"remove-claude-exact")

# --- 5b. form parser: prefix-optional name + price: line --------------------
code = replace_once(code,
"var formName = (firstLineParts.length >= 2 && firstLineParts[0] === 'c') ? firstLineParts[1] : null;",
"""var formName = null;
if (firstLineParts[0] === 'c' && firstLineParts.length >= 2) { formName = firstLineParts[1]; }
else if (firstLineParts[0] && firstLineParts[0] !== 'c') { formName = firstLineParts[0]; }""",
"form-name")

code = replace_once(code,
"""var formOrderLine = null;
var formAddressLine = null;
var formTimeLine = null;""",
"""var formOrderLine = null;
var formAddressLine = null;
var formTimeLine = null;
var formPriceLine = null;""",
"form-price-decl")

code = replace_once(code,
"""  var timeMatch = ln.match(/^time\\s*:\\s*(.*)$/i);
  if (orderMatch) { formOrderLine = orderMatch[1].trim(); }
  else if (addressMatch) { formAddressLine = addressMatch[1].trim(); }
  else if (timeMatch) { formTimeLine = timeMatch[1].trim(); }""",
"""  var timeMatch = ln.match(/^time\\s*:\\s*(.*)$/i);
  var priceMatch = ln.match(/^price\\s*:\\s*(.*)$/i);
  if (orderMatch) { formOrderLine = orderMatch[1].trim(); }
  else if (addressMatch) { formAddressLine = addressMatch[1].trim(); }
  else if (timeMatch) { formTimeLine = timeMatch[1].trim(); }
  else if (priceMatch) { formPriceLine = priceMatch[1].trim(); }""",
"form-price-parse")

# use the parsed price (original always set price:null)
code = replace_once(code,
"""    name: formName.toLowerCase(),
    items: formItems,
    price: null,""",
"""    name: formName.toLowerCase(),
    items: formItems,
    price: (formPriceLine && !isNaN(parseInt(formPriceLine, 10))) ? parseInt(formPriceLine, 10) : null,""",
"form-price-use")

# fix latent half-product bug: the (\d+)([a-z]) split turns '50p' into '50 p'.
# Re-merge '50'+('p'|'c'|'k') so form-style '2 50p' parses as product 50p qty 2.
code = replace_once(code,
"  var itemTokens = formOrderRaw.split(/\\s+/).filter(function(t){return t.length>0;});",
"""  var itemTokens = formOrderRaw.split(/\\s+/).filter(function(t){return t.length>0;});
  // re-merge half-products split by the (\\d+)([a-z]) normalization above
  var __merged = [];
  for (var __mi = 0; __mi < itemTokens.length; __mi++) {
    if (itemTokens[__mi] === '50' && (itemTokens[__mi+1] === 'p' || itemTokens[__mi+1] === 'c' || itemTokens[__mi+1] === 'k')) {
      __merged.push('50' + itemTokens[__mi+1]); __mi++;
    } else { __merged.push(itemTokens[__mi]); }
  }
  itemTokens = __merged;""",
"form-halfproduct-fix")

# the card line still says [no price]; make it reflect parsed price
code = replace_once(code,
"  formCardLines.push(htmlEsc(formPending.name) + '  [no price]');",
"  formCardLines.push(htmlEsc(formPending.name) + '  ' + (formPending.price === null ? '[no price]' : '$' + formPending.price));",
"form-card-price")

# --- 6c. Claude path: prefix-optional (use parse_text, not substring(2)) -----
# edit path sets a clean parse_text
code = replace_once(code,
"""      raw_text: 'c ' + editText,
      needs_parsing: true, is_callback: false,""",
"""      raw_text: 'c ' + editText,
      parse_text: editText,
      needs_parsing: true, is_callback: false,""",
"edit-parse-text")

# fall-through computes a prefix-stripped parse_text
code = replace_once(code,
"""return [{
  json: {
    chat_id: chatId, user_id: userId, raw_text: rawText,
    needs_parsing: true, is_callback: false,
    is_edit: false, edit_target: 'none'
  }
}];""",
"""var __claudeText = rawText;
if (__claudeText.toLowerCase().indexOf('c ') === 0) { __claudeText = __claudeText.slice(2); }
return [{
  json: {
    chat_id: chatId, user_id: userId, raw_text: __claudeText, parse_text: __claudeText,
    needs_parsing: true, is_callback: false,
    is_edit: false, edit_target: 'none'
  }
}];""",
"fallthrough-parse-text")

# --- 8. Help text: prefix-free, Claude removed -------------------------------
new_help = (
"function cmd_help() {\n"
"  return send('OPERATOR COMMANDS\\n(type a command, or tap the keyboard \\u2014 send kb to show it)\\n\\n"
"NEW ORDER\\n  new                       intake menu (free-form / form)\\n  free-form: maya 2 50p 65 10pm 4520 papineau\\n  form (multi-line):\\n    maya\\n    order: 2 50p\\n    address: 4520 papineau\\n    price: 65        (optional)\\n    time: 10pm       (optional, blank = asap)\\n  on the card: \\u2705 approve \\u00b7 \\ud83d\\udfe7 front \\u00b7 \\u274c cancel\\n\\n"
"JOBS\\n  jobs                      list active orders\\n  edit ord-N <new>          update an order\\n  cancel ord-N              drop a pending order\\n  void ord-N                reverse an approved order\\n  undo                      reverse last approval (5min)\\n  jobs reset                wipe approved orders (confirm)\\n  jobs reset hard           wipe orders + reset ord-N (confirm)\\n  summary                   paste-ready report\\n  backup                    state JSON to DM\\n\\n"
"WALLET\\n  wallet                    cash, pay, total, front out\\n  wallet add <n>            deposit cash\\n  wallet sub <n>            withdraw cash\\n  wallet set <n>            overwrite cash\\n  wallet reset              cash to 0\\n  wallet pay add/sub/set <n>  adjust pay\\n  wallet pay reset          pay to 0\\n  wallet paid <name> [amt]  client paid (full/partial)\\n  (keyboard Add / Sub / Paid ask for the value as a prompt)\\n\\n"
"FRONT\\n  front                     list open tabs\\n  front <name>              one client tab\\n  front ord-N <amt>         mark order fronted\\n  front void <name> ord-N   forgive a fronted order\\n  (or tap \\ud83d\\udfe7 on an order card, then send the amount)\\n\\n"
"CLIENTS\\n  clients                   list clients\\n  client <name> [balance]   history / outstanding balance\\n\\n"
"INVENTORY\\n  inv                       show stock\\n  inv add c=10 p=5          add to stock\\n  inv set c=8               overwrite stock\\n  inv reset [product]       zero all stock, or one product\\n\\n"
"KEYBOARD\\n  kb / keyboard             show the button pad\\n\\n"
"DISPATCH\\n  eta <address>             real-time ETA');\n"
"}"
)
_hs = code.index('function cmd_help() {')
_he = code.index('\n}', _hs) + len('\n}')
assert code[_hs:_hs+40].startswith('function cmd_help()'), "help anchor drift"
assert 'INVENTORY' in code[_hs:_he] and 'FORM-STYLE' in code[_hs:_he], "help body drift"
code = code[:_hs] + new_help + code[_he:]

# --- front-reply fallback: bare number consumes a pending front prompt --------
# Keeps the exact reply_to_message.message_id match as the primary path; adds a
# chat-scoped fallback for dropped/mis-targeted reply context (esp. iOS).
# Fires ONLY when a front_prompt is pending and the message is a lone number;
# routes into the existing `c front ord-N <amt>` path. No other behavior changes.
code = replace_once(code,
"""  // No `else suppress` branch anymore: if the reply isn't a front_prompt,
  // fall through to normal routing. iOS sticky-reply context where the
  // user types a regular command will now reach dispatch instead of being
  // silently swallowed (v7.5.1's bug).
}""",
"""  // No `else suppress` branch anymore: if the reply isn't a front_prompt,
  // fall through to normal routing. iOS sticky-reply context where the
  // user types a regular command will now reach dispatch instead of being
  // silently swallowed (v7.5.1's bug).
}

// ----- front-reply fallback (dropped/mis-targeted reply context) -------------
// The 🟧 front prompt is the only feature still relying on Telegram reply
// context, which iOS frequently drops. When a front prompt is pending, a bare
// positive number is taken as the front amount (most recent prompt by ts) and
// routed into the existing `c front ord-N <amt>` path. Fires ONLY when a
// front_prompt exists, so no other parsing or flow is affected.
if (text.indexOf('c ') !== 0 && /^\\d+$/.test((rawText || '').trim())
    && data.front_prompts && Object.keys(data.front_prompts).length > 0) {
  var __fpKeys = Object.keys(data.front_prompts);
  var __fpLatest = __fpKeys[0];
  var __fk;
  for (__fk = 1; __fk < __fpKeys.length; __fk++) {
    if ((data.front_prompts[__fpKeys[__fk]].ts || 0) > (data.front_prompts[__fpLatest].ts || 0)) { __fpLatest = __fpKeys[__fk]; }
  }
  var __fpRec2 = data.front_prompts[__fpLatest];
  var __fpAmt2 = parseInt((rawText || '').trim(), 10);
  delete data.front_prompts[__fpLatest];
  if (!isNaN(__fpAmt2) && __fpAmt2 > 0) {
    text = 'c front ' + __fpRec2.order_id + ' ' + __fpAmt2;
    rawText = text;
  } else {
    return [{ json: { chat_id: chatId, text: 'bad amount, front cancelled', is_callback: false, needs_parsing: false } }];
  }
}""",
"front-reply-fallback")

# --- front display detail + pending-card maps link (output only) -------------
# read-only helpers: plain maps URL + compact "Mon DD" date (reuse montrealDateStr)
code = replace_once(code,
"function send(textOut) {",
r"""function mapsUrlPlain(addr) {
  if (!addr) { return ''; }
  var full = addr;
  if (!/montreal|laval|brossard|quebec|qc/i.test(addr)) { full = addr + ', Montreal, QC, Canada'; }
  return 'https://maps.google.com/?q=' + encodeURIComponent(full);
}
function montrealMonDay(ts) {
  if (!ts) { return ''; }
  var __dp = montrealDateStr(ts).split('-');
  var __mn = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return __mn[parseInt(__dp[1], 10) - 1] + ' ' + parseInt(__dp[2], 10);
}
function send(textOut) {""",
"front-helpers")

# look up the order behind a front entry (open order, else pending, else void)
_NEW_CMD_FRONT = r"""function cmd_front() {
  var entries = [];
  var tn;
  for (tn in data.front) {
    if (data.front.hasOwnProperty(tn) && data.front[tn].orders) {
      var oj;
      for (oj = 0; oj < data.front[tn].orders.length; oj++) {
        if (data.front[tn].orders[oj].amount > 0) { entries.push({ name: tn, fe: data.front[tn].orders[oj] }); }
      }
    }
  }
  if (entries.length === 0) { return send('no open tabs'); }
  entries.sort(function (a, b) { return (a.fe.ts || 0) - (b.fe.ts || 0); });
  var lines = [];
  lines.push('OPEN TABS  ·  ' + entries.length);
  var grand = 0;
  var i;
  for (i = 0; i < entries.length; i++) {
    var nm = entries[i].name;
    var fe = entries[i].fe;
    var ord = null, oi;
    for (oi = 0; oi < data.orders.length; oi++) { if (data.orders[oi].id === fe.id) { ord = data.orders[oi]; break; } }
    if (!ord && data.pending && data.pending[fe.id]) { ord = data.pending[fe.id]; }
    if (!ord) { for (oi = 0; oi < data.voids.length; oi++) { if (data.voids[oi].id === fe.id) { ord = data.voids[oi]; break; } } }
    var dts = ord ? (ord.approved_at || ord.entered_at || fe.ts) : fe.ts;
    lines.push(nm + '  ·  $' + fe.amount);
    lines.push(fe.id + '  ·  ' + montrealMonDay(dts));
    if (ord && ord.items) { lines.push(itemsToStr(ord.items)); }
    if (ord && ord.address) { lines.push(ord.address); }
    grand = grand + fe.amount;
  }
  lines.push('total owed: $' + grand);
  return send(lines.join('\n'));
}"""
_fs = code.index('function cmd_front() {')
_fe = code.index('\n}', _fs) + len('\n}')
assert 'OPEN TABS' in code[_fs:_fe], "cmd_front anchor drift"
code = code[:_fs] + _NEW_CMD_FRONT + code[_fe:]

_NEW_CMD_FRONTNAME = r"""function cmd_frontName(arg) {
  var parts = arg.split(/\s+/);
  if (parts.length === 0 || !parts[0]) { return send('format: c front <name>'); }
  var name = parts[0];
  if (!data.front[name] || data.front[name].total === 0) { return send(name + ' has no open tab'); }
  var rec = data.front[name];
  var lines = [];
  lines.push(name.toUpperCase() + '  ·  TAB');
  var i;
  for (i = 0; i < rec.orders.length; i++) {
    var fe = rec.orders[i];
    if (!(fe.amount > 0)) { continue; }
    var ord = null, oi;
    for (oi = 0; oi < data.orders.length; oi++) { if (data.orders[oi].id === fe.id) { ord = data.orders[oi]; break; } }
    if (!ord && data.pending && data.pending[fe.id]) { ord = data.pending[fe.id]; }
    if (!ord) { for (oi = 0; oi < data.voids.length; oi++) { if (data.voids[oi].id === fe.id) { ord = data.voids[oi]; break; } } }
    var origPrice = ord ? ord.price : null;
    var dts = ord ? (ord.approved_at || ord.entered_at || fe.ts) : fe.ts;
    if (origPrice !== null && origPrice !== undefined && fe.amount < origPrice) {
      lines.push(name + '  ·  $' + fe.amount + ' of $' + origPrice);
    } else {
      lines.push(name + '  ·  $' + fe.amount);
    }
    lines.push(fe.id + '  ·  ' + montrealMonDay(dts));
    if (ord && ord.items) { lines.push(itemsToStr(ord.items)); }
    if (ord && ord.address) { lines.push(ord.address); }
  }
  lines.push('total: $' + rec.total);
  return send(lines.join('\n'));
}"""
_ns = code.index('function cmd_frontName(arg) {')
_ne = code.index('\n}', _ns) + len('\n}')
assert 'has no open tab' in code[_ns:_ne], "cmd_frontName anchor drift"
code = code[:_ns] + _NEW_CMD_FRONTNAME + code[_ne:]

# form-parser pending card: add a plain Maps line
code = replace_once(code,
"  formCardLines.push(htmlEsc(formTime || '[no time]') + '  ' + htmlEsc(formPending.address) + ' ' + mapsLink(formPending.address));",
"  formCardLines.push(htmlEsc(formTime || '[no time]') + '  ' + htmlEsc(formPending.address) + ' ' + mapsLink(formPending.address));\n  formCardLines.push('Maps: ' + mapsUrlPlain(formPending.address));",
"form-card-maps")

# write code back
nodes['Code']['parameters']['jsCode'] = code

# --- Parse Response (Claude-path pending card): maps helper + Maps line -------
_pr = nodes['Parse Response']['parameters']['jsCode']
_pr = _pr.replace(
"function timeLabel(v) { return v || '[no time]'; }",
"function timeLabel(v) { return v || '[no time]'; }\n"
"function mapsUrlPlain(addr) { if (!addr) { return ''; } var full = addr; if (!/montreal|laval|brossard|quebec|qc/i.test(addr)) { full = addr + ', Montreal, QC, Canada'; } return 'https://maps.google.com/?q=' + encodeURIComponent(full); }",
1)
_pr = _pr.replace(
"finalCardLines.push(timeStrFinal + '  ' + pending.address);",
"finalCardLines.push(timeStrFinal + '  ' + pending.address);\nfinalCardLines.push('Maps: ' + mapsUrlPlain(pending.address));",
1)
assert _pr.count('mapsUrlPlain') == 2, "parse response maps anchors"
nodes['Parse Response']['parameters']['jsCode'] = _pr

# --- 9. Callback handler: handle new_order:freeform|form --------------------
cb = nodes['Callback Handler']['parameters']['jsCode']
cb = replace_once(cb,
"""} else if (action === 'discard_action') {""",
"""} else if (action === 'new_order') {
  // token is 'freeform' or 'form'. Stage an intake prompt so the operator's
  // next message is treated as the order text in the chosen mode.
  if (!data.ui_prompts) { data.ui_prompts = {}; }
  data.ui_prompts[chatId] = { type: 'new_order_' + token, staged_at: nowTs, staged_by: userId };
  responseText = (token === 'form')
    ? 'form-style: send\\nname\\norder: ...\\naddress: ...\\nprice: ...\\ntime: ... (blank=asap)'
    : 'free-form: send one line\\nexample: maya 2 50p 65 10pm 4520 papineau';
  auditAction = 'new_order_prompt';
} else if (action === 'discard_action') {""",
"cb-new-order")
nodes['Callback Handler']['parameters']['jsCode'] = cb

# --- 7. Auth gate: drop the 'c'-prefix condition, keep auth + existence ------
gate = nodes['If']['parameters']['conditions']['conditions']
assert len(gate) == 3, f"gate expected 3 conditions, got {len(gate)}"
# condition[1] is the 'startsWith c' ternary — remove it
del gate[1]
assert len(gate) == 2

# --- Claude node: use parse_text instead of raw_text.substring(2) ------------
cn = nodes['Claude Parser']['parameters']
assert '$json.raw_text.substring(2)' in cn['jsonBody'], "claude body anchor missing"
cn['jsonBody'] = cn['jsonBody'].replace('$json.raw_text.substring(2)', '$json.parse_text || $json.raw_text')

# --- externalize secrets out of the workflow JSON (staging/prod precondition) -
# Telegram bot token in the 4 raw HTTP sender node URLs -> $env.TELEGRAM_BOT_TOKEN
import re as _re
# Match the `bot<...>` segment of the Telegram API URL (real token OR a redacted
# placeholder), up to the next path slash. Idempotent: re-running on an already
# externalized URL leaves it unchanged.
_tok_re = _re.compile(r'bot[^/"]+')
_tok_nodes = ['Send Card HTTP', 'Send ETA Card HTTP', 'Send Snippet HTTP', 'Send Backup Document']
for _nm in _tok_nodes:
    _u = nodes[_nm]['parameters'].get('url', '')
    assert _tok_re.search(_u), 'expected inline bot token in ' + _nm
    _u2 = _tok_re.sub('bot{{ $env.TELEGRAM_BOT_TOKEN }}', _u)
    nodes[_nm]['parameters']['url'] = ('=' if not _u2.startswith('=') else '') + _u2

# Dispatch URL + secret inline in Code and Callback Handler -> $env
def _externalize_dispatch(js):
    js2 = _re.sub(r"var DISPATCH_ETA_URL(\s*)= '[^']*';",
                  r"var DISPATCH_ETA_URL\1= $env.DISPATCH_ETA_URL;", js)
    js2 = _re.sub(r"var DISPATCH_SECRET(\s*)= '[^']*';",
                  r"var DISPATCH_SECRET\1= $env.DISPATCH_SECRET;", js2)
    return js2
for _nm in ['Code', 'Callback Handler']:
    _js = nodes[_nm]['parameters']['jsCode']
    _new = _externalize_dispatch(_js)
    assert _new != _js, 'dispatch externalization no-op in ' + _nm
    nodes[_nm]['parameters']['jsCode'] = _new

# bump workflow name so it's distinguishable on import
d['name'] = 'concierge (hardened operator UX)'

json.dump(d, open(DST, 'w'), indent=2, ensure_ascii=False)
print("wrote", DST)
print("Code node bytes:", len(nodes['Code']['parameters']['jsCode']))
