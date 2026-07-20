/**
 * ARS-269 (slice B): Supabase Realtime listener for entitlements invalidation.
 *
 * Subscribes to INSERT on `platform_events` filtered to
 * event_type='entitlements.invalidated'. The RLS policy `platform_events_read_own`
 * (organization_id = any(fn_my_org_ids())) already scopes Realtime delivery to the
 * signed-in user's own org — no extra org filter is needed. Mirrors the existing
 * `useTaxonomyRealtimeSync` pattern (postgres_changes on platform_events).
 *
 * The event is emitted by d13_billing whenever a subscription's capabilities
 * change: subscribe / cancel / renewals engine / admin manual-pay / extend /
 * revoke (ARS-267). On receipt the caller re-pulls its membership snapshot so the
 * cabinet reflects the change in seconds instead of only on a full reload.
 *
 * Soft invalidation (M3 §5, D-FG-4): the client is never blocked — it works with
 * the last-good snapshot until the re-pull lands, and the server always enforces
 * access in real time via the TSP gates (fn_org_membership_active). This is UI
 * freshness, NOT a security gate.
 *
 * Mount once in the authenticated shell (CabinetApp). Safe to mount multiple
 * times — Supabase deduplicates by channel name.
 */
import { useEffect, useRef } from 'react'
import { supabase } from '@/lib/supabase'

export function useEntitlementsRealtimeSync(onInvalidated: () => void): void {
  // Hold the latest callback in a ref so passing a fresh closure each render does
  // NOT tear down and re-subscribe the channel (setup stays stable across renders).
  const cbRef = useRef(onInvalidated)
  cbRef.current = onInvalidated

  useEffect(() => {
    // Coalesce bursts: a single admin action can emit succeeded + renewed +
    // entitlements.invalidated back-to-back — debounce to a single re-pull.
    let timer: ReturnType<typeof setTimeout> | null = null
    const fire = () => {
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => { cbRef.current() }, 400)
    }

    const channel = supabase
      .channel('cabinet-entitlements')
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'platform_events',
          filter: 'event_type=eq.entitlements.invalidated',
        },
        () => { fire() },
      )
      .subscribe()

    return () => {
      if (timer) clearTimeout(timer)
      supabase.removeChannel(channel)
    }
  }, [])
}
