-- Private engine. Never expose the cartridge schema through PostgREST.
CREATE SCHEMA cartridge;
CREATE ROLE cartridge_executor NOLOGIN NOINHERIT;
-- Hosted Supabase: the postgres role is not a superuser, so it must be a
-- member of cartridge_executor before ALTER FUNCTION ... OWNER TO that role.
GRANT cartridge_executor TO postgres;
GRANT USAGE ON SCHEMA public, auth, cartridge TO cartridge_executor;
GRANT EXECUTE ON FUNCTION auth.uid() TO cartridge_executor;
-- Hosted Supabase does not persist USAGE on the auth schema for custom roles,
-- so executor-owned RPCs must call cartridge.current_uid() instead of auth.uid().

CREATE TABLE cartridge.entitlements (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_tier text NOT NULL DEFAULT 'free' CHECK (plan_tier IN ('free', 'pro', 'unlimited')),
  credit_balance integer NOT NULL DEFAULT 500 CHECK (credit_balance >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cartridge.settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  checkout_base_url text CHECK (checkout_base_url ~ '^https://'),
  enable_billing_topups boolean NOT NULL DEFAULT false
);
INSERT INTO cartridge.settings DEFAULT VALUES;
CREATE TABLE cartridge.undo_targets (
  table_name text PRIMARY KEY,
  pk_column text NOT NULL DEFAULT 'id',
  owner_column text NOT NULL DEFAULT 'owner_id'
);
CREATE TABLE cartridge.audit_logs (
  audit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  intent_name text NOT NULL,
  target_table text NOT NULL REFERENCES cartridge.undo_targets(table_name),
  target_id text NOT NULL,
  before_state jsonb NOT NULL,
  after_state jsonb NOT NULL,
  credits_charged integer NOT NULL CHECK (credits_charged >= 0),
  trade_context jsonb,
  reverted boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cartridge.billing_events (
  session_id text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id),
  credits integer NOT NULL CHECK (credits > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cartridge.entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE cartridge.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE cartridge.billing_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE cartridge.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE cartridge.undo_targets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA cartridge FROM PUBLIC, anon, authenticated;

CREATE FUNCTION cartridge.init_user_entitlement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO cartridge.entitlements(user_id, credit_balance) VALUES (NEW.id, 500) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER on_auth_user_created_cartridge AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION cartridge.init_user_entitlement();

-- Dedicated SQLSTATE C0001 for domain invariants (not generic P0001).
CREATE FUNCTION cartridge.assert(p_condition boolean, p_error_code text, p_message text, p_remediation text)
RETURNS void LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NOT coalesce(p_condition, false) THEN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'C0001', DETAIL = p_error_code, HINT = p_remediation;
  END IF;
END;
$$;
CREATE FUNCTION cartridge.catch_error(p_sqlstate text, p_message text, p_detail text, p_hint text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_sqlstate = 'C0001' THEN jsonb_build_object(
      'ok', false, 'error_code', coalesce(nullif(p_detail, ''), 'DOMAIN_INVARIANT_ERROR'),
      'error_message', p_message, 'remediation', p_hint)
    WHEN p_sqlstate = 'P0402' THEN jsonb_build_object(
      'ok', false, 'error_code', 'PAYMENT_REQUIRED', 'error_message', p_message,
      'remediation', p_hint, 'checkout_url', nullif(p_detail, ''))
    ELSE jsonb_build_object('ok', false, 'error_code', 'INTERNAL_ERROR',
      'error_message', 'The operation could not be completed.',
      'remediation', 'Do not retry blindly. Ask the operator to inspect database logs.')
  END;
$$;
CREATE FUNCTION cartridge.checkout_url(p_user_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT CASE WHEN (SELECT enable_billing_topups FROM cartridge.settings WHERE singleton)
   THEN checkout_base_url || CASE WHEN strpos(checkout_base_url, '?') > 0 THEN '&' ELSE '?' END
     || 'client_reference_id=' || p_user_id::text
   ELSE NULL END
 FROM cartridge.settings WHERE singleton;
$$;

-- Wrapper so cartridge_executor can read auth.uid() without schema USAGE on auth.
CREATE FUNCTION cartridge.current_uid() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid();
$$;
REVOKE ALL ON FUNCTION cartridge.current_uid() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cartridge.current_uid() TO cartridge_executor;

CREATE FUNCTION cartridge.commit_and_charge(
  p_intent_name text, p_target_table text, p_target_id text,
  p_before jsonb, p_after jsonb, p_cost integer DEFAULT 0,
  p_trade_context jsonb DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  u uuid := auth.uid(); e cartridge.entitlements; t cartridge.undo_targets;
  a uuid; charged integer := 0; checkout text;
BEGIN
  PERFORM cartridge.assert(u IS NOT NULL, 'UNAUTHENTICATED', 'Authentication required.', 'Complete OAuth sign-in.');
  PERFORM cartridge.assert(p_cost >= 0, 'INVALID_COST', 'Cost must be nonnegative.', 'Contact the operator.');
  SELECT * INTO t FROM cartridge.undo_targets WHERE table_name = p_target_table;
  PERFORM cartridge.assert(FOUND AND p_before IS NOT NULL AND p_after IS NOT NULL
    AND p_before->>t.owner_column = u::text AND p_after->>t.owner_column = u::text
    AND p_before->>t.pk_column = p_target_id AND p_after->>t.pk_column = p_target_id,
    'INVALID_AUDIT', 'Unsupported audit target.', 'Contact the operator.');
  INSERT INTO cartridge.entitlements(user_id) VALUES (u) ON CONFLICT DO NOTHING;
  SELECT * INTO e FROM cartridge.entitlements WHERE user_id = u FOR UPDATE;
  IF e.plan_tier <> 'unlimited' AND p_cost > 0 THEN
    charged := p_cost;
    IF e.credit_balance < charged THEN
      checkout := cartridge.checkout_url(u);
      RAISE EXCEPTION 'Insufficient credits.' USING ERRCODE = 'P0402', DETAIL = coalesce(checkout, ''),
        HINT = CASE WHEN checkout IS NULL
          THEN 'Billing top-ups are disabled for this showcase. Trade within your in-game Bell balance.'
          ELSE 'Show checkout_url to the user and wait for payment before retrying.' END;
    END IF;
    UPDATE cartridge.entitlements SET credit_balance = credit_balance - charged, updated_at = now()
      WHERE user_id = u RETURNING * INTO e;
  END IF;
  INSERT INTO cartridge.audit_logs(user_id, intent_name, target_table, target_id, before_state, after_state, credits_charged, trade_context)
    VALUES (u, p_intent_name, p_target_table, p_target_id, p_before, p_after, charged, p_trade_context) RETURNING audit_id INTO a;
  RETURN jsonb_build_object('ok', true, 'audit_id', a, 'charged_credits', charged,
    'remaining_credits', CASE WHEN e.plan_tier = 'unlimited' THEN -1 ELSE e.credit_balance END,
    'data', p_after,
    'undo_hint', CASE WHEN p_trade_context IS NULL THEN 'Use cartridge_undo with audit_id only when the user requests reversal.'
      ELSE 'Undo is only allowed while the same price window and price apply. Call get_market to confirm before undo.' END);
END;
$$;

CREATE FUNCTION public.rpc_cartridge_status() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE u uuid := auth.uid(); e cartridge.entitlements; topups boolean;
BEGIN
  IF u IS NULL THEN RETURN jsonb_build_object('ok', false, 'error_code', 'UNAUTHENTICATED'); END IF;
  INSERT INTO cartridge.entitlements(user_id) VALUES (u) ON CONFLICT DO NOTHING;
  SELECT * INTO e FROM cartridge.entitlements WHERE user_id = u;
  SELECT enable_billing_topups INTO topups FROM cartridge.settings WHERE singleton;
  RETURN jsonb_build_object('ok', true, 'user_id', u, 'plan_tier', e.plan_tier,
    'billing_topups_enabled', coalesce(topups, false),
    'topup_checkout_url', cartridge.checkout_url(u));
END;
$$;

CREATE FUNCTION public.rpc_cartridge_undo(p_audit_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l cartridge.audit_logs; t cartridge.undo_targets; current_state jsonb; columns_sql text;
  s text; m text; d text; h text; affected integer;
BEGIN
  SELECT * INTO l FROM cartridge.audit_logs WHERE audit_id = p_audit_id AND user_id = auth.uid() FOR UPDATE;
  PERFORM cartridge.assert(FOUND AND NOT l.reverted, 'INVALID_AUDIT_ID',
    'Audit entry not found or already reverted.', 'Inspect the audit ID; do not retry this undo.');
  SELECT * INTO STRICT t FROM cartridge.undo_targets WHERE table_name = l.target_table;
  EXECUTE format('SELECT to_jsonb(r) FROM public.%I r WHERE %I::text = $1 AND %I::text = $2 FOR UPDATE',
    t.table_name, t.pk_column, t.owner_column) INTO current_state USING l.target_id, auth.uid()::text;
  PERFORM cartridge.assert(current_state IS NOT DISTINCT FROM l.after_state, 'UNDO_CONFLICT',
    'The row changed or was deleted after this operation.', 'Inspect current state and ask the user how to proceed.');
  SELECT string_agg(format('%I = restored.%I', attname, attname), ', ' ORDER BY attnum) INTO columns_sql
    FROM pg_catalog.pg_attribute WHERE attrelid = format('public.%I', t.table_name)::regclass
      AND attnum > 0 AND NOT attisdropped AND attgenerated = '' AND attidentity = '' AND attname <> t.pk_column;
  EXECUTE format('UPDATE public.%I AS target SET %s FROM jsonb_populate_record(NULL::public.%I, $1) AS restored WHERE target.%I::text = $2 AND target.%I::text = $3',
    t.table_name, columns_sql, t.table_name, t.pk_column, t.owner_column)
    USING l.before_state, l.target_id, auth.uid()::text;
  GET DIAGNOSTICS affected = ROW_COUNT;
  PERFORM cartridge.assert(affected = 1, 'UNDO_CONFLICT', 'Undo did not restore exactly one row.', 'Contact the operator.');
  UPDATE cartridge.entitlements SET credit_balance = credit_balance + l.credits_charged, updated_at = now() WHERE user_id = l.user_id;
  UPDATE cartridge.audit_logs SET reverted = true WHERE audit_id = p_audit_id;
  RETURN jsonb_build_object('ok', true, 'reverted_audit_id', p_audit_id,
    'refunded_credits', l.credits_charged, 'restored_state', l.before_state);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN cartridge.catch_error(s, m, d, h);
END;
$$;

CREATE FUNCTION public.admin_grant_credits(p_session_id text, p_user_id uuid, p_amount integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 OR p_session_id IS NULL OR p_session_id = '' THEN
    RAISE EXCEPTION 'Invalid credit grant';
  END IF;
  IF NOT (SELECT enable_billing_topups FROM cartridge.settings WHERE singleton) THEN
    RETURN false;
  END IF;
  INSERT INTO cartridge.billing_events(session_id, user_id, credits) VALUES (p_session_id, p_user_id, p_amount)
    ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN RETURN false; END IF;
  INSERT INTO cartridge.entitlements(user_id, plan_tier, credit_balance) VALUES (p_user_id, 'free', p_amount)
    ON CONFLICT (user_id) DO UPDATE SET credit_balance = cartridge.entitlements.credit_balance + EXCLUDED.credit_balance,
      updated_at = now();
  RETURN true;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cartridge FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cartridge.assert(boolean,text,text,text), cartridge.catch_error(text,text,text,text),
  cartridge.commit_and_charge(text,text,text,jsonb,jsonb,integer,jsonb) TO cartridge_executor;
REVOKE ALL ON FUNCTION public.rpc_cartridge_status(), public.rpc_cartridge_undo(uuid), public.admin_grant_credits(text,uuid,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_cartridge_status(), public.rpc_cartridge_undo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_grant_credits(text,uuid,integer) TO service_role;
GRANT USAGE ON SCHEMA cartridge TO service_role;
GRANT SELECT, UPDATE ON cartridge.settings TO service_role;