-- Close the future-price leak: authenticated users could call
-- public.market_price_for_slot for any week/slot and read ahead.
-- Move the helper into the unexposed cartridge schema, revoke EXECUTE
-- on internal price/seed/clock helpers from PUBLIC/anon/authenticated,
-- and expose only the current slot sell price to invoker views.

CREATE OR REPLACE FUNCTION cartridge.market_price_for_slot(p_week integer, p_slot integer, p_phase text)
RETURNS integer
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
REVOKE ALL ON FUNCTION cartridge.market_price_for_slot(integer, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cartridge.market_price_for_slot(integer, integer, text) TO cartridge_executor;

-- Current-slot sell price only, for security_invoker views. No week/slot arguments.
CREATE OR REPLACE FUNCTION public.current_market_sell_price()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE
    WHEN r.slot_index = 0 THEN 0
    ELSE cartridge.market_price_for_slot(r.week_number, r.slot_index, 'sell')
  END
  FROM public.market_runtime AS r
  WHERE r.singleton;
$$;
REVOKE ALL ON FUNCTION public.current_market_sell_price() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_market_sell_price() TO authenticated, cartridge_executor;

CREATE OR REPLACE VIEW public.v_player_portfolio
WITH (security_invoker = true) AS
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
    ELSE greatest(0, (public.current_market_sell_price() * h.turnip_qty) - h.turnip_cost_total)
  END AS unrealized_pl_bells,
  CASE
    WHEN h.turnip_week IS NOT NULL AND h.turnip_week < r.week_number THEN 'rotten'
    WHEN r.slot_index = 0 THEN 'buy_window'
    WHEN coalesce(h.turnip_qty, 0) > 0 THEN 'can_sell'
    ELSE 'idle'
  END AS holding_status
FROM public.player_holdings h
CROSS JOIN public.market_runtime r;

-- SECURITY DEFINER is intentional: the leaderboard is a public ranking and must
-- see every player's mark-to-market net worth. Do not route this through
-- v_player_portfolio (security_invoker), or RLS would hide other players.
-- Prices come only from the current slot (via current_market_sell_price).
CREATE OR REPLACE VIEW public.v_leaderboard AS
SELECT
  h.owner_id,
  h.bell_balance
    + CASE WHEN coalesce(h.turnip_qty, 0) > 0
            AND h.turnip_week IS NOT DISTINCT FROM r.week_number
      THEN public.current_market_sell_price() * h.turnip_qty
      ELSE 0 END AS net_worth_bells,
  h.turnip_qty,
  h.bell_balance,
  rank() OVER (ORDER BY (
    h.bell_balance
      + CASE WHEN coalesce(h.turnip_qty, 0) > 0
              AND h.turnip_week IS NOT DISTINCT FROM r.week_number
        THEN public.current_market_sell_price() * h.turnip_qty
        ELSE 0 END
  ) DESC) AS rank
FROM public.player_holdings h
CROSS JOIN public.market_runtime r;

REVOKE ALL ON public.v_player_portfolio, public.v_leaderboard FROM PUBLIC, anon;
GRANT SELECT ON public.v_player_portfolio, public.v_leaderboard TO authenticated;

CREATE OR REPLACE FUNCTION cartridge.market_log_current_prices() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; buy_p integer; sell_p integer;
BEGIN
  SELECT * INTO r FROM public.market_runtime WHERE singleton;
  buy_p := cartridge.market_price_for_slot(r.week_number, r.slot_index, 'buy');
  sell_p := cartridge.market_price_for_slot(r.week_number, r.slot_index, 'sell');
  IF r.slot_index = 0 THEN
    INSERT INTO public.market_price_log(week_number, slot_index, phase, unit_price)
      VALUES (r.week_number, 0, 'buy', buy_p) ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO public.market_price_log(week_number, slot_index, phase, unit_price)
      VALUES (r.week_number, r.slot_index, 'sell', sell_p) ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_get_market() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; cfg public.market_config; buy_p integer; sell_p integer;
  wait_sec integer; market_phase text; history jsonb;
  s text; m text; d text; h text;
BEGIN
  PERFORM cartridge.assert(cartridge.current_uid() IS NOT NULL, 'UNAUTHENTICATED', 'Authentication required.', 'Complete OAuth sign-in.');
  PERFORM cartridge.market_advance_clock();
  SELECT * INTO r FROM public.market_runtime WHERE singleton;
  SELECT * INTO cfg FROM public.market_config WHERE singleton;
  market_phase := CASE WHEN r.slot_index = 0 THEN 'buy_window' ELSE 'sell_window' END;
  buy_p := cartridge.market_price_for_slot(r.week_number, r.slot_index, 'buy');
  sell_p := cartridge.market_price_for_slot(r.week_number, r.slot_index, 'sell');
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

CREATE OR REPLACE FUNCTION public.rpc_buy_turnips(p_qty integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; u uuid := cartridge.current_uid();
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
  unit := cartridge.market_price_for_slot(r.week_number, 0, 'buy');
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

CREATE OR REPLACE FUNCTION public.rpc_sell_turnips(p_qty integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.market_runtime; u uuid := cartridge.current_uid();
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
  unit := cartridge.market_price_for_slot(r.week_number, r.slot_index, 'sell');
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
    px := cartridge.market_price_for_slot(wk, sl, l.trade_context->>'phase');
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

-- Drop the public helper after dependents have moved off it.
DROP FUNCTION IF EXISTS public.market_price_for_slot(integer, integer, text);

REVOKE ALL ON FUNCTION cartridge.market_ensure_week_secret(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cartridge.market_advance_clock() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cartridge.market_log_current_prices() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cartridge.market_apply_rotten() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cartridge.market_price_for_slot(integer, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cartridge.market_ensure_week_secret(integer) TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_advance_clock() TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_log_current_prices() TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_apply_rotten() TO cartridge_executor;
GRANT EXECUTE ON FUNCTION cartridge.market_price_for_slot(integer, integer, text) TO cartridge_executor;

REVOKE USAGE ON SCHEMA cartridge FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA cartridge REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
