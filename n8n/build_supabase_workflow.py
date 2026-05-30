#!/usr/bin/env python3
"""
build_supabase_workflow.py
Produce n8n/concierge.supabase.workflow.json from the hardened workflow by
cutting the two god nodes over from n8n static data to the Supabase state bridge
(db/migrations/0004_state_bridge.sql).

Transform per node (Code router + Callback Handler), all assertion-guarded:
  * prepend a SUPABASE STATE BRIDGE prelude (db client, loadState/saveState,
    __actor) that runs where `this`/$json/$env are valid;
  * declare `let data;` in the prelude and change the body so
    `var data = $getWorkflowStaticData('global')` becomes `data = await loadState()`;
  * neutralize the inner `var httpRequest = this.helpers...` (uses prelude __http);
  * wrap the whole body in `async function __main(){...}` and finish with
    `const __out = await __main(); await saveState(data); return __out;`
  * router pushLog() also appends to data.__events (durable audit);
  * callback's audit log push also appends to data.__events.

Nothing about the accounting/render logic changes — only where state lives.
"""
import json, sys

SRC = 'n8n/concierge.hardened.workflow.json'
DST = 'n8n/concierge.supabase.workflow.json'

d = json.load(open(SRC))
nodes = {n['name']: n for n in d['nodes']}

PRELUDE = """// ===== SUPABASE STATE BRIDGE (cutover) ======================================
// State now lives in Supabase (db/migrations/0004_state_bridge.sql), not n8n
// static data. Config comes from n8n env (never inline secrets):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
const __SUPA_URL = $env.SUPABASE_URL;
const __SUPA_KEY = $env.SUPABASE_SERVICE_ROLE_KEY;
const __http = this.helpers.httpRequest.bind(this.helpers);
const __actor = ($json.message && $json.message.from && $json.message.from.id)
  || ($json.callback_query && $json.callback_query.from && $json.callback_query.from.id) || null;
function __rpc(fn, args) {
  return __http({
    method: 'POST',
    url: String(__SUPA_URL).replace(/\\/+$/, '') + '/rest/v1/rpc/' + fn,
    headers: {
      apikey: __SUPA_KEY, Authorization: 'Bearer ' + __SUPA_KEY,
      'Content-Type': 'application/json',
      'Accept-Profile': 'concierge', 'Content-Profile': 'concierge'
    },
    body: args || {}, json: true, timeout: 8000
  });
}
async function loadState() { return await __rpc('load_state', {}); }
async function saveState(state) {
  return await __rpc('save_state', { p_state: state, p_events: (state && state.__events) || [], p_actor: __actor });
}
let data;
// ============================================================================

async function __main() {
"""

TRAILER = """
}
const __out = await __main();
await saveState(data);
return __out;
"""

def transform(js, is_router):
    # 1. data source -> Supabase
    needle = "var data = $getWorkflowStaticData('global');"
    assert js.count(needle) == 1, "data source anchor"
    js = js.replace(needle, "data = await loadState();\n  data.__events = [];", 1)

    # 2. neutralize inner httpRequest capture (this.* invalid inside __main)
    hr = "var httpRequest = this.helpers.httpRequest.bind(this.helpers);"
    assert js.count(hr) == 1, "httpRequest anchor"
    js = js.replace(hr, "var httpRequest = __http; // bridged (prelude)", 1)

    # 3. audit -> durable events
    if is_router:
        old = ("function pushLog(action, details) {\n"
               "  data.log.push({ ts: nowTs, by: userId, action: action, details: details });\n"
               "  if (data.log.length > 500) { data.log = data.log.slice(data.log.length - 500); }\n"
               "}")
        assert js.count(old) == 1, "pushLog anchor"
        new = ("function pushLog(action, details) {\n"
               "  data.log.push({ ts: nowTs, by: userId, action: action, details: details });\n"
               "  if (data.log.length > 500) { data.log = data.log.slice(data.log.length - 500); }\n"
               "  if (!data.__events) { data.__events = []; }\n"
               "  data.__events.push({ actor: userId, entity_type: 'op',\n"
               "    entity_id: (details && (details.token || details.id || details.name || details.product || details.ord)) || null,\n"
               "    action: action, metadata: details || {} });\n"
               "}")
        js = js.replace(old, new, 1)
    else:
        old = ("data.log.push({ ts: nowTs, by: userId, action: auditAction, "
               "details: { token: token, action: action } });")
        assert js.count(old) == 1, "callback audit anchor"
        new = (old + "\nif (!data.__events) { data.__events = []; }\n"
               "data.__events.push({ actor: userId, entity_type: 'op', entity_id: token, "
               "action: auditAction, metadata: { action: action } });")
        js = js.replace(old, new, 1)

    return PRELUDE + js + TRAILER

nodes['Code']['parameters']['jsCode'] = transform(nodes['Code']['parameters']['jsCode'], True)
nodes['Callback Handler']['parameters']['jsCode'] = transform(nodes['Callback Handler']['parameters']['jsCode'], False)

d['name'] = 'concierge (supabase-backed)'
json.dump(d, open(DST, 'w'), indent=2, ensure_ascii=False)
print("wrote", DST)
for nm in ('Code', 'Callback Handler'):
    print(nm, "bytes:", len(nodes[nm]['parameters']['jsCode']))
