import { useLiveEvents } from "live_vue_contract"
import type { Author } from "./types"
import { hook } from "./hook"

export function useBoard() {
  const live = useLiveEvents<{ refresh: { reply: { authors: Author[] } } }>(hook)
  return { refresh: () => live.pushEvent("refresh") }
}
