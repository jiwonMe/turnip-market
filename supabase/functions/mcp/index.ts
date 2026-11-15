import { McpServer } from 'npm:@modelcontextprotocol/sdk@1.32.2/server/mcp.js';
import { WebStandardStreamableHTTPServerTransport } from 'npm:@modelcontextprotocol/sdk@1.32.2/server/webStandardStreamableHttp.js';
import { createClient } from 'npm:@supabase/supabase-js@2.95.3';
import { z } from 'npm:zod@4.6.7';
import { Polar } from 'npm:@polar-sh/sdk@0.42.5';
import { parseProducts } from '../_shared/polar.ts';
import manifest from './mcp-manifest.json' with { type: 'json' };
import skill from './skill.json' with { type: 'json' };

function env(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}
const supabaseUrl = env('SUPABASE_URL');
const resource = env('CARTRIDGE_MCP_URL').replace(/\/$/, '');
const metadataUrl = `${resource}/.well-known/oauth-protected-resource`;
const allowedOrigins = (Deno.env.get('CARTRIDGE_ALLOWED_ORIGINS') ?? '').split(',').filter(Boolean);
// Supabase commonly issues aud=authenticated. Restrict OAuth clients as well as audience.
const audience = env('CARTRIDGE_TOKEN_AUDIENCE');
const clientIds = env('CARTRIDGE_OAUTH_CLIENT_IDS').split(',').filter(Boolean);
const polarToken = Deno.env.get('POLAR_ACCESS_TOKEN');
const polarServer = Deno.env.get('POLAR_SERVER') ?? 'production';
if (!['production', 'sandbox'].includes(polarServer)) throw new Error('Invalid POLAR_SERVER');
const polar = polarToken ? new Polar({ accessToken: polarToken, server: polarServer as 'production' | 'sandbox' }) : null;
const products = polar ? parseProducts(env('POLAR_PRODUCT_CREDITS')) : {};

function result(data: unknown, error: unknown) {
  const body = error ? { ok: false, error_code: 'DATABASE_ERROR', remediation: 'Check arguments and contact the operator if the problem persists.' } : data;
  return { isError: Boolean(error) || (typeof data === 'object' && data !== null && 'ok' in data && data.ok === false),
    content: [{ type: 'text' as const, text: JSON.stringify(body) }] };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  if (origin && !allowedOrigins.includes(origin)) return new Response('Forbidden origin', { status: 403 });
  const headers = new Headers({ 'Cache-Control': 'no-store', Vary: 'Origin' });
  if (origin) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type, Accept, MCP-Protocol-Version, MCP-Session-Id');
    headers.set('Access-Control-Expose-Headers', 'WWW-Authenticate, MCP-Session-Id');
  }
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  const path = new URL(req.url).pathname;
  if (path.endsWith('/.well-known/oauth-protected-resource') && req.method === 'GET') {
    return Response.json({ resource, authorization_servers: [`${supabaseUrl}/auth/v1`], bearer_methods_supported: ['header'] }, { headers });
  }
  const unauthorized = () => {
    headers.set('WWW-Authenticate', `Bearer error="invalid_token", resource_metadata="${metadataUrl}"`);
    return new Response('Unauthorized', { status: 401, headers });
  };
  const auth = req.headers.get('Authorization');
  if (!auth?.startsWith('Bearer ')) return unauthorized();
  const token = auth.slice(7);
  const db = createClient(supabaseUrl, env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await db.auth.getUser(token);
  if (userError || !userData.user) return unauthorized();
  // Verify signature/expiry before trusting claims; getUser also checks server-side validity.
  const { data: claimData, error: claimError } = await db.auth.getClaims(token);
  const claims = claimData?.claims;
  const aud = claims?.aud;
  if (claimError || !claims || claims.iss !== `${supabaseUrl}/auth/v1` || claims.sub !== userData.user.id ||
      !(Array.isArray(aud) ? aud.includes(audience) : aud === audience) ||
      typeof claims.client_id !== 'string' || !clientIds.includes(claims.client_id) || claims.role !== 'authenticated') return unauthorized();

  const server = new McpServer({ name: manifest.name, version: manifest.version });
  server.registerResource('skill-manual', 'skill://manual', { mimeType: 'text/markdown' }, (uri: URL) => ({
    contents: [{ uri: uri.href, mimeType: 'text/markdown', text: skill }],
  }));
  server.registerPrompt('load_skill_sop', { description: 'Load the complete Cartridge manual.' }, () => ({
    messages: [{ role: 'user', content: { type: 'text', text: skill } }],
  }));
  server.registerTool('cartridge_checkout', {
    description: 'Create a payment link for the signed-in account. Ask the user before purchasing. Omit product_id to list available credit products.',
    inputSchema: { product_id: z.string().optional() },
  }, async ({ product_id }: { product_id?: string }) => {
    if (!polar) return result({ ok: false, error_code: 'BILLING_NOT_CONFIGURED', remediation: 'Contact the operator.' }, null);
    if (!product_id) return result({ ok: true, products }, null);
    if (!Object.hasOwn(products, product_id)) return result({ ok: false, error_code: 'UNKNOWN_PRODUCT', remediation: 'Call cartridge_checkout without product_id to list configured products.' }, null);
    try {
      const checkout = await polar.checkouts.create({ products: [product_id], externalCustomerId: userData.user.id });
      return result({ ok: true, checkout_url: checkout.url, credits_per_paid_order: products[product_id] }, null);
    } catch {
      return result({ ok: false, error_code: 'BILLING_UNAVAILABLE', remediation: 'Checkout creation failed. Contact the operator; no credits were charged by this tool.' }, null);
    }
  });
  server.registerTool('get_billing_portal', {
    description: 'Create a private customer portal link for your receipts and subscription management. Do not share the link.', inputSchema: {},
  }, async () => {
    if (!polar) return result({ ok: false, error_code: 'BILLING_NOT_CONFIGURED', remediation: 'Contact the operator.' }, null);
    try {
      const session = await polar.customerSessions.create({ externalCustomerId: userData.user.id });
      return result({ ok: true, customer_portal_url: session.customerPortalUrl }, null);
    } catch {
      return result({ ok: false, error_code: 'PORTAL_UNAVAILABLE', remediation: 'A billing customer may not exist yet. Contact the operator if you have already paid.' }, null);
    }
  });
  server.registerTool('cartridge_status', { description: 'Read your plan, credits, and checkout URL.', inputSchema: {} }, async () => {
    const { data, error } = await db.rpc('rpc_cartridge_status'); return result(data, error);
  });
  server.registerTool('cartridge_undo', { description: 'Undo an audited update and refund its actual charge.', inputSchema: { p_audit_id: z.string().uuid() } }, async (args: { p_audit_id: string }) => {
    const { data, error } = await db.rpc('rpc_cartridge_undo', args); return result(data, error);
  });
  for (const query of manifest.queries) {
    server.registerTool(query.name, { description: query.description, inputSchema: { filter_value: z.string().max(1000).optional() } }, async ({ filter_value }: { filter_value?: string }) => {
      let request = db.from(query.table).select('*');
      if (query.filterColumn && filter_value !== undefined) request = request.eq(query.filterColumn, filter_value);
      if (query.orderBy) request = request.order(query.orderBy, { ascending: false });
      const { data, error } = await request.limit(50); return result(data, error);
    });
  }
  for (const intent of manifest.intents) {
    const shape: Record<string, z.ZodType> = {};
    for (const [key, spec] of Object.entries(intent.params)) {
      const p = spec as { type: string; enum?: string[]; description: string };
      shape[key] = (p.enum?.length ? z.enum(p.enum as [string, ...string[]]) :
        p.type === 'number' ? z.number() : p.type === 'boolean' ? z.boolean() : z.string().max(10000)).describe(p.description);
    }
    server.registerTool(intent.name, { description: `${intent.description} Billing: ${intent.creditCostNote}`, inputSchema: shape }, async (args: Record<string, unknown>) => {
      const { data, error } = await db.rpc(intent.rpcName, args); return result(data, error);
    });
  }
  const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  try {
    await server.connect(transport);
    const response = await transport.handleRequest(req);
    // JSON mode has no long-lived SSE stream; consume before closing request-scoped resources.
    const body = await response.arrayBuffer();
    const merged = new Headers(response.headers);
    headers.forEach((value, key) => merged.set(key, value));
    return new Response(body.byteLength ? body : null, { status: response.status, headers: merged });
  } finally { await server.close(); }
});
