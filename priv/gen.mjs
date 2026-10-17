// Reads `defineProps<T>()` of every .vue file under the given roots via vue-component-meta
// and writes one JSON file: { "<component name>": <JSON-Schema subset> }.
// Usage (cwd = host app root, needs node_modules/vue-component-meta):
//   node gen.mjs tsconfig.json assets/vue/contract.json deps.json assets/vue [more roots...]
// The contract is rewritten only when its content changes: every `~H` module lists it as an
// external resource, so a rewrite with the same schemas would recompile them all for nothing.
// deps.json gets the project files the schemas were read from (the .vue files themselves, prop
// declarations, every type expanded into a schema): the Mix compiler hashes only these, so an edit
// to code that no prop type touches does not run this script at all.
import { createRequire } from "module"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "fs"
import path from "path"

const [tsconfig, out, depsOut, ...roots] = process.argv.slice(2)
const deps = new Set()
const track = file => {
  const rel = path.relative(process.cwd(), file)
  if (!rel.startsWith("..") && !path.isAbsolute(rel) && !rel.split(path.sep).includes("node_modules")) deps.add(rel)
}
const require = createRequire(path.resolve("package.json"))
const { createChecker } = require("vue-component-meta")
const ts = require("typescript")

// Types declared only in TypeScript's own lib (DOM, Promise, Map, Date...) never travel over the
// wire as objects: leave them unexpanded, they become `any` below. Everything else is expanded.
// Generic instantiations (Array<T>, Partial<T>, Record<K, V>) are still expanded: their shape is ours.
// The schema resolver asks this for every type it meets, so it is also where deps are collected.
const fromTsLib = (_name, type, typeChecker) => {
  for (const sym of [type.aliasSymbol, type.getSymbol()])
    for (const d of sym?.getDeclarations() ?? []) track(d.getSourceFile().fileName)
  const args = type.aliasTypeArguments ?? (type.objectFlags & ts.ObjectFlags.Reference ? typeChecker.getTypeArguments(type) : [])
  const decls = (type.aliasSymbol ?? type.getSymbol())?.getDeclarations() ?? []
  return args.length === 0 && decls.length > 0 &&
    decls.every(d => /[\\/]typescript[\\/]lib[\\/]lib\..*\.d\.ts$/.test(d.getSourceFile().fileName))
}
const checker = createChecker(path.resolve(tsconfig), { forceUseTs: true, schema: { ignore: [fromTsLib] } })

const ANY = { type: "any" }
const PRIM = { string: "string", number: "number", boolean: "boolean", null: "null", undefined: "null" }

// "string | null" or a single type name -> schema
function fromTypeString(s) {
  const parts = s.split(" | ").map(p => p.trim())
  const schemas = parts.map(p => {
    if (PRIM[p]) return { type: PRIM[p] }
    if (/^".*"$/.test(p) || /^-?\d+(\.\d+)?$/.test(p) || p === "true" || p === "false") {
      try { return { enum: [JSON.parse(p)] } } catch { return ANY }
    }
    return ANY
  })
  return union(schemas)
}

function union(schemas) {
  if (schemas.some(s => s.type === "any")) return ANY
  schemas = [...new Map(schemas.map(s => [JSON.stringify(s), s])).values()] // `null | undefined` -> one null
  const lits = schemas.filter(s => s.enum).flatMap(s => s.enum)
  const rest = schemas.filter(s => !s.enum)
  const all = lits.length ? [...rest, { enum: lits }] : rest
  return all.length === 1 ? all[0] : { anyOf: all }
}

function toSchema(s, seen = new Set()) {
  if (typeof s === "string") return fromTypeString(s)
  switch (s.kind) {
    case "literal":
      try { return { enum: [JSON.parse(s.value)] } } catch { return ANY }
    case "enum":
      if (s.type === "boolean") return { type: "boolean" }
      return union((s.schema || []).map(m => toSchema(m, seen)))
    case "array":
      return { type: "array", items: s.schema?.length ? union(s.schema.map(m => toSchema(m, seen))) : ANY }
    case "object": {
      if (seen.has(s.type)) return ANY // recursive type: stop here
      const next = new Set(seen).add(s.type)
      return object(Object.values(s.schema || {}), next)
    }
    default:
      return ANY
  }
}

function object(props, seen) {
  const properties = {}
  const required = []
  for (const p of props) {
    for (const d of p.getDeclarations?.() ?? []) track(d.file)
    properties[p.name] = toSchema(p.schema, seen)
    if (p.required) required.push(p.name)
  }
  return { type: "object", properties, required }
}

function* vueFiles(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) yield* vueFiles(p)
    else if (e.name.endsWith(".vue")) yield p
  }
}

const contract = {}
for (const root of roots) {
  for (const file of vueFiles(root)) {
    const name = path.relative(root, file).replace(/\.vue$/, "")
    const props = checker.getComponentMeta(path.resolve(file)).props.filter(p => !p.global)
    contract[name] = object(props, new Set())
    track(file)
  }
}

const sorted = Object.fromEntries(Object.keys(contract).sort().map(k => [k, contract[k]]))
const json = JSON.stringify(sorted, null, 2) + "\n"
const same = existsSync(out) && readFileSync(out, "utf8") === json
if (!same) writeFileSync(out, json)
writeFileSync(depsOut, JSON.stringify([...deps].sort()) + "\n")
console.log(`live_vue_contract: ${Object.keys(contract).length} components -> ${out}${same ? " (unchanged)" : ""}`)
