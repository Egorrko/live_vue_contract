# Changelog

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
