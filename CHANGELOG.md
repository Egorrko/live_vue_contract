# Changelog

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
