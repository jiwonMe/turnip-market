import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

test('engine: cartridge core, billing gate, undo', async () => {
  const db = new PGlite();
  const alice = '11111111-1111-4111-8111-111111111111';
  try {
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
      CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY);
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
      GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;`);
    for (const file of ['000_cartridge_engine.sql', '001_domain_turnip_market.sql', '002_polar_billing.sql', '003_view_security_invoker.sql', '005_executor_current_uid.sql', '006_revoke_future_price_access.sql']) {
      await db.exec(await readFile(new URL(`../supabase/migrations/${file}`, import.meta.url), 'utf8'));
    }
    await db.exec(`INSERT INTO auth.users VALUES ('${alice}');
      SELECT set_config('request.jwt.claim.sub','${alice}',false); SET ROLE authenticated;`);
    async function rpc(sql: string) {
      const r = await db.query<{ result: Record<string, unknown> }>(`SELECT ${sql} AS result`);
      return r.rows[0].result;
    }
    const status = await rpc('rpc_cartridge_status()');
    assert.equal(status.ok, true);
    assert.equal(Number((status as { game_wallet_bells: number }).game_wallet_bells), 500);
    await assert.rejects(db.exec('SELECT cartridge.commit_and_charge(\'x\',\'player_holdings\',\'a\',\'{}\',\'{}\',0)'), /permission denied/);
    const buy = await rpc('rpc_buy_turnips(4)');
    assert.equal(buy.ok, true);
    assert.equal((buy as { charged_credits: number }).charged_credits, 0);
    const undo = await rpc(`rpc_cartridge_undo('${(buy as { audit_id: string }).audit_id}')`);
    assert.equal(undo.ok, true);
    await db.exec(`RESET ROLE; SET ROLE service_role;`);
    assert.equal((await db.query<{ granted: boolean }>(`SELECT admin_grant_credits('cs_1','${alice}',20) AS granted`)).rows[0].granted, false);
    await db.exec(`UPDATE cartridge.settings SET enable_billing_topups = true, checkout_base_url = 'https://example.com/pay';
      SELECT admin_grant_credits('cs_2','${alice}',20);`);
    await db.exec('RESET ROLE; SET ROLE authenticated;');
    assert.equal((await rpc('rpc_cartridge_status()')).game_wallet_bells, 500);
  } finally {
    await db.close();
  }
});