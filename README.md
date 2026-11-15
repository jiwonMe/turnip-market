# Turnip Stalk Market

**An agent-native “주식 무(turnip) market” showcase built on the [Cartridge](https://github.com/jiwonMe/cartridge) pattern.**

There is no frontend. Players interact only through an MCP client (Claude Code, Cursor, etc.). State and invariants live in PostgreSQL (Supabase). Mutations are MCP tools backed by `SECURITY DEFINER` RPCs owned by a restricted `cartridge_executor` role. A generated [`dist/skills/SKILL.md`](dist/skills/SKILL.md) tells the agent how to trade. Failures return **Error-as-Prompt** envelopes (`ok: false`, `error_code`, `error_message`, `remediation`) so the agent can recover without human hand-holding.

> **Showcase status.** Domain logic and Cartridge engine behavior are covered by PGlite tests and CI. Hosted OAuth, Polar, and real-time demos still need your Supabase project and secrets.

## Concept

Inspired by Animal Crossing’s stalk market:

- Each account starts with **500 bells** (in-game wallet).
- **Sunday (slot 0)** is a **buy-only window** at a weekly base buy price (~90–110).
- **Twelve half-days (slots 1–12)** publish **sell prices** from a hidden weekly pattern (random walk, dips, small/large spikes).
- **Unsold turnips rot** when the week ends (after slot 12 advances to the next week).
- **Demo time compression:** one half-day lasts `market_config.minutes_per_half_day` real minutes (default **5**), so a full week fits a short demo.

Prices are **deterministic per week** from a server-only seed in `cartridge.market_week_secrets`. Clients and agents can read **current** prices and **past** log entries only—never future slots or the seed.

## Architecture

```text
Agent (MCP client)
    │  OAuth JWT
    ▼
Supabase Edge: functions/mcp          ← manifest from domain/cartridge.config.ts
    │  SELECT queries (RLS)           ← v_player_portfolio, v_leaderboard, market_price_log
    │  rpc_* intents                  ← catch_error → Error-as-Prompt JSON
    ▼
PostgreSQL
  cartridge.*     wallet, audit, undo, billing engine (000)
  public.*        turnip domain: holdings, runtime, price log (001)
  Polar sync      optional top-ups (002) — game top-ups OFF by default
```

| Layer | Responsibility |
|--------|----------------|
| RLS | `authenticated` users **SELECT** only their rows (and public market views). |
| `cartridge_executor` | Row locks, `cartridge.assert`, mutations, `commit_and_charge`, audit. |
| `cartridge.catch_error` | Maps domain errors (`SQLSTATE C0001`) to JSON; other failures stay generic. |
| MCP | No service-role on user paths; billing webhook uses service role separately. |

## MCP tools (domain)

| Tool | Role |
|------|------|
| `get_market` | Phase, buy/sell price, seconds until next slot, recent history; **advances the clock**. |
| `get_portfolio` | Bell balance, turnips, cost basis, unrealized P/L, rotten/can_sell status. |
| `get_leaderboard` | Net worth ranking (bells + mark-to-market turnips). |
| `get_price_history` | Logged prices (no lookahead). |
| `buy_turnips` / `sell_turnips` | Spend/credit **in-game bells** (not API billing credits). |
| `cartridge_status` | Plan + **game_wallet_bells** + optional Polar checkout. |
| `cartridge_undo` | Trade undo with strict window rules (below). |

Install the skill after build: `dist/skills/SKILL.md` (or MCP resource `skill://manual`).

## Key design decisions

### In-game bells vs billing credits

- **Game wealth:** `player_holdings.bell_balance` (500 on signup). Buys and sells move bells only here.
- **Cartridge billing:** `entitlements.credit_balance` remains for **API/tool metering** and optional Polar packs.
- **`enable_billing_topups`** defaults to **false** in `cartridge.settings`. Polar checkout can exist for infrastructure demos, but paid top-ups do not inflate the stalk market unless an operator explicitly enables it and documents fairness implications.

### Undo policy

Undoing a trade after the price moved would grant a free option. **Trade audits** restore only when:

- The market is still in the **same `week_number` and `slot_index`**, and  
- The **unit price** in `audit_logs.trade_context` matches the live price.

Otherwise: `UNDO_WINDOW_CLOSED` or `UNDO_PRICE_CHANGED`. Prefer advising users not to undo trades unless they insist in the same price window.

### Price model and secrecy

- Weekly seed in `cartridge.market_week_secrets` (no grants to `authenticated`).
- `market_price_for_slot(week, slot, mode)` is stable for tests; sell patterns vary by slot index.
- `rpc_get_market` calls `market_advance_clock()` so time progresses on read.

### Cartridge fixes carried in this repo

- `cartridge.assert` raises **`C0001`** (not generic `P0001`) so `catch_error` does not mis-label errors.
- Polar webhook **acknowledges unmapped subscription products with 200** instead of infinite 500 retries.
- Documented: `plan_tier 'pro'` does not change game rules; it only affects billing-side limits where configured.

## ~60-second agent demo script

Use this verbatim with your MCP-connected agent (adjust quantities to your balance):

1. **“Load the turnip stalk market skill and call `get_market`.”**  
   Note `phase`, `buy_price` or `sell_price`, and `seconds_until_next_slot`.

2. **“Call `get_portfolio`.”**  
   Confirm `bell_balance` ≈ 500 and no turnips.

3. **If `buy_window`: “Buy 10 turnips.”**  
   On success, note cost and remaining bells.

4. **“Try to buy 9999 turnips.”**  
   Expect `INSUFFICIENT_CREDITS`; read `remediation` (affordable quantity).

5. **“Wait until `seconds_until_next_slot` is 0 or advance half a day in the demo, then `get_market` again.”**  
   When `phase` is `sell_window`, check `sell_price`.

6. **“Sell 5 turnips”** (or fewer if you bought less).  
   Bells increase; unrealized P/L updates in portfolio.

7. **“Show `get_leaderboard`.”**  
   Compare net worth.

8. *(Optional)* **“Try `cartridge_undo` on the last buy audit after the slot changes.”**  
   Expect `UNDO_WINDOW_CLOSED` and explain why.

## Quick start (local)

Requires **Node.js 22+**. Tests use **PGlite** (no Docker).

```sh
git clone <this-repo>
cd turnip-stalk-market
npm ci
npm run check    # typecheck + tests + build → dist/
```

Optional Deno check (matches CI):

```sh
npx deno check --config supabase/functions/deno.json \
  supabase/functions/mcp/index.ts supabase/functions/billing-webhook/index.ts
```

Local Supabase (Docker) for a live MCP endpoint:

```sh
supabase start
supabase db reset   # applies migrations
export CARTRIDGE_MCP_URL="http://127.0.0.1:54321/functions/v1/mcp"
npm run build
supabase functions serve mcp --no-verify-jwt
```

Connect your MCP client to that URL with Supabase OAuth (see **OAuth and hosting** below).

### Operator tuning

```sql
-- Faster or slower demo weeks
UPDATE public.market_config SET minutes_per_half_day = 8 WHERE singleton;
```

## Deploy

```sh
export CARTRIDGE_MCP_URL="https://PROJECT_REF.supabase.co/functions/v1/mcp"
export SUPABASE_URL="https://PROJECT_REF.supabase.co"
export SUPABASE_ANON_KEY="YOUR_ANON_KEY"
npm run build
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase functions deploy mcp --no-verify-jwt
supabase functions deploy billing-webhook --no-verify-jwt
```

Host `public/oauth/consent/` on your HTTPS origin; configure Supabase Auth Site URL and OAuth clients per Cartridge’s OAuth section. Set function secrets (`CARTRIDGE_*`, and Polar only if you enable billing). **`enable_billing_topups`** should stay false for a fair leaderboard unless you deliberately opt in.

### Hosted Supabase notes

These adjustments are required on hosted Supabase (they are already in the migrations):

- `GRANT cartridge_executor TO postgres` must run before `ALTER FUNCTION ... OWNER TO cartridge_executor`, because the hosted `postgres` role is not a superuser.
- `GRANT USAGE ON SCHEMA auth` to custom roles does not persist. Executor-owned RPCs call `cartridge.current_uid()` (a `SECURITY DEFINER` wrapper owned by `postgres`) instead of `auth.uid()` directly.

The Management API / MCP connector cannot set function secrets or Auth settings. In the project dashboard, configure:

1. Edge Function secrets (no Polar/Stripe secrets needed while billing top-ups stay off):
   - `CARTRIDGE_MCP_URL=https://PROJECT_REF.supabase.co/functions/v1/mcp`
   - `CARTRIDGE_TOKEN_AUDIENCE=authenticated`
   - `CARTRIDGE_OAUTH_CLIENT_IDS` — comma-separated allowlist of registered OAuth client IDs
   - `CARTRIDGE_ALLOWED_ORIGINS` — comma-separated HTTPS origins for the consent page (optional; non-browser clients without an `Origin` header are allowed)
2. Authentication → OAuth server: enable it. `config.toml` only configures local Supabase.
3. Host `public/oauth/consent/` (after `npm run build` with `SUPABASE_URL` and `SUPABASE_ANON_KEY`) on your HTTPS origin. Set the Auth Site URL to that origin, and the authorization / consent path to `/oauth/consent/`.
4. Register OAuth clients with exact redirect URIs. Use authorization-code + PKCE. Dynamic client registration is disabled by default (`allow_dynamic_registration = false`).

## Repository layout

```text
domain/cartridge.config.ts       Turnip tools + SOP → compiler input
src/                               Cartridge config schema + compiler (vendored core)
supabase/migrations/
  000_cartridge_engine.sql         Engine, audit, undo, C0001 assert
  001_domain_turnip_market.sql     Market clock, prices, buy/sell, RLS, trade undo rules
  002_polar_billing.sql            Polar sync (safe skip on unknown products)
supabase/functions/mcp/            Streamable HTTP MCP
tests/                             compiler, engine, turnip domain, polar webhook
```

## Development and verification

```sh
npm run check
```

Tests cover: buy/sell, insufficient credits, oversell, rot at week end, price determinism, secret table denial, RLS isolation, undo same-window vs closed window, billing gate, Polar signature checks.

CI: `.github/workflows/ci.yml` runs `npm run check` and `deno check` on push/PR.

## Before production

- Real Supabase OAuth + MCP integration test with your client  
- Concurrent buy/sell stress (two sessions, same user)  
- Rate limiting and monitoring on Edge functions  
- Decide explicitly on `enable_billing_topups` and Polar products  
- Independent security review (showcase, not certification)

---

## 한국어 요약

**터니프 주식 시장 쇼케이스**입니다. UI 없이 MCP 도구만으로 동물의 숲 스타일 **무 매매**를 합니다.

- 가입 시 **벨 500** (`player_holdings.bell_balance`).
- **일요일 슬롯(0)** 에만 매수, **1–12 슬롯** 에 매도 가격이 공개됩니다.
- 주가는 서버만 아는 주간 시드로 **결정적**이며, 미래 가격·시드는 클라이언트에 노출되지 않습니다.
- 주가 끝에 미판매 무는 **썩어서 0** 이 됩니다.
- 데모용으로 `minutes_per_half_day`(기본 5분)마다 슬롯이 바뀝니다.
- 오류는 `error_code` + `remediation` 으로 에이전트가 스스로 복구하도록 설계했습니다.
- **Polar 충전**은 기본 꺼짐; 게임 공정성은 인게임 벨만 사용합니다.
- **거래 undo**는 같은 주·같은 슬롯·같은 단가에서만 가능합니다.

위 **60초 데모 스크립트**를 한국어로 요청해도 동일한 순서로 진행하면 됩니다.

## License

MIT (Cartridge core). See [LICENSE](LICENSE).