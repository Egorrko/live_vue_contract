# live_vue_contract

Makes the props contract between `<.vue ...>` in LiveView and `defineProps<T>()` in Vue red on
`mix compile` / `mix test` instead of in production.

[LiveVue](https://github.com/Valian/live_vue) passes data from LiveView to a Vue component as props.
The shape of that data is written twice: implicitly on the Elixir side (whatever ends up in the
assign) and explicitly in TypeScript (`defineProps<{ units: Unit[]; total: number }>()`). Nothing
checks one against the other: rename a key in the presenter and both compilers stay silent, tests
stay green unless one asserts that exact key, and Vue renders `undefined` as an empty cell.

This library takes `defineProps<T>()` as the single source of truth and checks the Elixir side
against it. Nothing is described a second time.

| Drift | Caught at |
|---|---|
| `<.vue>` does not pass a required prop | `mix compile` |
| `<.vue>` passes a prop the component does not declare | `mix compile` |
| `v-component="UnitLst"` — typo, or an ambiguous name | `mix compile` |
| presenter renames or drops a key, at any depth (`items[].statusLabel`) | `mix test`, dev runtime |
| string where TS says `number`, `null` where TS says non-nullable, value outside a union of literals | `mix test`, dev runtime |
| wrong value inside a `Record<string, T>`, an index signature, `Partial<T>`, `Pick<T, K>`, a recursive type | `mix test`, dev runtime |
| server sends a key the TS type does not know | warning in the log (`strict: true` makes it an error) |

"`mix test`" means: any live test that renders the screen. "dev runtime" means: the first render in
`mix phx.server` raises with the JSON path of the problem.

## How it works

```
.vue (defineProps<T>)  --vue-component-meta-->  assets/vue/contract.json   (Mix compiler, by source hash)
                                                       │
                     ┌─────────────────────────────────┴───────────────────────────────┐
     ~H at compile time: attributes of <.vue v-component="X"> ⟷ keys of schema X   vue/1 at render (dev/test):
     missing required / undeclared / unknown component → CompileError              encoded props ⟷ nested schema
                                                                                   → ArgumentError with a JSON path
```

1. A Mix compiler (`:live_vue_contract`) runs [`vue-component-meta`](https://www.npmjs.com/package/vue-component-meta)
   (the same Volar engine `vue-tsc` uses) over every `.vue` file to list its props, builds a
   JSON-Schema subset from their TypeScript types and writes it to `assets/vue/contract.json`.
   Named types (`Author`, `Record<string, Author>`) are written once under `"$defs"` and referenced,
   so shared and recursive types cost one entry. It reruns only when a `.vue` file, a file a prop type
   is declared in, or the generator itself changed.
2. `use LiveVueContract` overrides `~H` (and `LiveVueContract.HEExEngine` does the same for `.heex`
   files). After the template is compiled as usual, the HEEx AST is walked and every literal
   `<.vue v-component="X" ...>` (and every `<.X>` shortcut) is compared with the schema of `X`.
   The walk depends on what Phoenix LiveView compiles a function component to; the tags are also
   counted in the template source, and a template where the walk found fewer is a `CompileError`, so a
   LiveView release that changes that form breaks the build instead of turning the check off.
3. `LiveVueContract.vue/1` replaces `LiveVue.vue/1`. In dev and test it encodes the props exactly as
   LiveVue would and validates them against the nested schema before rendering. In a release it is a
   pass-through.

## Installation

```elixir
# mix.exs
def project do
  [
    ...,
    compilers: [:live_vue_contract, :phoenix_live_view] ++ Mix.compilers()
  ]
end

defp deps do
  [
    ...,
    {:live_vue_contract, "~> 0.3"}
  ]
end
```

```elixir
# lib/my_app_web.ex, inside html_helpers — replaces `use LiveVue` and `use LiveVue.Components`
use LiveVueContract
```

```elixir
# config/config.exs — only if `<.vue>` tags live in .heex files (colocated templates, embed_templates)
config :phoenix, :template_engines, heex: LiveVueContract.HEExEngine
```

```sh
npm install -D vue-component-meta@$(node -p "require('vue-tsc/package.json').version")
mix compile      # writes assets/vue/contract.json
git add assets/vue/contract.json
```

`vue-component-meta` must be the same version as your `vue-tsc`; both come from the Volar monorepo.

If your `html_helpers` imported `LiveVue.SharedPropsView` (shared props, automatic `v-socket`),
keep that behaviour with:

```elixir
use LiveVueContract, shared_props: true
```

## Configuration

```elixir
config :live_vue_contract,
  vue_root: ["assets/vue"],           # where the components live, like LiveVue.Components
  watch: [],                          # extra globs that regenerate the contract (prop types are tracked)
  contract: "assets/vue/contract.json",
  tsconfig: "tsconfig.json",
  validate: true,                     # render-time validation; default: on under Mix outside :prod
  strict: false                       # extra nested keys: warning (false) or error (true)
```

`use LiveVueContract` options: `shared_props: true` (compile through `LiveVue.SharedPropsView`),
`shortcuts: false` (do not define `<.ComponentName>` functions).

## Rolling out on an existing project

The first run on a real project usually finds drift you did not know about. To keep the suite green
while you fix it:

```elixir
# config/test.exs, config/dev.exs
config :live_vue_contract, validate: :warn
```

Every mismatch is then logged once per component and key instead of raising. Remove the line when
the log is clean. `strict: true` turns "server sends a key the type does not know" into an error too.

## CI and Docker

- What the contract was built from (hash and list of source files) is kept in a stamp under
  `_build/<env>`, not in the contract. Node runs only when a `.vue` file or a file a prop type is
  declared in changed; the contract is rewritten only when the schemas changed, so `~H` modules
  are not recompiled for edits that do not touch props.
- Without `node`: a committed `assets/vue/contract.json` is used as is (with a note) when `_build`
  has no stamp; a missing contract fails `mix compile` with a message saying so.
- To assert freshness in CI where `node` is available: `mix compile && git diff --exit-code assets/vue/contract.json`.
- If your Dockerfile runs `mix compile` before `COPY assets` (the Phoenix default), there are no
  `.vue` files at that point and the compiler is a no-op; the later `mix release` sees the committed
  contract and checks against it.

## What it does not catch

- **Screens nobody renders in a test.** Nested-value checks (renamed key, wrong type) run at render
  time, so a root component without a live test gets only the compile-time attribute check.
- **Values your tests never produce.** The render-time check sees the data the test rendered: a `nil`
  branch, a rare enum value or an empty list that only production data has goes unchecked. It is off
  in releases.
- **Dynamic tags.** `v-component={@name}` and `<.vue {@rest}>` are skipped at compile time and
  checked at render time only.
- **TypeScript's lib types and functions.** `Date`, `HTMLElement`, `Map`, `Promise`, `unknown`,
  `object` and function types become `any`: none of them is a JSON shape. (Mapped and generic types —
  `Record`, `Partial`, `Pick`, your own generics — are expanded.)
- **Distinctions JSON does not make.** `Date` and `DateTime` are both `string`; `integer` and `float`
  are both `number`.
- **Events.** `pushEvent` / `handle_event` and `push_event` / `useLiveEvent` are not covered.

## Requirements

- Elixir 1.18+ (uses the built-in `JSON` module), Phoenix LiveView 1.1+, LiveVue 1.2+.
- Node.js with `vue-component-meta` and `typescript` in the host project's `node_modules`, only on
  machines that regenerate the contract.

CI runs the oldest supported versions (Elixir 1.18, LiveView 1.1, LiveVue 1.2.0), the locked ones, and
the newest on Hex — the last also weekly, so a LiveView release that changes compiled HEEx shows up
here first.

## Development

```sh
mix deps.get
npm ci --prefix test/fixtures/app   # generator tests; skipped without it
mix test
```

`test/fixtures/app` is a small Vue project whose `defineProps` cover every shape the generator maps;
its expected contract is checked in (`contract.expected.json`). After a deliberate change to the
generator: `LIVE_VUE_CONTRACT_UPDATE=1 mix test` and review the diff.

The Elixir tests cover the schema validator and name resolution. The generator is exercised against
real projects; see `CHANGELOG.md` for what it was verified on.

## License

MIT
