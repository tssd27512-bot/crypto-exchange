/**
 * Stage 6 — the one place the frontend talks to the exchange backend.
 *
 * Rules this file encodes (see the stage-6 spec and SCHEMA.md):
 *  - Money is integer base units, end to end. `numeric(38,0)` columns arrive as
 *    decimal strings; they are parsed with BigInt, never through Number, and
 *    divided by 10^decimals only for display.
 *  - The backend is NOT deployed to the live Supabase project yet. Every call
 *    therefore has three distinguishable outcomes: ready / unavailable
 *    (the table or function does not exist yet) / error (a real failure).
 *    Nothing here invents a value to fill the gap.
 *  - Identity always comes from the Supabase session JWT; no user id is ever
 *    sent from the client.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '@/lib/supabase';
import { SUPABASE_ANON_KEY, SUPABASE_URL } from '@/lib/supabaseEnv';

// ---------------------------------------------------------------------------
// units
// ---------------------------------------------------------------------------

/** A `numeric(38,0)` value as PostgREST returns it (string) or as JSON may carry it. */
export type Units = string | number | bigint | null | undefined;

/** Parse a base-unit value without ever going through floating point. */
export function units(value: Units): bigint {
  if (value === null || value === undefined || value === '') return 0n;
  if (typeof value === 'bigint') return value;
  const raw = String(value).trim();
  const whole = raw.split('.')[0];
  if (!/^-?\d+$/.test(whole)) return 0n;
  return BigInt(whole);
}

/** Base units -> human decimal string, trimmed of trailing zeros. */
export function formatUnits(value: Units, decimals: number, maxFractionDigits = 8): string {
  const n = units(value);
  const negative = n < 0n;
  const abs = negative ? -n : n;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  let fraction = (abs % base).toString().padStart(decimals, '0');
  if (maxFractionDigits < decimals) fraction = fraction.slice(0, maxFractionDigits);
  fraction = fraction.replace(/0+$/, '');
  const sign = negative ? '-' : '';
  return fraction ? `${sign}${whole.toString()}.${fraction}` : `${sign}${whole.toString()}`;
}

/**
 * User-typed decimal -> base units. Returns null when the input is not a valid
 * decimal or carries more precision than the asset allows (the backend rejects
 * fractional/over-precise amounts loudly, so we must not silently round).
 */
export function parseUnits(input: string, decimals: number): bigint | null {
  const text = input.trim();
  if (!/^\d+(\.\d+)?$/.test(text)) return null;
  const [whole, fraction = ''] = text.split('.');
  if (fraction.length > decimals) return null;
  const scale = 10n ** BigInt(decimals);
  return BigInt(whole) * scale + BigInt(fraction.padEnd(decimals, '0') || '0');
}

/** Base units -> the string form PostgREST accepts for a numeric argument. */
export function unitsParam(value: bigint): string {
  return value.toString();
}

export function bpsToPercent(bps: number | null | undefined): string {
  if (bps === null || bps === undefined) return '—';
  return `${(bps / 100).toFixed(2)}%`;
}

/**
 * The backend's own formula for a quote amount (public.notional_units):
 * trunc(qty_units * price_units / 10^notional_scale). Reproduced with BigInt so
 * the number the user sees before submitting matches what the engine holds.
 */
export function notionalUnits(qtyUnits: Units, priceUnits: Units, notionalScale: number): bigint {
  const scale = 10n ** BigInt(Math.max(0, notionalScale));
  return (units(qtyUnits) * units(priceUnits)) / scale;
}

// ---------------------------------------------------------------------------
// error classification
// ---------------------------------------------------------------------------

export type ApiFailureKind = 'unavailable' | 'error';

export interface ApiFailure {
  kind: ApiFailureKind;
  /** Message shown to the user. */
  message: string;
  /** Raw code/message for the details line. */
  detail?: string;
}

interface PostgrestLikeError {
  code?: string;
  message?: string;
  details?: string;
  hint?: string;
}

const MISSING_BACKEND_CODES = new Set([
  '42P01', // undefined_table
  '42883', // undefined_function
  'PGRST202', // function not found in schema cache
  'PGRST205', // table not found in schema cache
  'PGRST204', // column not found
]);

function isMissingBackend(err: PostgrestLikeError): boolean {
  if (err.code && MISSING_BACKEND_CODES.has(err.code)) return true;
  const text = `${err.message ?? ''} ${err.details ?? ''}`.toLowerCase();
  return (
    text.includes('could not find the table') ||
    text.includes('could not find the function') ||
    text.includes('schema cache') ||
    text.includes('does not exist')
  );
}

/**
 * Turn whatever a Supabase call threw into something the UI can render honestly.
 * `unavailable` means "the backend object is not there yet" — the expected state
 * until the migrations are applied to the live project.
 */
export function toApiFailure(err: unknown): ApiFailure {
  if (!err) return { kind: 'error', message: 'Unknown error.' };
  if (err instanceof BackendNotConfigured) {
    return { kind: 'unavailable', message: err.message, detail: err.detail };
  }
  if (typeof err === 'object' && err !== null) {
    const e = err as PostgrestLikeError & { name?: string };
    if (e.name === 'TypeError' || /failed to fetch|networkerror|load failed/i.test(e.message ?? '')) {
      return {
        kind: 'unavailable',
        message: 'The exchange backend is not reachable from this build.',
        detail: e.message,
      };
    }
    if (isMissingBackend(e)) {
      return {
        kind: 'unavailable',
        message: 'Not available yet — the exchange backend has not been deployed to this project.',
        detail: [e.code, e.message].filter(Boolean).join(': '),
      };
    }
    if (e.code === 'PGRST301' || /jwt expired/i.test(e.message ?? '')) {
      return { kind: 'error', message: 'Your session has expired. Sign in again.', detail: e.message };
    }
    if (e.message) {
      return { kind: 'error', message: e.message, detail: [e.code, e.details, e.hint].filter(Boolean).join(' ') };
    }
  }
  return { kind: 'error', message: String(err) };
}

export class BackendNotConfigured extends Error {
  detail?: string;
  constructor(message: string, detail?: string) {
    super(message);
    this.name = 'BackendNotConfigured';
    this.detail = detail;
  }
}

export const backendConfigured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);

function assertConfigured(): void {
  if (!backendConfigured) {
    throw new BackendNotConfigured(
      'The exchange backend is not configured in this build (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are missing).',
    );
  }
}

// ---------------------------------------------------------------------------
// query helper
// ---------------------------------------------------------------------------

export type QueryState<T> =
  | { status: 'loading' }
  | { status: 'ready'; data: T }
  | { status: 'unavailable'; failure: ApiFailure }
  | { status: 'error'; failure: ApiFailure };

export interface QueryResult<T> {
  state: QueryState<T>;
  reload: () => void;
}

/**
 * Minimal read hook: runs `run` whenever `key` changes (and on demand via
 * `reload`), and keeps loading/ready/unavailable/error distinct. `run` is held
 * in a ref so an inline arrow function does not re-trigger the query.
 */
export function useQuery<T>(key: string, run: () => Promise<T>): QueryResult<T> {
  const runRef = useRef(run);
  runRef.current = run;
  const [nonce, setNonce] = useState(0);
  const [state, setState] = useState<QueryState<T>>({ status: 'loading' });

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let cancelled = false;
    setState({ status: 'loading' });
    (async () => {
      try {
        assertConfigured();
        const data = await runRef.current();
        if (!cancelled) setState({ status: 'ready', data });
      } catch (err) {
        if (cancelled) return;
        const failure = toApiFailure(err);
        setState(
          failure.kind === 'unavailable'
            ? { status: 'unavailable', failure }
            : { status: 'error', failure },
        );
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [key, nonce]);

  return { state, reload };
}

// ---------------------------------------------------------------------------
// realtime helper
// ---------------------------------------------------------------------------

export type RealtimeStatus = 'connecting' | 'live' | 'unavailable';

/**
 * Subscribe to changes on one published table. Delivery is only verifiable once
 * the backend is deployed, so a subscribe failure is reported as 'unavailable'
 * and callers fall back to a refetch — never treated as "no data".
 */
export function useRealtimeTable(
  table: string,
  options: { event?: 'INSERT' | 'UPDATE' | 'DELETE' | '*'; filter?: string; onChange: () => void; enabled?: boolean },
): RealtimeStatus {
  const { event = '*', filter, onChange, enabled = true } = options;
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const [status, setStatus] = useState<RealtimeStatus>('connecting');

  useEffect(() => {
    if (!enabled || !backendConfigured) {
      setStatus('unavailable');
      return;
    }
    const channelName = `stage6:${table}:${filter ?? 'all'}:${Math.random().toString(36).slice(2, 8)}`;
    let channel: ReturnType<typeof supabase.channel> | null = null;
    try {
      channel = supabase
        .channel(channelName)
        .on(
          'postgres_changes' as never,
          { event, schema: 'public', table, ...(filter ? { filter } : {}) } as never,
          () => onChangeRef.current(),
        )
        .subscribe((s: string) => {
          if (s === 'SUBSCRIBED') setStatus('live');
          else if (s === 'CHANNEL_ERROR' || s === 'TIMED_OUT') setStatus('unavailable');
        });
    } catch {
      setStatus('unavailable');
    }
    return () => {
      if (channel) supabase.removeChannel(channel);
    };
  }, [table, event, filter, enabled]);

  return status;
}

// ---------------------------------------------------------------------------
// row types (only the columns the UI reads)
// ---------------------------------------------------------------------------

export interface MarketRow {
  market_id: string;
  market_symbol: string;
  environment: string;
  market_status: string;
  is_active: boolean;
  base_symbol: string;
  base_decimals: number;
  quote_symbol: string;
  quote_decimals: number;
  price_scale: number;
  notional_scale: number;
  price_tick_units: Units;
  qty_step_units: Units;
  min_qty_units: Units;
  min_notional_units: Units;
  maker_fee_bps: number;
  taker_fee_bps: number;
}

export interface BalanceRow {
  user_id: string;
  account_id: string;
  environment: string;
  kind: string;
  asset_id: string;
  symbol: string;
  asset_name: string;
  base_decimals: number;
  available_units: Units;
  locked_units: Units;
  total_units: Units;
  balance_version: number | null;
  balance_updated_at: string | null;
}

export interface DepthRow {
  market_id: string;
  market_symbol: string;
  environment: string;
  side: 'buy' | 'sell';
  price_units: Units;
  qty_units: Units;
  order_count: number;
  oldest_order_at: string;
  cumulative_qty_units: Units;
}

export interface BestRow {
  market_id: string;
  market_symbol: string;
  environment: string;
  market_status: string;
  best_bid_units: Units;
  best_bid_qty_units: Units;
  best_ask_units: Units;
  best_ask_qty_units: Units;
  spread_units: Units;
  last_price_units: Units;
  last_trade_at: string | null;
}

export interface MarketStatsRow {
  market_id: string;
  market_symbol: string;
  environment: string;
  trade_count: number;
  open_price_units: Units;
  last_price_units: Units;
  low_price_units: Units;
  high_price_units: Units;
  volume_qty_units: Units;
  volume_quote_units: Units;
  last_trade_at: string | null;
}

export interface OrderRow {
  id: string;
  market_id: string;
  client_order_id: string | null;
  side: 'buy' | 'sell';
  type: 'limit' | 'market';
  time_in_force: string;
  price_units: Units;
  qty_units: Units;
  filled_qty_units: Units;
  filled_quote_units: Units;
  avg_price_units: Units;
  status: string;
  reject_reason: string | null;
  cancel_reason: string | null;
  environment: string;
  created_at: string;
  closed_at: string | null;
}

export interface TradeRow {
  id: string;
  market_id: string;
  price_units: Units;
  qty_units: Units;
  quote_units: Units;
  taker_fee_units: Units;
  maker_fee_units: Units;
  created_at: string;
}

export interface NotificationRow {
  id: string;
  user_id: string | null;
  type: string;
  title: string;
  body: string;
  read_at: string | null;
  created_at: string;
}

export interface AnnouncementRow {
  id: string;
  title: string;
  body: string;
  active_from: string;
  active_to: string | null;
}

export interface DepositRow {
  id: string;
  asset_id: string;
  network: string;
  environment: string;
  address: string | null;
  txid: string;
  amount_units: Units;
  confirmations: number;
  required_confirmations: number;
  status: string;
  detected_at: string;
  credited_at: string | null;
}

export interface DepositNetworkRow {
  asset_id: string;
  network: string;
  enabled: boolean;
  min_amount_units: Units;
  required_confirmations: number;
  [key: string]: unknown;
}

export interface DepositAddressRow {
  id: string;
  asset_id: string;
  network: string;
  address: string;
  memo: string | null;
  environment: string;
  created_at: string;
}

export interface WithdrawalNetworkRow {
  asset_id: string;
  network: string;
  enabled: boolean;
  min_amount_units: Units;
  fee_units: Units;
  [key: string]: unknown;
}

export interface WithdrawalRow {
  id: string;
  asset_id: string;
  network: string;
  environment: string;
  destination_address: string;
  amount_units: Units;
  fee_units: Units;
  status: string;
  requested_at: string;
  completed_at: string | null;
  failure_reason: string | null;
  review_reason: string | null;
}

export interface LedgerTransactionRow {
  id: string;
  type: string;
  environment: string;
  description: string | null;
  created_at: string;
  reference_type: string | null;
}

export interface KycStatusRow {
  level: number;
  provider: string | null;
  level_changed_at: string | null;
  updated_at: string;
}

export interface AssetRow {
  id: string;
  symbol: string;
  name: string;
  base_decimals: number;
}

export interface SystemHealthRow {
  component: string;
  status: string;
  detail: string | null;
  checked_at: string;
}

// ---------------------------------------------------------------------------
// reads
// ---------------------------------------------------------------------------

function unwrap<T>(res: { data: T | null; error: PostgrestLikeError | null }): T {
  if (res.error) throw res.error;
  return (res.data ?? []) as T;
}

export async function fetchMyBalances(): Promise<BalanceRow[]> {
  return unwrap<BalanceRow[]>(await supabase.from('v_my_balances').select('*').order('symbol'));
}

export async function fetchMarkets(): Promise<MarketRow[]> {
  return unwrap<MarketRow[]>(await supabase.from('v_markets').select('*').order('market_symbol'));
}

export async function fetchOrderBook(marketId: string | null): Promise<DepthRow[]> {
  let q = supabase.from('v_order_book_depth').select('*');
  if (marketId) q = q.eq('market_id', marketId);
  const res = await q;
  return unwrap<DepthRow[]>(res);
}

export async function fetchBestPrices(): Promise<BestRow[]> {
  return unwrap<BestRow[]>(await supabase.from('v_order_book_best').select('*').order('market_symbol'));
}

export async function fetchMarketStats(): Promise<MarketStatsRow[]> {
  return unwrap<MarketStatsRow[]>(await supabase.from('v_market_stats_24h').select('*').order('market_symbol'));
}

export async function fetchMyOrders(limit = 25): Promise<OrderRow[]> {
  return unwrap<OrderRow[]>(
    await supabase.from('orders').select('*').order('created_at', { ascending: false }).limit(limit),
  );
}

export async function fetchMyTrades(limit = 25): Promise<TradeRow[]> {
  return unwrap<TradeRow[]>(
    await supabase.from('trades').select('*').order('created_at', { ascending: false }).limit(limit),
  );
}

export async function fetchMyNotifications(limit = 20): Promise<NotificationRow[]> {
  return unwrap<NotificationRow[]>(
    await supabase.from('notifications').select('*').order('created_at', { ascending: false }).limit(limit),
  );
}

export async function fetchAnnouncements(): Promise<AnnouncementRow[]> {
  return unwrap<AnnouncementRow[]>(
    await supabase
      .from('v_public_announcements')
      .select('*')
      .order('active_from', { ascending: false })
      .limit(5),
  );
}

export async function fetchMyDeposits(limit = 20): Promise<DepositRow[]> {
  return unwrap<DepositRow[]>(
    await supabase.from('deposits').select('*').order('detected_at', { ascending: false }).limit(limit),
  );
}

export async function fetchMyWithdrawals(limit = 20): Promise<WithdrawalRow[]> {
  return unwrap<WithdrawalRow[]>(
    await supabase
      .from('withdrawal_requests')
      .select('*')
      .order('requested_at', { ascending: false })
      .limit(limit),
  );
}

export async function fetchMyLedger(limit = 25): Promise<LedgerTransactionRow[]> {
  return unwrap<LedgerTransactionRow[]>(
    await supabase.from('ledger_transactions').select('*').order('created_at', { ascending: false }).limit(limit),
  );
}

export async function fetchAssets(): Promise<AssetRow[]> {
  return unwrap<AssetRow[]>(await supabase.from('assets').select('*').order('symbol'));
}

export async function fetchDepositNetworks(): Promise<DepositNetworkRow[]> {
  return unwrap<DepositNetworkRow[]>(await supabase.from('deposit_networks').select('*'));
}

export async function fetchMyDepositAddresses(): Promise<DepositAddressRow[]> {
  return unwrap<DepositAddressRow[]>(
    await supabase.from('deposit_addresses').select('*').order('created_at', { ascending: false }),
  );
}

export async function fetchWithdrawalNetworks(): Promise<WithdrawalNetworkRow[]> {
  return unwrap<WithdrawalNetworkRow[]>(await supabase.from('withdrawal_networks').select('*'));
}

export interface KycLevelRow {
  level: number;
  name: string;
  description: string;
}

export async function fetchKycLevels(): Promise<KycLevelRow[]> {
  return unwrap<KycLevelRow[]>(await supabase.from('kyc_levels').select('*').order('level'));
}

export async function fetchSystemHealth(): Promise<SystemHealthRow[]> {
  return unwrap<SystemHealthRow[]>(await supabase.from('v_system_health').select('*'));
}

export async function fetchAppSettings(): Promise<{ mode: string; [key: string]: unknown } | null> {
  const res = await supabase.from('app_settings').select('*').limit(1).maybeSingle();
  if (res.error) throw res.error;
  return (res.data as { mode: string } | null) ?? null;
}

// ---------------------------------------------------------------------------
// RPCs (the only public entry points granted to `authenticated`)
// ---------------------------------------------------------------------------

export interface PlaceOrderArgs {
  marketSymbol: string;
  side: 'buy' | 'sell';
  type: 'limit' | 'market';
  qtyUnits: bigint;
  priceUnits: bigint | null;
  timeInForce?: 'gtc' | 'ioc' | 'fok';
  clientOrderId?: string | null;
}

/** The jsonb `place_order` / `cancel_order` return (mirrors public.order_result). */
export interface PlaceOrderResult {
  order_id?: string;
  market?: string;
  environment?: string;
  side?: string;
  type?: string;
  time_in_force?: string;
  status?: string;
  price_units?: Units;
  qty_units?: Units;
  filled_qty_units?: Units;
  filled_quote_units?: Units;
  avg_price_units?: Units;
  hold_units?: Units;
  hold_amount_units?: Units;
  client_order_id?: string | null;
  reject_reason?: string | null;
  cancel_reason?: string | null;
  created_at?: string;
  closed_at?: string | null;
  fills?: unknown[];
  trades?: unknown[];
}

export async function placeOrder(args: PlaceOrderArgs): Promise<PlaceOrderResult> {
  assertConfigured();
  const res = await supabase.rpc('place_order', {
    p_market_symbol: args.marketSymbol,
    p_side: args.side,
    p_type: args.type,
    p_qty_units: unitsParam(args.qtyUnits),
    p_price_units: args.priceUnits === null ? null : unitsParam(args.priceUnits),
    p_tif: args.timeInForce ?? 'gtc',
    p_client_order_id: args.clientOrderId ?? null,
    p_user_id: null, // identity comes from the JWT, never the client
  });
  if (res.error) throw res.error;
  return (res.data ?? {}) as PlaceOrderResult;
}

export async function cancelOrder(orderId: string, reason = 'user_canceled'): Promise<Record<string, unknown>> {
  assertConfigured();
  const res = await supabase.rpc('cancel_order', {
    p_order_id: orderId,
    p_reason: reason,
    p_user_id: null,
  });
  if (res.error) throw res.error;
  return (res.data ?? {}) as Record<string, unknown>;
}

export async function fetchMyKycStatus(): Promise<KycStatusRow | null> {
  assertConfigured();
  const res = await supabase.rpc('my_kyc_status');
  if (res.error) throw res.error;
  const rows = (res.data ?? []) as KycStatusRow[];
  return rows.length > 0 ? rows[0] : null;
}

export async function markNotificationRead(id: string): Promise<void> {
  assertConfigured();
  const res = await supabase.rpc('user_mark_notification_read', { p_notification_id: id });
  if (res.error) throw res.error;
}

export async function quoteWithdrawalFee(
  assetSymbol: string,
  network: string,
  amountUnits: bigint,
): Promise<Record<string, unknown>> {
  assertConfigured();
  const res = await supabase.rpc('quote_withdrawal_fee', {
    p_asset_symbol: assetSymbol,
    p_network: network,
    p_amount_units: unitsParam(amountUnits),
  });
  if (res.error) throw res.error;
  return (res.data ?? {}) as Record<string, unknown>;
}

export async function fetchAppMode(): Promise<string | null> {
  const res = await supabase.rpc('app_mode');
  if (res.error) throw res.error;
  return typeof res.data === 'string' ? res.data : null;
}
