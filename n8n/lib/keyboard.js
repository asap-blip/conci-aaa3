// ============================================================================
// keyboard.js  —  operator control pad (reply keyboard) + button mapping
// ----------------------------------------------------------------------------
// This is the canonical source for the persistent Telegram reply keyboard and
// the button→action map. It is embedded verbatim into the router Code node of
// the n8n workflow (n8n Code nodes cannot require() local files).
//
// Design goals for this pass:
//   * exact 3x3 layout requested by the operator
//   * NO Claude button (Claude stays an internal implementation detail)
//   * "New Order" is a first-class entry point (row 3, col 3)
//   * plain labels — the operator never types or sees the `c` prefix
// ============================================================================

// Exact reply keyboard (rows fixed by spec).
const REPLY_KEYBOARD = {
  keyboard: [
    [{ text: 'Wallet' },  { text: 'Jobs' },   { text: 'Front' }],
    [{ text: 'Add' },     { text: 'Sub' },    { text: 'Paid' }],
    [{ text: 'Summary' }, { text: 'Backup' }, { text: 'New Order' }],
  ],
  resize_keyboard: true,
  is_persistent: true,
  selective: false,
};

// Button label -> behaviour.
//   'command' : map to an internal command name, fall through to dispatch
//   'prompt'  : stage a one-step prompt server-side, ask a plain question
//   'menu'    : open a small inline sub-menu (used by New Order)
//
// Internal command names are PREFIX-FREE. The router's normalize step
// (router_normalize.js) maps both these plain names and any legacy `c xxx`
// typed input onto the same internal handlers.
const BUTTON_COMMANDS = {
  'Wallet':    { type: 'command', cmd: 'wallet' },
  'Jobs':      { type: 'command', cmd: 'jobs' },
  'Front':     { type: 'command', cmd: 'front' },
  'Summary':   { type: 'command', cmd: 'summary' },
  'Backup':    { type: 'command', cmd: 'backup' },
  'Add':       { type: 'prompt', prompt_type: 'wallet_add',
                 prompt_text: 'how much to add to cash?\n(reply with a number, or tap any other button to cancel)' },
  'Sub':       { type: 'prompt', prompt_type: 'wallet_sub',
                 prompt_text: 'how much to withdraw from cash?\n(reply with a number, or tap any other button to cancel)' },
  'Paid':      { type: 'prompt', prompt_type: 'wallet_paid',
                 prompt_text: 'who paid? format: <name> [amount]\nexample: jay 100  (or just: jay for full)\n(or tap any other button to cancel)' },
  'New Order': { type: 'menu', menu: 'new_order' },
};

// Inline sub-menu shown when "New Order" is tapped. Two intake modes.
const NEW_ORDER_MENU = {
  text: [
    'NEW ORDER',
    '────────────────',
    'pick an intake mode:',
    '',
    '• Free-form — one line, e.g.',
    '   maya 2 50p 65 10pm 4520 papineau',
    '',
    '• Form-style — multi-line, e.g.',
    '   maya',
    '   order: 2 50p',
    '   address: 4520 papineau',
    '   price: 65',
    '   time: 10pm   (blank = asap)',
  ].join('\n'),
  reply_markup: {
    inline_keyboard: [[
      { text: 'Free-form',  callback_data: 'new_order:freeform' },
      { text: 'Form-style', callback_data: 'new_order:form' },
    ]],
  },
};

// Exported for embedding (the workflow inlines these literals).
if (typeof module !== 'undefined') {
  module.exports = { REPLY_KEYBOARD, BUTTON_COMMANDS, NEW_ORDER_MENU };
}
