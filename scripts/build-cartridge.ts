import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { cartridgeConfig } from '../domain/cartridge.config.js';
import { compileCartridge } from '../src/compiler.js';

const endpoint = process.env.CARTRIDGE_MCP_URL ?? 'http://127.0.0.1:54321/functions/v1/mcp';
const output = compileCartridge(cartridgeConfig, endpoint);
const files: Record<string, string> = {
  'dist/mcp-manifest.json': JSON.stringify(output.manifest, null, 2),
  'dist/.mcp.json': JSON.stringify(output.mcp, null, 2),
  'dist/skills/SKILL.md': output.skill,
  'supabase/functions/mcp/mcp-manifest.json': JSON.stringify(output.manifest, null, 2),
  'supabase/functions/mcp/skill.json': JSON.stringify(output.skill),
  'public/oauth/consent/config.json': JSON.stringify({
    supabaseUrl: process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321',
    publishableKey: process.env.SUPABASE_ANON_KEY ?? '',
  }, null, 2),
};
for (const [path, content] of Object.entries(files)) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content + '\n');
}
console.log(`Built ${Object.keys(files).length} artifacts for ${endpoint}`);
