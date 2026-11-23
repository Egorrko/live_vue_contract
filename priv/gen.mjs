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

function acceptsUndefined(type) {
  const F = ts.TypeFlags
  const types = type.isUnion() ? type.types : [type]
  return types.some(t => t.flags & (F.Any | F.Unknown | F.Undefined | F.Void))
}

function objectSchema(type, checker, inner) {
  const F = ts.TypeFlags
  const properties = {}
  const required = []

  for (const prop of checker.getPropertiesOfType(type)) {
    for (const d of prop.getDeclarations() ?? []) track(d.getSourceFile().fileName)
    properties[prop.name] = toSchema(checker.getTypeOfSymbol(prop), checker, inner)
    const propType = checker.getTypeOfSymbol(prop)
    // `x: unknown` / `x: T | undefined`: JSON drops undefined, so on the wire the key may be absent
    if (!(prop.flags & ts.SymbolFlags.Optional) && !acceptsUndefined(propType)) required.push(prop.name)
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
const componentFiles = new Map() // contract key -> absolute path
for (const root of roots) {
  for (const file of vueFiles(root)) {
    const key = path.relative(root, file).replace(/\.vue$/, "")
    contract[key] = componentSchema(file)
    componentFiles.set(key, path.resolve(file))
    track(file)
  }
}

// ---- Events: `useLiveEvents<{ name: { payload; reply } }>()` from the "live_vue_contract" package ----
//
// A declaration belongs to the file it is written in. The server only knows which root component
// it rendered, so every component is credited with the declarations reachable through its runtime
// imports (a child component, a composable). Same event name, same shape: one entry; another shape
// in another component: a separate entry, picked on the server by the component that was rendered.

const program = checker.getProgram()
const tc = program.getTypeChecker()
const inProject = file => {
  const rel = path.relative(process.cwd(), file)
  return !rel.startsWith("..") && !path.isAbsolute(rel) && !rel.split(path.sep).includes("node_modules")
}
const rel = file => path.relative(process.cwd(), file)

function isUseLiveEvents(call) {
  let sym = tc.getSymbolAtLocation(call.expression)
  if (sym && sym.flags & ts.SymbolFlags.Alias) sym = tc.getAliasedSymbol(sym)
  return !!sym && sym.getName() === "useLiveEvents" &&
    (sym.getDeclarations() ?? []).some(d => /[\\/]live_vue_contract[\\/]/.test(d.getSourceFile().fileName) || /[\\/]live_vue_contract[\\/]/.test(realPath(d.getSourceFile().fileName)))
}

function realPath(file) {
  try { return ts.sys.realpath ? ts.sys.realpath(file) : file } catch { return file }
}

function walk(node, visit) {
  visit(node)
  ts.forEachChild(node, child => walk(child, visit))
}

const NO_PAYLOAD = { type: "object", properties: {}, required: [] }

// file -> [{ event, payload, reply }]
const declared = new Map()
// file -> [resolved project files it imports at runtime]
const imports = new Map()

for (const sf of program.getSourceFiles()) {
  if (!inProject(sf.fileName)) continue
  const deps = []
  const decls = []
  walk(sf, node => {
    let spec = null
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      const typeOnly = ts.isImportDeclaration(node) ? node.importClause?.isTypeOnly : node.isTypeOnly
      if (!typeOnly) spec = node.moduleSpecifier
    } else if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword && node.arguments[0] && ts.isStringLiteral(node.arguments[0])) {
      spec = node.arguments[0]
    }
    if (spec) {
      const target = program.getResolvedModuleFromModuleSpecifier(spec, sf)?.resolvedModule?.resolvedFileName
      if (target && inProject(target)) deps.push(path.resolve(target))
    }

    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && isUseLiveEvents(node)) {
      const arg = node.typeArguments?.[0]
      if (!arg) throw new Error(`live_vue_contract: useLiveEvents() without a type argument in ${rel(sf.fileName)}`)
      const map = tc.getTypeFromTypeNode(arg)
      for (const prop of tc.getPropertiesOfType(map)) {
        const spec = tc.getTypeOfSymbol(prop)
        const part = name => {
          const sym = spec.getProperty(name)
          return sym ? toSchema(tc.getTypeOfSymbol(sym), tc, []) : null
        }
        decls.push({ event: prop.name, payload: part("payload") ?? NO_PAYLOAD, reply: part("reply") })
      }
    }
  })
  imports.set(path.resolve(sf.fileName), deps)
  if (decls.length) declared.set(path.resolve(sf.fileName), decls)
}

// declaring files reachable from `file` through runtime imports; files on a path to one are
// sources of the contract too (an import that adds or drops a child changes it)
const reach = new Map()
function reachable(file, seen = new Set()) {
  if (reach.has(file)) return reach.get(file)
  if (seen.has(file)) return new Set()
  seen.add(file)
  const out = new Set(declared.has(file) ? [file] : [])
  for (const dep of imports.get(file) ?? []) for (const f of reachable(dep, seen)) out.add(f)
  // a result computed inside a cycle may be partial; cache only from the outermost call
  if (seen.size === 1) reach.set(file, out)
  return out
}

const events = {}
for (const [key, file] of componentFiles) {
  const files = reachable(file)
  if (files.size) {
    track(file)
    for (const dep of imports.get(file) ?? []) if (reachable(dep).size) track(dep)
  }
  for (const f of files) {
    track(f)
    for (const d of declared.get(f)) {
      const variants = (events[d.event] ??= [])
      const shape = JSON.stringify([d.payload, d.reply])
      let v = variants.find(x => JSON.stringify([x.payload, x.reply]) === shape)
      if (!v) variants.push((v = { payload: d.payload, reply: d.reply, components: [], declared: [] }))
      if (!v.components.includes(key)) v.components.push(key)
      if (!v.declared.includes(rel(f))) v.declared.push(rel(f))
    }
  }
}
for (const variants of Object.values(events)) for (const v of variants) { v.components.sort(); v.declared.sort() }

const sortKeys = o => Object.fromEntries(Object.keys(o).sort().map(k => [k, o[k]]))
const sorted = sortKeys(contract)
if (Object.keys(defs).length) sorted.$defs = sortKeys(defs)
if (Object.keys(events).length) sorted.$events = sortKeys(events)
const json = JSON.stringify(sorted, null, 2) + "\n"
const same = existsSync(out) && readFileSync(out, "utf8") === json
if (!same) writeFileSync(out, json)
writeFileSync(depsOut, JSON.stringify([...deps].sort()) + "\n")
console.log(`live_vue_contract: ${Object.keys(contract).length} components, ${Object.keys(events).length} events -> ${out}${same ? " (unchanged)" : ""}`)
