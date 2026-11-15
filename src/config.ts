import { z } from 'zod';

const identifier = z.string().regex(/^[a-z][a-z0-9_]*$/).max(63);
const parameter = z.object({
  type: z.enum(['string', 'number', 'boolean']),
  enum: z.array(z.string()).nonempty().optional(),
  description: z.string().min(1),
}).strict().refine(p => !p.enum || p.type === 'string', 'Enums require string parameters');

export const cartridgeConfigSchema = z.object({
  name: z.string().regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/).max(64),
  version: z.string().regex(/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/),
  description: z.string().min(1),
  sop: z.array(z.string().min(1)).nonempty(),
  queries: z.array(z.object({
    name: identifier, description: z.string().min(1), table: identifier,
    filterColumn: identifier.optional(), orderBy: identifier.optional(),
  }).strict()),
  intents: z.array(z.object({
    name: identifier, rpcName: identifier, description: z.string().min(1),
    creditCostNote: z.string().min(1), params: z.record(identifier, parameter),
  }).strict()),
}).strict().superRefine((config, ctx) => {
  const names = new Set(['cartridge_status', 'cartridge_undo', 'cartridge_checkout', 'get_billing_portal']);
  for (const tool of [...config.queries, ...config.intents]) {
    if (names.has(tool.name)) ctx.addIssue({ code: 'custom', message: `Duplicate or reserved tool: ${tool.name}` });
    names.add(tool.name);
  }
});

export type CartridgeConfig = z.infer<typeof cartridgeConfigSchema>;
export function defineCartridge(config: CartridgeConfig): CartridgeConfig {
  return cartridgeConfigSchema.parse(config);
}
