import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accountId, parseProducts, productCredits } from '../supabase/functions/_shared/polar.ts';
import { validateEvent } from '@polar-sh/sdk/webhooks';

test('Polar fulfillment trusts only configured products and external account IDs', () => {
  const products = parseProducts('{"product_1":100}');
  assert.equal(productCredits(products, 'product_1'), 100);
  for (const id of [null, 'unknown', 'toString']) assert.throws(() => productCredits(products, id));
  for (const raw of ['null', '[]', '{}', '{"x":0}', '{"x":-1}', '{"x":1.5}', '{"x":"100"}']) assert.throws(() => parseProducts(raw));
  assert.equal(accountId('11111111-1111-4111-8111-111111111111'), '11111111-1111-4111-8111-111111111111');
  for (const id of [null, undefined, '', 'not-a-user']) assert.throws(() => accountId(id));
});
test('Polar rejects unsigned and forged webhook bodies', () => {
  assert.throws(() => validateEvent('{"type":"order.paid"}', {}, 'test-secret'));
  assert.throws(() => validateEvent('{}', { 'webhook-id': 'fake', 'webhook-timestamp': '1', 'webhook-signature': 'v1,fake' }, 'test-secret'));
});
