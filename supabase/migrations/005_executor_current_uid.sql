-- Hosted Supabase does not persist GRANT USAGE ON SCHEMA auth for custom roles.
-- Executor-owned RPCs must read the JWT subject through this postgres-owned wrapper.

CREATE OR REPLACE FUNCTION cartridge.current_uid() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid();
$$;
REVOKE ALL ON FUNCTION cartridge.current_uid() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cartridge.current_uid() TO cartridge_executor;

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
