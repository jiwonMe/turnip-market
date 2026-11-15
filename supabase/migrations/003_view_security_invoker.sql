-- Fix hosted security advisor: v_player_portfolio must not bypass RLS.
-- Recreate the public leaderboard independently so rankings stay visible.

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

-- SECURITY DEFINER is intentional: the leaderboard is a public ranking and must
-- see every player's mark-to-market net worth. Do not route this through
-- v_player_portfolio (security_invoker), or RLS would hide other players.
CREATE OR REPLACE VIEW public.v_leaderboard AS
SELECT
  h.owner_id,
  h.bell_balance
    + CASE WHEN coalesce(h.turnip_qty, 0) > 0
            AND h.turnip_week IS NOT DISTINCT FROM r.week_number
      THEN public.market_price_for_slot(r.week_number, r.slot_index, 'sell') * h.turnip_qty
      ELSE 0 END AS net_worth_bells,
  h.turnip_qty,
  h.bell_balance,
  rank() OVER (ORDER BY (
    h.bell_balance
      + CASE WHEN coalesce(h.turnip_qty, 0) > 0
              AND h.turnip_week IS NOT DISTINCT FROM r.week_number
        THEN public.market_price_for_slot(r.week_number, r.slot_index, 'sell') * h.turnip_qty
        ELSE 0 END
  ) DESC) AS rank
FROM public.player_holdings h
CROSS JOIN public.market_runtime r;

REVOKE ALL ON public.v_player_portfolio, public.v_leaderboard FROM PUBLIC, anon;
GRANT SELECT ON public.v_player_portfolio, public.v_leaderboard TO authenticated;
