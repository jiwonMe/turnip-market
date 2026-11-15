import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const MIGRATIONS = ['000_cartridge_engine.sql', '001_domain_turnip_market.sql', '002_polar_billing.sql'];

async function boot() {
  const db = new PGlite();
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
    CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$
      SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;`);
  for (const file of MIGRATIONS) {
    await db.exec(await readFile(new URL(`../supabase/migrations/${file}`, import.meta.url), 'utf8'));
  }
  return db;
}

async function rpc(db: PGlite, sql: string) {
  const r = await db.query<{ result: Record<string, unknown> }>(`SELECT ${sql} AS result`);
  return r.rows[0].result;
}

test('turnip: buy, sell, funds, rot, determinism, RLS, undo window', async () => {
  const alice = '11111111-1111-4111-8111-111111111111';
  const bob = '22222222-2222-4222-8222-222222222222';
  const db = await boot();
  try {
    await db.exec(`INSERT INTO auth.users VALUES ('${alice}'), ('${bob}');
      SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    const market = await rpc(db, 'rpc_get_market()');
    assert.equal(market.ok, true);
    assert.equal((market as { phase: string }).phase, 'buy_window');
  const buy = await rpc(db, 'rpc_buy_turnips(4)');
    assert.equal(buy.ok, true);
    const unit = (buy as { unit_price: number }).unit_price;
    assert.equal((buy as { bell_balance: number }).bell_balance, 500 - 4 * unit);
    const broke = await rpc(db, 'rpc_buy_turnips(9999)');
    assert.equal(broke.error_code, 'INSUFFICIENT_CREDITS');
    const buyAudit = buy as { audit_id: string };
    const undoOk = await rpc(db, `rpc_cartridge_undo('${buyAudit.audit_id}')`);
    assert.equal(undoOk.ok, true);
    const buyAgain = await rpc(db, 'rpc_buy_turnips(4)');
    assert.equal(buyAgain.ok, true);
    const buy2 = await rpc(db, 'rpc_buy_turnips(1)');
    assert.equal(buy2.ok, true);
    await db.exec(`RESET ROLE; UPDATE public.market_runtime SET slot_index = 1, slot_started_at = now();
      SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    const sell = await rpc(db, 'rpc_sell_turnips(2)');
    assert.equal(sell.ok, true);
    const oversell = await rpc(db, 'rpc_sell_turnips(999)');
    assert.equal(oversell.error_code, 'NOT_ENOUGH_TURNIPS');
    await db.exec(`RESET ROLE; SET ROLE authenticated;`);
    assert.equal((await db.query('SELECT owner_id FROM player_holdings')).rows.length, 1);
    await db.exec(`RESET ROLE; SELECT set_config('request.jwt.claim.sub','${bob}',false); SET ROLE authenticated;`);
    assert.equal((await db.query('SELECT owner_id FROM player_holdings')).rows.length, 1);
    await db.exec(`RESET ROLE; SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    const p1 = await rpc(db, `market_price_for_slot(1, 3, 'sell')`);
    const p2 = await rpc(db, `market_price_for_slot(1, 3, 'sell')`);
    assert.equal(p1, p2);
    const secretLeak = await db
      .query('SELECT seed FROM cartridge.market_week_secrets LIMIT 1')
      .catch((err: Error) => err);
    assert.ok(secretLeak instanceof Error);
    assert.match(secretLeak.message, /permission denied/i);
    await db.exec(`RESET ROLE; UPDATE public.market_runtime SET slot_index = 2 WHERE singleton;
      SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    const undoBad = await rpc(db, `rpc_cartridge_undo('${(buy2 as { audit_id: string }).audit_id}')`);
    assert.equal(undoBad.error_code, 'UNDO_WINDOW_CLOSED');
    await db.exec(`RESET ROLE; UPDATE public.player_holdings SET turnip_qty = 40, turnip_week = 1, turnip_cost_total = 4000 WHERE owner_id = '${alice}';
      UPDATE public.market_runtime SET week_number = 2, slot_index = 1, slot_started_at = now();
      SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    const rotten = await rpc(db, 'rpc_sell_turnips(1)');
    assert.equal(rotten.error_code, 'TURNIPS_ROTTEN');
    await db.exec(`RESET ROLE; UPDATE public.market_runtime SET slot_index = 12, slot_started_at = now() - interval '1 hour';
      SELECT cartridge.market_advance_clock();
      SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    const qty = (await db.query<{ turnip_qty: number }>(
      `SELECT turnip_qty FROM player_holdings WHERE owner_id = '${alice}'`,
    )).rows[0].turnip_qty;
    assert.equal(qty, 0);
  } finally {
    await db.close();
  }
});