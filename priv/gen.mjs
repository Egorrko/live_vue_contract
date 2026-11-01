// Reads `defineProps<T>()` of every .vue file under the given roots and writes one JSON file:
// { "<component name>": <JSON-Schema subset> }.
// Usage (cwd = host app root, needs node_modules/vue-component-meta and typescript):
//   node gen.mjs tsconfig.json assets/vue/contract.json deps.json assets/vue [more roots...]
//
// vue-component-meta (Volar, the engine behind vue-tsc) lists each component's props and gives
// their TypeScript types; the schema is built from those types here, with the TypeScript checker,
// so mapped and generic types (Record, Partial, Pick, index signatures) get a real shape instead of
// a type name.
//
// The contract is rewritten only when its content changes: every `~H` module lists it as an
// external resource, so a rewrite with the same schemas would recompile them all for nothing.
// deps.json gets the project files the schemas were read from (the .vue files themselves and every
// file a type in a schema is declared in): the Mix compiler hashes only these, so an edit to code no
// prop type touches does not run this script at all.
import { createRequire } from "module"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "fs"
import path from "path"

const [tsconfig, out, depsOut, ...roots] = process.argv.slice(2)
const require = createRequire(path.resolve("package.json"))
const { createChecker } = require("vue-component-meta")
const ts = require("typescript")

const ANY = { type: "any" }
const deps = new Set()

function track(file) {
  const rel = path.relative(process.cwd(), file)
  if (!rel.startsWith("..") && !path.isAbsolute(rel) && !rel.split(path.sep).includes("node_modules")) deps.add(rel)
}

const isTsLib = file => /[\\/]typescript[\\/]lib[\\/]lib\..*\.d\.ts$/.test(file)

function declarations(type) {
  return [type.aliasSymbol, type.getSymbol()].flatMap(sym => sym?.getDeclarations() ?? [])
}

// `Date`, `HTMLElement`, `Map`, `Promise`… — interfaces and classes from TypeScript's own lib never
// travel over the wire as the object they describe. Mapped types declared there (`Record`,
// `Partial`, `Pick`) are structural and are expanded like any other object.
function opaqueLibType(type) {
  // `some`, not `every`: libraries augment lib interfaces (`interface HTMLElement { … }` in a .d.ts)
  const decls = type.getSymbol()?.getDeclarations() ?? []
  return decls.some(d =>
    isTsLib(d.getSourceFile().fileName) && (ts.isInterfaceDeclaration(d) || ts.isClassDeclaration(d) || ts.isVariableDeclaration(d)))
}

function union(schemas) {
  if (schemas.some(s => s.type === "any")) return ANY
  schemas = [...new Map(schemas.map(s => [JSON.stringify(s), s])).values()] // `null | undefined` -> one null
  let lits = schemas.filter(s => s.enum).flatMap(s => s.enum)
  const rest = schemas.filter(s => !s.enum)
  if (lits.includes(true) && lits.includes(false)) {
    lits = lits.filter(l => l !== true && l !== false)
    rest.push({ type: "boolean" })
  }
  const all = lits.length ? [...rest, { enum: [...new Set(lits)] }] : rest
  return all.length === 1 ? all[0] : { anyOf: all }
}

// Named object types (interfaces, type aliases, `Partial<Settings>`) are written once under
// "$defs" and referenced as {"$ref": name}: a type shared by many components costs one entry,
// and a recursive type refers to itself instead of being cut off.
const defs = {}
const defKeys = new Map() // ts.Type -> key in defs
const keyTypes = new Map() // key in defs -> ts.Type

function defName(type, checker) {
  const sym = type.aliasSymbol ?? type.getSymbol()
  const name = sym?.getName()
  if (!name || name.startsWith("__")) return null
  const full = checker.typeToString(type, undefined, ts.TypeFormatFlags.NoTruncation | ts.TypeFormatFlags.UseFullyQualifiedType)
  return full.replace(/import\(.*?\)\./g, "")
}

function defKey(type, name) {
  let key = name
  for (let i = 2; keyTypes.has(key) && keyTypes.get(key) !== type; i++) key = `${name}~${i}`
  defKeys.set(type, key)
  keyTypes.set(key, type)
  return key
}

// `stack` holds the anonymous object types being expanded right now: one met again inside itself
// is recursive and becomes `any` there (named types use "$defs" instead).
function toSchema(type, checker, stack) {
  for (const d of declarations(type)) track(d.getSourceFile().fileName)
  const f = type.flags
  const F = ts.TypeFlags

  if (f & (F.Any | F.Unknown | F.Never)) return ANY
  if (f & (F.Null | F.Undefined | F.Void)) return { type: "null" }
  if (f & F.Boolean) return { type: "boolean" }
  if (f & F.BooleanLiteral) return { enum: [checker.typeToString(type) === "true"] }
  if (f & F.StringLiteral) return { enum: [type.value] }
  if (f & F.NumberLiteral) return { enum: [type.value] }
  if (f & (F.String | F.TemplateLiteral | F.StringMapping)) return { type: "string" }
  if (f & (F.Number | F.BigInt | F.BigIntLiteral)) return { type: "number" }
  if (f & F.ESSymbolLike) return ANY
  if (type.isUnion()) return union(type.types.map(t => toSchema(t, checker, stack)))

  if (checker.isArrayType(type) || checker.isTupleType(type)) {
    const args = checker.getTypeArguments(type)
    return { type: "array", items: args.length ? union(args.map(t => toSchema(t, checker, stack))) : ANY }
  }

  if (!(f & F.Object) && !type.isIntersection()) return ANY
  if (type.getCallSignatures().length > 0 || type.getConstructSignatures().length > 0) return ANY
  if (opaqueLibType(type)) return ANY
  if (defKeys.has(type)) return { $ref: defKeys.get(type) }

  const name = defName(type, checker)
  if (name) {
    const key = defKey(type, name)
    defs[key] = ANY // placeholder while the type is expanded: a self-reference finds the key
    defs[key] = objectSchema(type, checker, [])
    return { $ref: key }
  }

  if (stack.includes(type)) return ANY
  return objectSchema(type, checker, [...stack, type])
}

function objectSchema(type, checker, inner) {
  const F = ts.TypeFlags
  const properties = {}
  const required = []

  for (const prop of checker.getPropertiesOfType(type)) {
    for (const d of prop.getDeclarations() ?? []) track(d.getSourceFile().fileName)
    properties[prop.name] = toSchema(checker.getTypeOfSymbol(prop), checker, inner)
    if (!(prop.flags & ts.SymbolFlags.Optional)) required.push(prop.name)
  }

  const schema = { type: "object", properties, required }
  const index = checker.getIndexInfosOfType(type).filter(i => !(i.keyType.flags & F.ESSymbolLike))
  if (index.length) schema.additionalProperties = union(index.map(i => toSchema(i.type, checker, inner)))
  // `{}` and `object` say nothing about the keys: accept any
  else if (Object.keys(properties).length === 0) schema.additionalProperties = ANY

  return schema
}

// The TypeScript checker that owns a prop's type. Types carry it; the schema option is a fallback
// that hands it to us without expanding anything.
let fromMeta
const checker = createChecker(path.resolve(tsconfig), {
  forceUseTs: true,
  noDeclarations: false,
  schema: { ignore: [(_name, _type, typeChecker) => ((fromMeta ??= typeChecker), true)] },
})

function typeCheckerOf(prop, type) {
  if (type.checker) return type.checker
  void prop.schema
  if (fromMeta) return fromMeta
  throw new Error("live_vue_contract: cannot reach the TypeScript checker through vue-component-meta")
}

function componentSchema(file) {
  const props = checker.getComponentMeta(path.resolve(file)).props.filter(p => !p.global)
  const properties = {}
  const required = []

  for (const p of props) {
    const type = p.getTypeObject()
    properties[p.name] = toSchema(type, typeCheckerOf(p, type), [])
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
    contract[path.relative(root, file).replace(/\.vue$/, "")] = componentSchema(file)
    track(file)
  }
}

const sortKeys = o => Object.fromEntries(Object.keys(o).sort().map(k => [k, o[k]]))
const sorted = sortKeys(contract)
if (Object.keys(defs).length) sorted.$defs = sortKeys(defs)
const json = JSON.stringify(sorted, null, 2) + "\n"
const same = existsSync(out) && readFileSync(out, "utf8") === json
if (!same) writeFileSync(out, json)
writeFileSync(depsOut, JSON.stringify([...deps].sort()) + "\n")
console.log(`live_vue_contract: ${Object.keys(contract).length} components -> ${out}${same ? " (unchanged)" : ""}`)
