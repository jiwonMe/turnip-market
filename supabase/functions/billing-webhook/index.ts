import { validateEvent } from 'npm:@polar-sh/sdk@0.42.5/webhooks';
import { createClient } from 'npm:@supabase/supabase-js@2.95.3';
import { accountId, parseProducts, productCredits } from '../_shared/polar.ts';

function env(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}
const secret = env('POLAR_WEBHOOK_SECRET');
const products = parseProducts(env('POLAR_PRODUCT_CREDITS'));
const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false, autoRefreshToken: false },
});
Deno.serve(async req => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  let event;
  try {
    // Validate the original bytes before interpreting any account or product fields.
    event = validateEvent(await req.text(), Object.fromEntries(req.headers.entries()), secret);
  } catch { return new Response('Invalid webhook', { status: 400 }); }
  try {
    if (event.type === 'order.paid') {
      const order = event.data;
      const userId = accountId(order.customer.externalId);
      const credits = productCredits(products, order.productId);
      // Initial subscription payments and renewals each have a distinct order ID.
      // Never also grant on subscription.active.
      const { error } = await db.rpc('admin_grant_credits', {
        p_session_id: `polar:order:${order.id}`, p_user_id: userId, p_amount: credits,
      });
      if (error) throw error;
    } else if (event.type === 'subscription.created' || event.type === 'subscription.updated' ||
               event.type === 'subscription.active' || event.type === 'subscription.revoked' ||
               event.type === 'subscription.canceled' || event.type === 'subscription.uncanceled') {
      const sub = event.data;
      if (!sub.productId || !Object.hasOwn(products, sub.productId)) {
        return Response.json({ received: true, skipped: 'unmapped_subscription_product' });
      }
      const { error } = await db.rpc('admin_sync_polar_subscription', {
        p_subscription_id: sub.id, p_user_id: accountId(sub.customer.externalId),
        // Cancellation scheduled at period end retains active status until revocation.
        p_active: sub.status === 'active' || sub.status === 'trialing',
        p_event_at: (sub.modifiedAt ?? event.timestamp).toISOString(),
      });
      if (error) throw error;
    }
    return Response.json({ received: true });
  } catch {
    // Retryable: never acknowledge a paid event whose grant failed.
    console.error('Polar fulfillment failed', event.type);
    return new Response('Fulfillment failed; retry required', { status: 500 });
  }
});
