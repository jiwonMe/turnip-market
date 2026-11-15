import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compileCartridge } from '../src/compiler.js';
import { cartridgeConfig } from '../domain/cartridge.config.js';

test('compiler produces one complete manual and manifest', () => {
  const output = compileCartridge(cartridgeConfig, 'https://example.com/functions/v1/mcp');
  assert.deepEqual(output.manifest, cartridgeConfig);
  for (const rule of cartridgeConfig.sop) assert.ok(output.skill.includes(rule));
  assert.ok(output.skill.includes('p_qty'));
  assert.equal(output.mcp.mcpServers['turnip-stalk-market'].type, 'http');
});
test('rejects reserved names, SQL identifiers, invalid enums, and unsafe endpoints', () => {
  for (const changes of [
    { queries: [{ ...cartridgeConfig.queries[0], name: 'cartridge_undo' }] },
    { queries: [{ ...cartridgeConfig.queries[0], table: 'work_sets;drop' }] },
    { intents: [{ ...cartridgeConfig.intents[0], params: { x: { type: 'number', enum: ['a'], description: 'bad' } } }] },
  ]) assert.throws(() => compileCartridge({ ...cartridgeConfig, ...changes }, 'https://example.com/mcp'));
  for (const endpoint of ['http://example.com', 'https://u:p@example.com', 'https://example.com?token=secret']) {
    assert.throws(() => compileCartridge(cartridgeConfig, endpoint));
  }
});
