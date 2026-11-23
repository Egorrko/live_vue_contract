# Changelog

## Unreleased

- **Contract without fallthrough attributes.** With `vueCompilerOptions.fallthroughAttributes` on
  in the host's tsconfig, vue-component-meta listed every attribute of a component's root element as
  its prop — all of HTML, or a library component's whole API — and the contract grew to hundreds of
  MB (320 MB in one app), parsed by every BEAM on the first render. The generator now reads the
  tsconfig with that option forced off; vue-tsc keeps it.

## 0.5.1 — 2026-11-23

- `mix live_vue_contract.coverage` counts every component: the report loads the app's modules
  before looking for templates, so it no longer sees only those a test helper happened to load.

## 0.5.0 — 2026-11-23

- **Coverage of partitioned runs.** Under `mix test --partitions N` each partition adds what it
  saw to `_build/live_vue_contract_coverage/<partition>.etf` instead of printing a partial report;
  `mix live_vue_contract.coverage` merges the files into one report and deletes them.
  `Coverage.start(export: name)` does the same for other ways of splitting a run.

## 0.4.0 — 2026-11-23

- **Events.** `useLiveEvents<{ name: { payload; reply } }>(useLiveVue())` from the new
  `live_vue_contract` npm package (in the Hex package, `"file:./deps/live_vue_contract"`) types
  `pushEvent` on the client, so replies need no `as`. The generator writes the declarations to
  `"$events"` of the contract, crediting each to every component that imports it at runtime.
  `use LiveVueContract` wraps `handle_event/3` of LiveViews and LiveComponents when validation is on
  at compile time and checks the params, the reply (after a JSON round trip) and a missing reply.
- **Coverage.** `LiveVueContract.Coverage.start()` in `test_helper.exs` prints which `<.vue>`
  components no test rendered and which declared events no test pushed.
- A discriminated union (`{ ok: true } | { ok: false; error: string }`) is reported against the
  alternative its literal key picks, not the first one with as many errors.
- Error messages for props read "props of <.vue v-component=…> does not match defineProps in
  <key>.vue" and name the resolved contract key.
- The Mix compiler also hashes scripts under `:vue_root` that import "live_vue_contract", so a new
  `useLiveEvents` regenerates the contract.
- A union of partials (`Partial<A> | Partial<B>`) picks the alternative that declares the value's
  keys: ties on errors are broken by fewer unknown keys, so `strict` no longer fails a valid value.
- A property typed `unknown`, `any` or `T | undefined` is not required: JSON drops `undefined`.
- `validate: :warn` no longer breaks compilation (`BadBooleanError` in the `handle_event` wrapper).
- `useLiveEvents` accepts LiveVue's `LiveHook` even when phoenix_live_view's types do not resolve
  and `LiveHook` collapses to an index signature.

## 0.3.1 — 2026-11-01

- `.heex` files are checked by `use LiveVueContract` itself: templates from `embed_templates` and a
  LiveView's colocated template, in any module with `use LiveVueContract`. No config needed.
- `LiveVueContract.HEExEngine` is removed: set in `config :phoenix, :template_engines`, it also
  applied to dependencies, and a dependency with `.heex` files (`oban_web`) failed to compile on a
  clean build, before live_vue_contract itself was compiled. Delete that config line.

## 0.3.0 — 2026-11-01

- The generator builds schemas from the TypeScript types itself (vue-component-meta only lists the
  props): `Record<K, V>`, index signatures, `Partial`, `Pick`, intersections, tuples, enums and
  template literal types are checked instead of becoming `any`.
- Named types go to `"$defs"` in the contract and are referenced with `{"$ref": name}`: a type
  shared by many components is written once, and recursive types are checked at every depth.
- A template whose source has more `<.vue>` tags than the compile-time walk found is a
  `CompileError`: a Phoenix LiveView release that changes compiled HEEx can no longer turn the
  check off silently.
- `LiveVueContract.HEExEngine` checks `<.vue>` in `.heex` files
  (`config :phoenix, :template_engines, heex: LiveVueContract.HEExEngine`).
- Compile errors point at the line of the tag in `.heex` files too.
- The generator script is part of the stamp hash: upgrading the library regenerates the contract.
- `phoenix_live_view ~> 1.1` is a direct dependency. Published on Hex.
- Tests: real templates compiled through `~H` and the `.heex` engine; the generator and the Mix
  compiler against a fixture Vue project with a checked-in expected contract. CI covers the oldest,
  locked and newest versions, and runs weekly.

## 0.2.0 — 2026-10-17

- The source hash moved from `"$sources"` in the contract to a stamp in the Mix manifest directory
  (`_build/<env>`); `LiveVueContract.Schema.sources/0` is gone. Old contracts still load.
- The contract is rewritten only when its schemas change: an edit that leaves props as they were no
  longer recompiles every `~H` module (they list the contract as an external resource).
- Sources are the `.vue` files plus the project files the generator actually read prop types from;
  `:watch` now defaults to `[]` and only adds extra globs. Editing code no prop type touches does not
  run node.
- Without `node` and without a stamp, an existing contract is used without a freshness check.

## 0.1.0 — 2026-09-19

First release.

- `use LiveVueContract`: replaces `use LiveVue` and `use LiveVue.Components`; `~H` checks every
  literal `<.vue>` / `<.ComponentName>` against `defineProps` at compile time; `vue/1` validates
  encoded props against the nested schema at render time in dev and test.
- `:live_vue_contract` Mix compiler: generates `assets/vue/contract.json` with `vue-component-meta`,
  regenerates by source hash, compiles without `node` when the committed file is fresh.
- `validate: :warn` for rolling out on projects with existing drift; `strict: true` for extra keys.
- Names resolve like LiveVue's `findComponent` (path suffix, `index` ignored, ambiguity is an error).
- Types declared only in TypeScript's lib (DOM, `Promise`, …) are not expanded; generic instantiations are.
- Atoms are compared as the strings they become on the wire; LiveStream props are skipped.

Verified on two Phoenix + Ash + LiveVue applications (19 and 16 root components): all planted
breakages red, one real drift found in each, no false positives left in their suites.
