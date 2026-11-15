-- Turnip stalk market (Animal Crossing–style) domain.

CREATE TABLE public.market_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  minutes_per_half_day integer NOT NULL DEFAULT 5 CHECK (minutes_per_half_day BETWEEN 1 AND 1440),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.market_config DEFAULT VALUES;

CREATE TABLE public.market_runtime (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  week_number integer NOT NULL DEFAULT 1 CHECK (week_number > 0),
  slot_index integer NOT NULL DEFAULT 0 CHECK (slot_index BETWEEN 0 AND 12),
  slot_started_at timestamptz NOT NULL DEFAULT now(),
  week_started_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.market_runtime DEFAULT VALUES;

CREATE TABLE cartridge.market_week_secrets (
  week_number integer PRIMARY KEY,
  seed bigint NOT NULL
);
REVOKE ALL ON cartridge.market_week_secrets FROM PUBLIC, anon, authenticated;

CREATE TABLE public.market_price_log (
  id bigserial PRIMARY KEY,
  week_number integer NOT NULL,
  slot_index integer NOT NULL CHECK (slot_index BETWEEN 0 AND 12),
  phase text NOT NULL CHECK (phase IN ('buy', 'sell')),
  unit_price integer NOT NULL CHECK (unit_price > 0),
  logged_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (week_number, slot_index, phase)
);

CREATE TABLE public.player_holdings (
  owner_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  bell_balance integer NOT NULL DEFAULT 500 CHECK (bell_balance >= 0),
  turnip_qty integer NOT NULL DEFAULT 0 CHECK (turnip_qty >= 0),
  turnip_week integer,
  turnip_cost_total integer NOT NULL DEFAULT 0 CHECK (turnip_cost_total >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.market_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_price_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_holdings ENABLE ROW LEVEL SECURITY;

CREATE POLICY market_config_read ON public.market_config FOR SELECT TO authenticated USING (true);
CREATE POLICY market_config_executor ON public.market_config FOR ALL TO cartridge_executor USING (true) WITH CHECK (true);
CREATE POLICY market_runtime_read ON public.market_runtime FOR SELECT TO authenticated USING (true);
CREATE POLICY market_runtime_executor ON public.market_runtime FOR ALL TO cartridge_executor USING (true) WITH CHECK (true);
CREATE POLICY market_price_log_read ON public.market_price_log FOR SELECT TO authenticated USING (true);
CREATE POLICY market_price_log_executor ON public.market_price_log FOR ALL TO cartridge_executor USING (true) WITH CHECK (true);
CREATE POLICY player_holdings_read ON public.player_holdings FOR SELECT TO authenticated
  USING (owner_id = auth.uid());
CREATE POLICY player_holdings_intent ON public.player_holdings FOR ALL TO cartridge_executor
  USING (owner_id = auth.uid()) WITH CHECK (owner_id = auth.uid());

REVOKE ALL ON public.player_holdings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.market_config, public.market_runtime, public.market_price_log TO authenticated;
GRANT SELECT ON public.player_holdings TO authenticated;
GRANT SELECT ON public.market_config, public.market_runtime, public.market_price_log TO cartridge_executor;
GRANT SELECT, INSERT, UPDATE ON public.player_holdings TO cartridge_executor;
GRANT SELECT, UPDATE ON public.market_runtime TO cartridge_executor;

INSERT INTO cartridge.undo_targets(table_name, pk_column, owner_column)
  VALUES ('player_holdings', 'owner_id', 'owner_id');

CREATE FUNCTION cartridge.market_ensure_week_secret(p_week integer) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s bigint;
BEGIN
  SELECT seed INTO s FROM cartridge.market_week_secrets WHERE week_number = p_week;
  IF FOUND THEN RETURN s; END IF;
  s := abs((extract(epoch FROM now()) * 1000000)::bigint + p_week::bigint * 7919 + (random() * 1000000)::bigint);
  IF s < 0 THEN s := -s; END IF;
  INSERT INTO cartridge.market_week_secrets(week_number, seed) VALUES (p_week, s) ON CONFLICT DO NOTHING;
  SELECT seed INTO s FROM cartridge.market_week_secrets WHERE week_number = p_week;
  RETURN s;
END;
$$;
REVOKE ALL ON FUNCTION cartridge.market_ensure_week_secret(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cartridge.market_ensure_week_secret(integer) TO cartridge_executor;

CREATE FUNCTION public.market_price_for_slot(p_week integer, p_slot integer, p_phase text) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE seed bigint; pattern integer; base integer; i integer; price integer; peak integer; slot integer;
BEGIN
  IF p_phase = 'buy' THEN
    IF p_slot <> 0 THEN RETURN 0; END IF;
    seed := cartridge.market_ensure_week_secret(p_week);
    RETURN 90 + (seed % 21);
  END IF;
  IF p_slot < 1 OR p_slot > 12 THEN RETURN 0; END IF;
  seed := cartridge.market_ensure_week_secret(p_week);
  pattern := (seed / 7) % 4;
  base := 80 + (seed % 40);
  slot := p_slot;
  IF pattern = 0 THEN
    price := base + ((seed >> (slot % 16)) % 25) - 10 + (slot % 5) * 2;
  ELSIF pattern = 1 THEN
    price := base + 40 - slot * 4 + ((seed >> slot) % 6);
  ELSIF pattern = 2 THEN
    peak := 6 + (seed % 4);
    price := base + CASE WHEN abs(slot - peak) <= 1 THEN 35 + (seed % 20) ELSE 5 + (seed >> slot) % 15 END;
  ELSE
    peak := 4 + (seed % 3);
    price := base + CASE WHEN slot = peak THEN 90 + (seed % 60) ELSE 8 + ((seed >> (slot + 3)) % 12) END;
  END IF;
  RETURN greatest(15, least(660, price));
END;
$$;
REVOKE ALL ON FUNCTION public.market_price_for_slot(integer, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.market_price_for_slot(integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.market_price_for_slot(integer, integer, text) TO cartridge_executor;

CREATE OR REPLACE VIEW public.v_player_portfolio AS
SELECT
  h.owner_id,
  h.bell_balance,
  coalesce(h.turnip_qty, 0) AS turnip_qty,
  h.turnip_week,
  CASE WHEN h.turnip_qty > 0 AND h.turnip_cost_total > 0
    THEN round(h.turnip_cost_total::numeric / h.turnip_qty)::integer ELSE NULL END AS avg_buy_price,
  CASE
    WHEN coalesce(h.turnip_qty, 0) = 0 THEN 0
    WHEN h.turnip_week IS DISTINCT FROM r.week_number THEN 0
    WHEN r.slot_index = 0 THEN 0
    ELSE greatest(0, (public.market_price_for_slot(r.week_number, r.slot_index, 'sell') * h.turnip_qty) - h.turnip_cost_total)
  END AS unrealized_pl_bells,
  CASE
    WHEN h.turnip_week IS NOT NULL AND h.turnip_week < r.week_number THEN 'rotten'
    WHEN r.slot_index = 0 THEN 'buy_window'
    WHEN coalesce(h.turnip_qty, 0) > 0 THEN 'can_sell'
    ELSE 'idle'
  END AS holding_status
FROM public.player_holdings h
CROSS JOIN public.market_runtime r;

CREATE OR REPLACE VIEW public.v_leaderboard AS
SELECT
  p.owner_id,
  p.bell_balance
    + CASE WHEN p.holding_status IN ('can_sell', 'buy_window') AND p.turnip_qty > 0
      THEN public.market_price_for_slot(r.week_number, r.slot_index, 'sell') * p.turnip_qty
      ELSE 0 END AS net_worth_bells,
  p.turnip_qty,
  p.bell_balance,
  rank() OVER (ORDER BY (
    p.bell_balance
      + CASE WHEN p.holding_status IN ('can_sell', 'buy_window') AND p.turnip_qty > 0
        THEN public.market_price_for_slot(r.week_number, r.slot_index, 'sell') * p.turnip_qty
        ELSE 0 END
  ) DESC) AS rank
FROM public.v_player_portfolio p
CROSS JOIN public.market_runtime r;

REVOKE ALL ON public.v_player_portfolio, public.v_leaderboard FROM PUBLIC, anon;
GRANT SELECT ON public.v_player_portfolio, public.v_leaderboard TO authenticated;

CREATE FUNCTION cartridge.market_log_current_prices() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; buy_p integer; sell_p integer;
BEGIN
  SELECT * INTO r FROM public.market_runtime WHERE singleton;
  buy_p := public.market_price_for_slot(r.week_number, r.slot_index, 'buy');
  sell_p := public.market_price_for_slot(r.week_number, r.slot_index, 'sell');
  IF r.slot_index = 0 THEN
    INSERT INTO public.market_price_log(week_number, slot_index, phase, unit_price)
      VALUES (r.week_number, 0, 'buy', buy_p) ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO public.market_price_log(week_number, slot_index, phase, unit_price)
      VALUES (r.week_number, r.slot_index, 'sell', sell_p) ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE FUNCTION cartridge.market_apply_rotten() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.player_holdings SET turnip_qty = 0, turnip_week = NULL, turnip_cost_total = 0, updated_at = now()
    WHERE turnip_week IS NOT NULL AND turnip_qty > 0;
END;
$$;

CREATE FUNCTION cartridge.market_advance_clock() RETURNS public.market_runtime
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; cfg public.market_config; elapsed_min numeric; next_slot integer; next_week integer;
BEGIN
  SELECT * INTO r FROM public.market_runtime WHERE singleton FOR UPDATE;
  SELECT * INTO cfg FROM public.market_config WHERE singleton;
  elapsed_min := extract(epoch FROM (now() - r.slot_started_at)) / 60.0;
  IF elapsed_min < cfg.minutes_per_half_day THEN
    PERFORM cartridge.market_log_current_prices();
    RETURN r;
  END IF;
  IF r.slot_index >= 12 THEN
    PERFORM cartridge.market_apply_rotten();
    next_week := r.week_number + 1;
    PERFORM cartridge.market_ensure_week_secret(next_week);
    UPDATE public.market_runtime SET week_number = next_week, slot_index = 0,
      slot_started_at = now(), week_started_at = now() WHERE singleton RETURNING * INTO r;
  ELSE
    next_slot := r.slot_index + 1;
    UPDATE public.market_runtime SET slot_index = next_slot, slot_started_at = now() WHERE singleton RETURNING * INTO r;
  END IF;
  PERFORM cartridge.market_log_current_prices();
  RETURN r;
END;
$$;

CREATE FUNCTION public.rpc_get_market() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; cfg public.market_config; buy_p integer; sell_p integer;
  wait_sec integer; market_phase text; history jsonb;
  s text; m text; d text; h text;
BEGIN
  PERFORM cartridge.assert(auth.uid() IS NOT NULL, 'UNAUTHENTICATED', 'Authentication required.', 'Complete OAuth sign-in.');
  PERFORM cartridge.market_advance_clock();
  SELECT * INTO r FROM public.market_runtime WHERE singleton;
  SELECT * INTO cfg FROM public.market_config WHERE singleton;
  market_phase := CASE WHEN r.slot_index = 0 THEN 'buy_window' ELSE 'sell_window' END;
  buy_p := public.market_price_for_slot(r.week_number, r.slot_index, 'buy');
  sell_p := public.market_price_for_slot(r.week_number, r.slot_index, 'sell');
  wait_sec := greatest(0, floor(greatest(
    (cfg.minutes_per_half_day::numeric * 60) - extract(epoch FROM (now() - r.slot_started_at)), 0
  ))::integer);
  SELECT coalesce(jsonb_agg(row_to_json(recent)::jsonb), '[]'::jsonb) INTO history
  FROM (
    SELECT week_number, slot_index, phase, unit_price
    FROM public.market_price_log ORDER BY logged_at DESC LIMIT 8
  ) recent;
  RETURN jsonb_build_object('ok', true, 'week_number', r.week_number, 'slot_index', r.slot_index, 'phase', market_phase,
    'buy_price', CASE WHEN r.slot_index = 0 THEN buy_p ELSE NULL END,
    'sell_price', CASE WHEN r.slot_index > 0 THEN sell_p ELSE NULL END,
    'seconds_until_next_slot', wait_sec, 'minutes_per_half_day', cfg.minutes_per_half_day,
    'recent_prices', history);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN cartridge.catch_error(s, m, d, h);
END;
$$;

CREATE FUNCTION public.rpc_buy_turnips(p_qty integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; u uuid := auth.uid();
  b public.player_holdings; a public.player_holdings; e_before integer; e_after integer;
  unit integer; total integer; ctx jsonb;
  s text; m text; d text; h text;
BEGIN
  PERFORM cartridge.market_advance_clock();
  SELECT * INTO r FROM public.market_runtime WHERE singleton;
  PERFORM cartridge.assert(p_qty IS NOT NULL AND p_qty > 0, 'INVALID_QTY',
    'Quantity must be a positive integer.', 'Ask how many turnips to buy and retry with n >= 1.');
  PERFORM cartridge.assert(r.slot_index = 0, 'BUY_WINDOW_CLOSED',
    'Turnips can only be bought on Sunday (slot 0).',
    format('Market is in %s. Wait %s seconds or call get_market until phase is buy_window.', r.slot_index, 0));
  unit := public.market_price_for_slot(r.week_number, 0, 'buy');
  total := unit * p_qty;
  INSERT INTO public.player_holdings(owner_id, bell_balance) VALUES (u, 500) ON CONFLICT DO NOTHING;
  SELECT * INTO b FROM public.player_holdings WHERE owner_id = u FOR UPDATE;
  e_before := b.bell_balance;
  PERFORM cartridge.assert(e_before >= total, 'INSUFFICIENT_CREDITS',
    format('Need %s bells but only have %s.', total, e_before),
    format('Buy at most %s turnips at %s bells each, or wait for a better sell window after Sunday.', e_before / unit, unit));
  PERFORM cartridge.assert(b.turnip_qty = 0 OR b.turnip_week = r.week_number, 'HOLDINGS_CONFLICT',
    'You already hold turnips from another week.', 'Sell or let them rot before buying again this week.');
  UPDATE public.player_holdings SET
    bell_balance = b.bell_balance - total,
    turnip_qty = b.turnip_qty + p_qty,
    turnip_week = r.week_number,
    turnip_cost_total = b.turnip_cost_total + total,
    updated_at = now()
  WHERE owner_id = u RETURNING * INTO a;
  e_after := a.bell_balance;
  ctx := jsonb_build_object('week_number', r.week_number, 'slot_index', r.slot_index,
    'phase', 'buy', 'unit_price', unit, 'qty', p_qty);
  RETURN cartridge.commit_and_charge('buy_turnips', 'player_holdings', u::text, to_jsonb(b), to_jsonb(a), 0, ctx)
    || jsonb_build_object('bells_spent', total, 'unit_price', unit, 'bell_balance', e_after);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN cartridge.catch_error(s, m, d, h);
END;
$$;

CREATE FUNCTION public.rpc_sell_turnips(p_qty integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; u uuid := auth.uid();
  b public.player_holdings; a public.player_holdings; e_before integer; e_after integer;
  unit integer; total integer; ctx jsonb;
  s text; m text; d text; h text;
BEGIN
  PERFORM cartridge.market_advance_clock();
  SELECT * INTO r FROM public.market_runtime WHERE singleton;
  PERFORM cartridge.assert(p_qty IS NOT NULL AND p_qty > 0, 'INVALID_QTY',
    'Quantity must be a positive integer.', 'Retry with n >= 1.');
  PERFORM cartridge.assert(r.slot_index > 0, 'MARKET_CLOSED',
    'Selling is closed on Sunday buy window.',
    'Call get_market and sell during a sell_window (slot_index 1–12).');
  INSERT INTO public.player_holdings(owner_id, bell_balance) VALUES (u, 500) ON CONFLICT DO NOTHING;
  SELECT * INTO b FROM public.player_holdings WHERE owner_id = u FOR UPDATE;
  PERFORM cartridge.assert(b.turnip_qty >= p_qty, 'NOT_ENOUGH_TURNIPS',
    format('You only hold %s turnips.', b.turnip_qty),
    format('Sell at most %s turnips, or buy more on the next Sunday buy_window.', b.turnip_qty));
  PERFORM cartridge.assert(b.turnip_week = r.week_number, 'TURNIPS_ROTTEN',
    'These turnips rotted at the end of last week.',
    'Buy fresh turnips on the next Sunday buy_window.');
  unit := public.market_price_for_slot(r.week_number, r.slot_index, 'sell');
  total := unit * p_qty;
  e_before := b.bell_balance;
  UPDATE public.player_holdings SET
    bell_balance = b.bell_balance + total,
    turnip_qty = b.turnip_qty - p_qty,
    turnip_cost_total = CASE WHEN b.turnip_qty = p_qty THEN 0
      ELSE round(b.turnip_cost_total::numeric * (b.turnip_qty - p_qty) / b.turnip_qty)::integer END,
    turnip_week = CASE WHEN b.turnip_qty = p_qty THEN NULL ELSE b.turnip_week END,
    updated_at = now()
  WHERE owner_id = u RETURNING * INTO a;
  e_after := a.bell_balance;
  ctx := jsonb_build_object('week_number', r.week_number, 'slot_index', r.slot_index,
    'phase', 'sell', 'unit_price', unit, 'qty', p_qty);
  RETURN cartridge.commit_and_charge('sell_turnips', 'player_holdings', u::text, to_jsonb(b), to_jsonb(a), 0, ctx)
    || jsonb_build_object('bells_gained', total, 'unit_price', unit, 'bell_balance', e_after);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN cartridge.catch_error(s, m, d, h);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_cartridge_status() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE u uuid := auth.uid(); e cartridge.entitlements; bells integer; topups boolean;
BEGIN
  IF u IS NULL THEN RETURN jsonb_build_object('ok', false, 'error_code', 'UNAUTHENTICATED'); END IF;
  INSERT INTO cartridge.entitlements(user_id) VALUES (u) ON CONFLICT DO NOTHING;
  INSERT INTO public.player_holdings(owner_id, bell_balance) VALUES (u, 500) ON CONFLICT DO NOTHING;
  SELECT * INTO e FROM cartridge.entitlements WHERE user_id = u;
  SELECT bell_balance INTO bells FROM public.player_holdings WHERE owner_id = u;
  SELECT enable_billing_topups INTO topups FROM cartridge.settings WHERE singleton;
  RETURN jsonb_build_object('ok', true, 'user_id', u, 'plan_tier', e.plan_tier,
    'game_wallet_bells', coalesce(bells, 500), 'billing_topups_enabled', coalesce(topups, false),
    'topup_checkout_url', cartridge.checkout_url(u));
END;
$$;

CREATE FUNCTION cartridge.init_player_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.player_holdings(owner_id, bell_balance) VALUES (NEW.id, 500) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER on_auth_user_player AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION cartridge.init_player_row();

GRANT CREATE ON SCHEMA public TO cartridge_executor;
ALTER FUNCTION public.rpc_get_market() OWNER TO cartridge_executor;
ALTER FUNCTION public.rpc_buy_turnips(integer) OWNER TO cartridge_executor;
ALTER FUNCTION public.rpc_sell_turnips(integer) OWNER TO cartridge_executor;
REVOKE CREATE ON SCHEMA public FROM cartridge_executor;
REVOKE ALL ON FUNCTION public.rpc_get_market() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_buy_turnips(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_sell_turnips(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_market() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_buy_turnips(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_sell_turnips(integer) TO authenticated;

GRANT EXECUTE ON FUNCTION cartridge.market_advance_clock() TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_log_current_prices() TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_apply_rotten() TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_ensure_week_secret(integer) TO cartridge_executor;

SELECT cartridge.market_ensure_week_secret(1);
SELECT cartridge.market_log_current_prices();

CREATE OR REPLACE FUNCTION public.rpc_cartridge_undo(p_audit_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l cartridge.audit_logs; t cartridge.undo_targets; current_state jsonb; columns_sql text;
  s text; m text; d text; h text; affected integer;
  wk integer; sl integer; px integer;
BEGIN
  SELECT * INTO l FROM cartridge.audit_logs WHERE audit_id = p_audit_id AND user_id = auth.uid() FOR UPDATE;
  PERFORM cartridge.assert(FOUND AND NOT l.reverted, 'INVALID_AUDIT_ID',
    'Audit entry not found or already reverted.', 'Inspect the audit ID; do not retry this undo.');
  IF l.trade_context IS NOT NULL THEN
    SELECT week_number, slot_index INTO wk, sl FROM public.market_runtime WHERE singleton;
    PERFORM cartridge.assert(
      (l.trade_context->>'week_number')::int = wk AND (l.trade_context->>'slot_index')::int = sl,
      'UNDO_WINDOW_CLOSED', 'The price window changed since this trade.',
      'Undo is disabled after the market moves. Do not retry this undo.');
    px := public.market_price_for_slot(wk, sl, l.trade_context->>'phase');
    PERFORM cartridge.assert(px = (l.trade_context->>'unit_price')::int, 'UNDO_PRICE_CHANGED',
      'The market price changed since this trade.', 'Undo is only valid at the same price. Do not retry.');
  END IF;
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
  IF l.credits_charged > 0 THEN
    UPDATE cartridge.entitlements SET credit_balance = credit_balance + l.credits_charged, updated_at = now() WHERE user_id = l.user_id;
  END IF;
  UPDATE cartridge.audit_logs SET reverted = true WHERE audit_id = p_audit_id;
  RETURN jsonb_build_object('ok', true, 'reverted_audit_id', p_audit_id,
    'refunded_credits', l.credits_charged, 'restored_state', l.before_state);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
  RETURN cartridge.catch_error(s, m, d, h);
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_cartridge_undo(uuid) TO authenticated;