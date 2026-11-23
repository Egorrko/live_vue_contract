// stands in for `useLiveVue()` of live_vue, which the fixture does not install
export const hook = {
  pushEvent: (_event: string, _payload?: object) => Promise.resolve({}),
  pushEventTo: (_target: unknown, _event: string, _payload?: object) => Promise.resolve({}),
}
