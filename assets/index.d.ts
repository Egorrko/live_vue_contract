/**
 * One event a component sends with `pushEvent`: the payload it sends and the map
 * `handle_event` returns with `{:reply, map, socket}`. Leave `reply` out for `{:noreply, socket}`,
 * `payload` out for an event sent without one.
 */
export interface EventSpec {
  payload?: object
  reply?: object
}

/** Event name -> what it carries. The type argument of `useLiveEvents`. */
export type EventMap = { [event: string]: EventSpec }

type PayloadArgs<S> = S extends { payload: infer P } ? [payload: P] : [payload?: Record<string, never>]
type Reply<S> = S extends { reply: infer R } ? R : void

export interface LiveEvents<E extends EventMap> {
  /** `pushEvent` of LiveVue, typed by the event map. Resolves with the reply of `handle_event`. */
  pushEvent<K extends keyof E & string>(event: K, ...payload: PayloadArgs<E[K]>): Promise<Reply<E[K]>>
  /** `pushEventTo` of LiveVue, typed by the event map. */
  pushEventTo<K extends keyof E & string>(
    target: string | HTMLElement,
    event: K,
    ...payload: PayloadArgs<E[K]>
  ): Promise<Reply<E[K]>>
}

/**
 * The events this component sends to its LiveView, declared once:
 *
 *     import { useLiveVue } from "live_vue"
 *     import { useLiveEvents } from "live_vue_contract"
 *
 *     const live = useLiveEvents<{
 *       join: { payload: { room: string }; reply: { ok: boolean } }
 *       leave: {}
 *     }>(useLiveVue())
 *     const reply = await live.pushEvent("join", { room: "lobby" }) // { ok: boolean }
 *
 * live_vue_contract reads the type argument and, in dev and test, checks the params
 * `handle_event` receives and the map it replies with against it.
 */
export function useLiveEvents<E extends EventMap>(live: LiveVueHook): LiveEvents<E>

/** The part of LiveVue's `useLiveVue()` hook this wraps. */
export interface LiveVueHook {
  pushEvent(event: string, payload?: object): Promise<any> | void
  pushEventTo(target: any, event: string, payload?: object): Promise<any> | void
}
