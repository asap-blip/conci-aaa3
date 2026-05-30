// ============================================================================
// router_normalize.js  —  prefix-free operator surface + legacy compat
// ----------------------------------------------------------------------------
// The operator-facing model drops the `c` prefix entirely. Internally we keep
// a single normalize step that maps:
//   * plain operator words      ("wallet", "jobs", "front 12 40", ...)
//   * keyboard button rewrites  (handled in keyboard.js -> internal cmd)
//   * legacy typed `c xxx`      (TEMPORARY compatibility during transition)
// onto ONE canonical internal command string, then dispatch tables run on that.
//
// Canonical internal commands are themselves prefix-free, e.g.:
//   'wallet'        'wallet add 200'    'jobs'      'front 12 40'
//   'inv'           'inv add c=10'      'eta 7700 decarie'   'new'
//
// Claude is NOT reachable as an operator command here. Free-form order text
// still flows to the internal Claude parser as a fall-through (implementation
// detail), but there is no `claude on/off/status` operator command anymore.
// ============================================================================

// Words that begin a known operator command. Anything starting with one of
// these is treated as a command; everything else is order intake text.
const COMMAND_HEADS = [
  'wallet', 'jobs', 'front', 'inv', 'inventory', 'client', 'clients',
  'summary', 'backup', 'undo', 'cancel', 'void', 'edit', 'eta',
  'add', 'sub', 'paid', 'new', 'help', 'cmd', 'commands', 'kb', 'keyboard',
  'close', 'export', // period closeout (maps to RPCs)
];

// Legacy prefix toggle. Keep true during transition so old muscle-memory
// `c wallet` still works; flip to false to hard-disable the prefix.
const ALLOW_LEGACY_C_PREFIX = true;

// Normalize raw incoming text to a canonical internal command (or null if the
// message is not a command and should be treated as order intake).
//
// Returns { kind: 'command', cmd } | { kind: 'intake' } | { kind: 'empty' }
function normalizeInput(rawText) {
  let text = (rawText || '').trim();
  if (!text) return { kind: 'empty' };

  // Strip a legacy leading "c " (or bare "c") during transition.
  if (ALLOW_LEGACY_C_PREFIX) {
    const low = text.toLowerCase();
    if (low === 'c') return { kind: 'command', cmd: 'help' };
    if (low.startsWith('c ')) text = text.slice(2).trim();
  }

  const low = text.toLowerCase();
  const head = low.split(/\s+/)[0];

  // map a couple of friendly aliases to canonical heads
  const aliasHead =
    head === 'inventory' ? 'inv' :
    head === 'commands'  ? 'help' :
    head === 'cmd'       ? 'help' :
    head === 'keyboard'  ? 'kb' :
    head;

  if (COMMAND_HEADS.indexOf(head) >= 0) {
    // rebuild canonical command with aliased head
    const rest = low.slice(head.length).trim();
    return { kind: 'command', cmd: (aliasHead + (rest ? ' ' + rest : '')).trim() };
  }

  // Not a command head -> order intake (free-form or form-style).
  return { kind: 'intake' };
}

if (typeof module !== 'undefined') {
  module.exports = { normalizeInput, COMMAND_HEADS, ALLOW_LEGACY_C_PREFIX };
}
