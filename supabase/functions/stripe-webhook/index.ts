import Stripe from 'npm:stripe@18.5.0';
import { createClient } from 'npm:@supabase/supabase-js@2.95.3';

function env(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}
const stripe = new Stripe(env('STRIPE_SECRET_KEY'));
// Price IDs and credit quantities are operator-owned, never taken from client metadata.
const prices: Record<string, number> = JSON.parse(env('STRIPE_PRICE_CREDITS'));
for (const value of Object.values(prices)) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Invalid price credit mapping');
}
const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false, autoRefreshToken: false },
});
Deno.serve(async req => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const signature = req.headers.get('stripe-signature');
  if (!signature) return new Response('Missing signature', { status: 400 });
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(await req.text(), signature, env('STRIPE_WEBHOOK_SECRET'),
      undefined, Stripe.createSubtleCryptoProvider());
  } catch { return new Response('Invalid signature', { status: 400 }); }
  if (!['checkout.session.completed', 'checkout.session.async_payment_succeeded'].includes(event.type)) {
    return Response.json({ received: true });
  }
  const session = event.data.object as Stripe.Checkout.Session;
  if (session.mode !== 'payment' || session.payment_status !== 'paid') return Response.json({ received: true });
  const userId = session.client_reference_id;
  if (!userId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(userId)) {
    return new Response('Invalid account reference', { status: 400 });
  }
  try {
    let credits = 0;
    for await (const item of stripe.checkout.sessions.listLineItems(session.id, { limit: 100 })) {
      const perUnit = item.price?.id ? prices[item.price.id] : undefined;
      if (!perUnit || !item.quantity) throw new Error('Unknown price');
      credits += perUnit * item.quantity;
    }
    if (!Number.isSafeInteger(credits) || credits <= 0 || credits > 2147483647) throw new Error('Invalid credits');
    const { error } = await db.rpc('admin_grant_credits', { p_session_id: session.id, p_user_id: userId, p_amount: credits });
    if (error) throw error;
    return Response.json({ received: true });
  } catch {
    console.error('Credit grant failed for Stripe event', event.id);
    return new Response('Credit grant failed; retry required', { status: 500 });
  }
});
