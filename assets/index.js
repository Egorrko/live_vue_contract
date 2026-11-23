// Types live in index.d.ts. At runtime this is the LiveVue hook it is given, with an empty payload
// by default. No imports: the package resolves nothing from where it is installed.
export function useLiveEvents(live) {
  if (!live || typeof live.pushEvent !== "function")
    throw new Error("useLiveEvents(live): pass the LiveVue hook, useLiveEvents<Events>(useLiveVue())")

  return {
    pushEvent: (event, payload = {}) => live.pushEvent(event, payload),
    pushEventTo: (target, event, payload = {}) => live.pushEventTo(target, event, payload),
  }
}
