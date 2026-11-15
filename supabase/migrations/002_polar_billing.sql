CREATE TABLE cartridge.polar_subscriptions (
  subscription_id text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  active boolean NOT NULL,
  event_at timestamptz NOT NULL
);
ALTER TABLE cartridge.polar_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cartridge.polar_subscriptions FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.admin_sync_polar_subscription(
  p_subscription_id text, p_user_id uuid, p_active boolean, p_event_at timestamptz
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE applied boolean;
BEGIN
  IF p_subscription_id IS NULL OR p_subscription_id = '' OR p_active IS NULL OR p_event_at IS NULL THEN
    RAISE EXCEPTION 'Invalid subscription state';
  END IF;
  IF NOT (SELECT enable_billing_topups FROM cartridge.settings WHERE singleton) THEN
    RETURN false;
  END IF;
  INSERT INTO cartridge.entitlements(user_id) VALUES (p_user_id) ON CONFLICT DO NOTHING;
  PERFORM 1 FROM cartridge.entitlements WHERE user_id = p_user_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM cartridge.polar_subscriptions WHERE subscription_id = p_subscription_id AND user_id <> p_user_id) THEN
    RAISE EXCEPTION 'Subscription account mismatch';
  END IF;
  INSERT INTO cartridge.polar_subscriptions(subscription_id,user_id,active,event_at)
    VALUES (p_subscription_id,p_user_id,p_active,p_event_at)
    ON CONFLICT (subscription_id) DO UPDATE SET active = EXCLUDED.active, event_at = EXCLUDED.event_at
    WHERE cartridge.polar_subscriptions.event_at < EXCLUDED.event_at;
  applied := FOUND;
  RETURN applied;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_sync_polar_subscription(text,uuid,boolean,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_sync_polar_subscription(text,uuid,boolean,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION cartridge.catch_error(p_sqlstate text, p_message text, p_detail text, p_hint text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_sqlstate = 'C0001' THEN jsonb_build_object(
      'ok', false, 'error_code', coalesce(nullif(p_detail, ''), 'DOMAIN_INVARIANT_ERROR'),
      'error_message', p_message, 'remediation', p_hint)
    WHEN p_sqlstate = 'P0402' THEN jsonb_build_object(
      'ok', false, 'error_code', 'PAYMENT_REQUIRED', 'error_message', p_message,
      'remediation', CASE WHEN p_sqlstate = 'P0402'
        THEN 'Call cartridge_checkout to obtain a payment link when billing top-ups are enabled.' ELSE p_hint END,
      'checkout_url', nullif(p_detail, ''))
    ELSE jsonb_build_object('ok', false, 'error_code', 'INTERNAL_ERROR',
      'error_message', 'The operation could not be completed.',
      'remediation', 'Do not retry blindly. Ask the operator to inspect database logs.')
  END;
$$;