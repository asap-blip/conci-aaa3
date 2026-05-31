#!/usr/bin/env python3
"""
build_eta_workflow.py — produce n8n/eta.workflow.json (a SEPARATE workflow).

Standalone ETA / dispatch module. Does NOT touch any concierge.* file. Embeds the
shared n8n/lib/eta.js (pure logic) into the Code nodes and adds the network glue:
  - dispatch ETA via $env.DISPATCH_ETA_URL / DISPATCH_SECRET (this.helpers.httpRequest)
  - read-only driver queue from concierge state_doc via $env.SUPABASE_*
  - Telegram I/O via $env.ETA_BOT_TOKEN (separate ETA bot)
Quote staging lives in this workflow's own static data (ephemeral; quick quotes).
"""
import json, re

# ---- embed the shared module (strip the module.exports tail) ----------------
eta = open('n8n/lib/eta.js').read()
eta_embed = eta[:eta.index("if (typeof module !== 'undefined')")].rstrip()

PRELUDE = """// ===== ETA workflow Code node (standalone) ==================================
const SUPA_URL = $env.SUPABASE_URL;
const SUPA_KEY = $env.SUPABASE_SERVICE_ROLE_KEY;
const DISPATCH_URL = $env.DISPATCH_ETA_URL;
const DISPATCH_SECRET = $env.DISPATCH_SECRET;
const httpRequest = this.helpers.httpRequest.bind(this.helpers);
const store = $getWorkflowStaticData('global');
if (!store.quotes) { store.quotes = {}; }
"""

GLUE = r"""
// dispatch ETA for one address (driver forwarded for future per-driver GPS)
async function dispatchETA(address, driver) {
  if (!DISPATCH_URL) { return { ok: false, error: 'DISPATCH_ETA_URL not set' }; }
  try {
    var r = await httpRequest({ method: 'POST', url: DISPATCH_URL,
      body: { address: address, auth: DISPATCH_SECRET, driver: driver }, json: true, timeout: 8000 });
    return r || { ok: false, error: 'empty response' };
  } catch (e) { return { ok: false, error: String((e && e.message) || e).slice(0, 90) }; }
}
// read-only: this driver's active jobs from concierge state_doc, each with a direct ETA
async function driverQueue(driver) {
  if (!SUPA_URL || !SUPA_KEY) { return []; }
  var orders = [];
  try {
    var res = await httpRequest({ method: 'GET',
      url: String(SUPA_URL).replace(/\/+$/, '') + '/rest/v1/state_doc?select=doc',
      headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY, 'Accept-Profile': 'concierge' },
      json: true, timeout: 8000 });
    var rows = Array.isArray(res) ? res : [];
    orders = (rows.length && rows[0].doc && rows[0].doc.orders) ? rows[0].doc.orders : [];
  } catch (e) { return []; }
  var out = [];
  for (var i = 0; i < orders.length && out.length < 6; i++) {
    if ((orders[i].driver || '') !== driver) { continue; }
    var d = await dispatchETA(orders[i].address, driver);
    if (d && d.ok && typeof d.eta_minutes === 'number') {
      out.push({ client: orders[i].name, address: orders[i].address, minutes: d.eta_minutes });
    }
  }
  return out.sort(function (a, b) { return a.minutes - b.minutes; });
}
async function quote(parsed, driver) {
  var disp = await dispatchETA(parsed.address, driver);
  var queue = disp.ok ? await driverQueue(driver) : [];
  return etaBuildPayload(parsed, driver, disp, queue, Date.now());
}
"""

QUOTE_MAIN = r"""
// --- message path: produce a quote card -------------------------------------
var msg = $json.message;
var chatId = msg.chat.id;
var rawText = msg.text || '';
var parsed = etaParseInput(rawText);
if (!parsed.ok) {
  return [{ json: { chat_id: chatId, text: parsed.error, telegram_body: { chat_id: chatId, text: parsed.error } } }];
}
var driver = 'T';
var payload = await quote(parsed, driver);
var qid = 'q' + Date.now() + Math.floor(Math.random() * 1000);
store.quotes[qid] = { parsed: parsed, driver: driver, ts: Math.floor(Date.now() / 1000) };
var text = etaRenderText(payload);
return [{ json: {
  chat_id: chatId, text: text,
  telegram_body: { chat_id: chatId, text: text, reply_markup: { inline_keyboard: etaButtons(qid, driver) } }
} }];
"""

CALLBACK_MAIN = r"""
// --- callback path: driver switch / apply (no-op) / cancel ------------------
var cb = $json.callback_query;
var chatId = cb.message.chat.id;
var msgId = cb.message.message_id;
var cbId = cb.id;
var parts = (cb.data || '').split(':');
var action = parts[0], qid = parts[1];
var q = store.quotes[qid];
var editText = '', editMarkup = null, answerText = '';
if (!q) {
  editText = 'ETA quote expired — send `eta` again.';
} else if (action === 'eta_drv') {
  var drv = parts[2] === 'FISTON' ? 'FISTON' : 'T';
  q.driver = drv;
  var pl = await quote(q.parsed, drv);
  editText = etaRenderText(pl);
  editMarkup = { inline_keyboard: etaButtons(qid, drv) };
  answerText = 'driver: ' + drv;
} else if (action === 'eta_apply') {
  var pl2 = await quote(q.parsed, q.driver);
  editText = etaRenderText(pl2) + '\n\n⚠ Apply as order is NOT wired yet (no-op).\norder_draft kept for the main workflow: '
    + JSON.stringify(pl2.apply.order_draft);
  answerText = 'apply not wired yet';
  delete store.quotes[qid];
} else if (action === 'eta_cancel') {
  editText = 'ETA quote cancelled.';
  delete store.quotes[qid];
}
return [{ json: { chat_id: chatId, message_id: msgId, callback_query_id: cbId,
  edit_text: editText, edit_markup: editMarkup, answer_text: answerText } }];
"""

quote_code = PRELUDE + "\n" + eta_embed + "\n" + GLUE + QUOTE_MAIN
callback_code = PRELUDE + "\n" + eta_embed + "\n" + GLUE + CALLBACK_MAIN

TG = "=https://api.telegram.org/bot{{ $env.ETA_BOT_TOKEN }}"
AUTH_USERS = "[7865010991, 8302116388]"

wf = {
  "name": "eta (standalone dispatch/ETA module)",
  "nodes": [
    { "parameters": { "updates": ["message", "callback_query"], "additionalFields": {} },
      "type": "n8n-nodes-base.telegramTrigger", "typeVersion": 1.1, "position": [-1200, 0],
      "id": "eta00000-trig-0000-000000000001", "name": "ETA Trigger",
      "credentials": { "telegramApi": { "id": "REPLACE_WITH_ETA_BOT_CREDENTIAL", "name": "eta bot" } },
      "webhookId": "eta-standalone-webhook-0001" },
    { "parameters": { "conditions": { "options": { "caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 3 },
        "conditions": [
          { "id": "eta-exists-0001", "leftValue": "={{ $json.message?.text || $json.callback_query?.id }}", "rightValue": "", "operator": { "type": "string", "operation": "exists", "singleValue": True } },
          { "id": "eta-auth-0001", "leftValue": "={{ " + AUTH_USERS + ".includes($json.message?.from?.id || $json.callback_query?.from?.id) }}", "rightValue": "true", "operator": { "type": "boolean", "operation": "true", "singleValue": True } }
        ], "combinator": "and" }, "options": {} },
      "type": "n8n-nodes-base.if", "typeVersion": 2.3, "position": [-980, 0],
      "id": "eta00000-gate-0000-000000000001", "name": "ETA Gate" },
    { "parameters": { "rules": { "values": [
        { "conditions": { "options": { "caseSensitive": True, "leftValue": "", "typeValidation": "loose" },
          "conditions": [ { "leftValue": "={{ $json.message?.message_id }}", "rightValue": "", "operator": { "type": "string", "operation": "exists", "singleValue": True } } ], "combinator": "and" },
          "renameOutput": True, "outputKey": "message" },
        { "conditions": { "options": { "caseSensitive": True, "leftValue": "", "typeValidation": "loose" },
          "conditions": [ { "leftValue": "={{ $json.callback_query?.id }}", "rightValue": "", "operator": { "type": "string", "operation": "exists", "singleValue": True } } ], "combinator": "and" },
          "renameOutput": True, "outputKey": "callback" }
      ] }, "options": { "looseTypeValidation": True } },
      "type": "n8n-nodes-base.switch", "typeVersion": 3, "position": [-760, 0],
      "id": "eta00000-switch-0000-00000000001", "name": "ETA Switch" },
    { "parameters": { "jsCode": quote_code }, "type": "n8n-nodes-base.code", "typeVersion": 2,
      "position": [-520, -120], "id": "eta00000-quote-0000-000000000001", "name": "ETA Quote" },
    { "parameters": { "method": "POST", "url": TG + "/sendMessage", "sendHeaders": True,
        "headerParameters": { "parameters": [ { "name": "content-type", "value": "application/json" } ] },
        "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.telegram_body) }}", "options": {} },
      "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4, "position": [-300, -120],
      "id": "eta00000-send-0000-000000000001", "name": "ETA Send Card" },
    { "parameters": { "jsCode": callback_code }, "type": "n8n-nodes-base.code", "typeVersion": 2,
      "position": [-520, 140], "id": "eta00000-cback-0000-000000000001", "name": "ETA Callback" },
    { "parameters": { "method": "POST", "url": TG + "/editMessageText", "sendHeaders": True,
        "headerParameters": { "parameters": [ { "name": "content-type", "value": "application/json" } ] },
        "sendBody": True, "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify(Object.assign({ chat_id: $json.chat_id, message_id: $json.message_id, text: $json.edit_text }, $json.edit_markup ? { reply_markup: $json.edit_markup } : {})) }}",
        "options": {} },
      "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4, "position": [-300, 140],
      "id": "eta00000-edit-0000-000000000001", "name": "ETA Edit Card" },
    { "parameters": { "method": "POST", "url": TG + "/answerCallbackQuery", "sendHeaders": True,
        "headerParameters": { "parameters": [ { "name": "content-type", "value": "application/json" } ] },
        "sendBody": True, "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ callback_query_id: $json.callback_query_id, text: $json.answer_text || '' }) }}",
        "options": {} },
      "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4, "position": [-80, 140],
      "id": "eta00000-ans-0000-0000000000001", "name": "ETA Answer Callback" }
  ],
  "connections": {
    "ETA Trigger": { "main": [[{ "node": "ETA Gate", "type": "main", "index": 0 }]] },
    "ETA Gate": { "main": [[{ "node": "ETA Switch", "type": "main", "index": 0 }]] },
    "ETA Switch": { "main": [
      [{ "node": "ETA Quote", "type": "main", "index": 0 }],
      [{ "node": "ETA Callback", "type": "main", "index": 0 }]
    ] },
    "ETA Quote": { "main": [[{ "node": "ETA Send Card", "type": "main", "index": 0 }]] },
    "ETA Callback": { "main": [[{ "node": "ETA Edit Card", "type": "main", "index": 0 }]] },
    "ETA Edit Card": { "main": [[{ "node": "ETA Answer Callback", "type": "main", "index": 0 }]] }
  },
  "active": False, "settings": { "executionOrder": "v1" }, "pinData": {}, "tags": []
}

json.dump(wf, open('n8n/eta.workflow.json', 'w'), indent=2, ensure_ascii=False)
print("wrote n8n/eta.workflow.json")
print("ETA Quote bytes:", len(quote_code), "| ETA Callback bytes:", len(callback_code))
