import { defineCartridge } from '../src/config.js';

export const cartridgeConfig = defineCartridge({
  name: 'turnip-stalk-market',
  version: '1.0.0',
  description: 'Animal Crossing–style turnip stalk market. Trade turnips through MCP tools; prices move on a compressed weekly clock.',
  sop: [
    'Always call get_market first. It advances the demo clock and returns phase, prices, and seconds_until_next_slot.',
    'Sunday (slot_index 0) is buy_window: use buy_turnips. Slots 1–12 are sell_window: use sell_turnips.',
    'On ok:false, read error_code and remediation. Do not blind-retry mutations.',
    'Turnips rot when the week ends (after slot 12). Unsold holdings become worthless.',
    'Call get_portfolio for bell_balance, holdings, unrealized P/L. Call get_leaderboard for rankings.',
    'cartridge_undo is only safe for trades in the same price window at the same unit_price. Prefer not undoing trades unless the user insists immediately.',
    'Billing top-ups are off by default; game wealth is player_holdings.bell_balance (500 bells on signup).',
  ],
  queries: [
    {
      name: 'get_portfolio',
      description: 'Your bell balance, turnip holdings, cost basis, unrealized P/L, and holding status.',
      table: 'v_player_portfolio',
      filterColumn: 'owner_id',
    },
    {
      name: 'get_leaderboard',
      description: 'Net worth leaderboard (bells + mark-to-market turnips).',
      table: 'v_leaderboard',
      orderBy: 'rank',
    },
    {
      name: 'get_price_history',
      description: 'Logged market prices (no future slots).',
      table: 'market_price_log',
      orderBy: 'logged_at',
    },
  ],
  intents: [
    {
      name: 'get_market',
      rpcName: 'rpc_get_market',
      description: 'Current market phase, prices, time until next slot, and recent history. Advances the clock.',
      creditCostNote: 'Free.',
      params: {},
    },
    {
      name: 'buy_turnips',
      rpcName: 'rpc_buy_turnips',
      description: 'Buy n turnips during Sunday buy_window at the current buy_price.',
      creditCostNote: 'Free; spends in-game bells.',
      params: {
        p_qty: { type: 'number', description: 'Number of turnips to buy (positive integer).' },
      },
    },
    {
      name: 'sell_turnips',
      rpcName: 'rpc_sell_turnips',
      description: 'Sell n turnips during a sell_window at the current sell_price.',
      creditCostNote: 'Free; credits in-game bells.',
      params: {
        p_qty: { type: 'number', description: 'Number of turnips to sell (positive integer).' },
      },
    },
  ],
});