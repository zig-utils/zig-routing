// Check or regenerate the Zig schema tables from the pinned Valhalla checkout.
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const pin = '5c7f918e61306521d79cc4496d40c19c5305fa4b'
const [mode, checkout] = Bun.argv.slice(2)
if ((mode !== '--write' && mode !== '--check') || !checkout)
  throw new Error('usage: bun tools/proto/valhalla.ts --check|--write VALHALLA_CHECKOUT')

function run(argv: string[], input?: string): string {
  const child = Bun.spawnSync(argv, { stdin: input === undefined ? 'ignore' : new TextEncoder().encode(input), stderr: 'pipe' })
  if (child.exitCode !== 0) throw new Error(argv.join(' ') + ': ' + child.stderr.toString())
  return child.stdout.toString()
}
if (run(['git', '-C', checkout, 'rev-parse', 'HEAD']).trim() !== pin)
  throw new Error('expected the Valhalla 3.9.3 checkout at ' + pin)

type Label = 'optional' | 'required' | 'repeated'
type Field = {
  name: string
  number: number
  type: string
  label?: Label
  oneof?: string
  options: Record<string, string>
  map_entry_field?: boolean
}
type EnumValue = { name: string, number: number, options: Record<string, string> }
type File = { name: string, syntax: string, package: string, definitions: Definition[] }
type Path = { file: File, name: string[] }
type Definition = Path & ({ kind: 'message', fields: Field[] } | { kind: 'enum', values: EnumValue[] })

const namePattern = /^[A-Za-z_][A-Za-z_0-9]*$/
function tokenize(source: string): string[] {
  const token = /\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z_0-9]*|\d+|[=;{}[\],<.>+()\-]/gy
  const out: string[] = []
  while (token.lastIndex < source.length) {
    const at = token.lastIndex
    const match = token.exec(source)
    if (!match) throw new Error('unexpected proto source near ' + source.slice(at, at + 40))
    const value = match[0]!
    if (!/^\s/.test(value) && !value.startsWith('/')) out.push(value)
  }
  return out
}

class Parser {
  private at = 0
  constructor(private file: File, private tokens: string[]) {}

  private fail(message: string): never {
    throw new Error(this.file.name + ' near token ' + this.at + ': ' + message)
  }

  private peek(): string | undefined { return this.tokens[this.at] }

  private take(): string {
    return this.tokens[this.at++] ?? this.fail('unexpected end of file')
  }

  private accept(token: string): boolean {
    if (this.peek() !== token) return false
    this.at++
    return true
  }

  private expect(token: string): void {
    const actual = this.take()
    if (actual !== token) this.fail('expected ' + token + ', got ' + actual)
  }

  private name(): string {
    const token = this.take()
    if (!namePattern.test(token)) this.fail('expected an identifier, got ' + token)
    return token
  }

  private number(): number {
    const sign = this.accept('-') ? -1 : 1
    const token = this.take()
    if (!/^\d+$/.test(token) || !Number.isSafeInteger(Number(token))) this.fail('invalid number ' + token)
    return sign * Number(token)
  }

  private qualified(): string {
    let value = this.accept('.') ? '.' : ''
    value += this.name()
    while (this.accept('.')) value += '.' + this.name()
    return value
  }

  private statement(): void {
    while (this.take() !== ';') {}
  }

  private options(): Record<string, string> {
    const values: Record<string, string> = {}
    if (this.accept('[')) {
      do {
        const key = this.name()
        this.expect('=')
        let value = ''
        while (this.peek() !== ',' && this.peek() !== ']') value += this.take()
        values[key] = value
      } while (this.accept(','))
      this.expect(']')
    }
    return values
  }

  private field(type: string, label?: Label, oneof?: string): Field {
    const name = this.name()
    this.expect('=')
    const number = this.number()
    const options = this.options()
    this.expect(';')
    return { name, type, number, label, oneof, options }
  }

  private message(parent: string[]): void {
    const name = [...parent, this.name()]
    const message = { kind: 'message' as const, name, file: this.file, fields: [] as Field[] }
    this.file.definitions.push(message)
    this.expect('{')
    while (!this.accept('}')) {
      if (this.accept(';')) continue
      switch (this.peek()) {
        case 'message':
          this.take()
          this.message(name)
          break
        case 'enum':
          this.take()
          this.enumeration(name)
          break
        case 'option':
        case 'reserved':
          this.statement()
          break
        case 'oneof': {
          this.take()
          const oneof = this.name()
          this.expect('{')
          message.fields.push(this.field(this.qualified(), 'optional', oneof))
          // Every oneof in 3.9.3 is a single-field presence wrapper.
          this.expect('}')
          break
        }
        case 'map': {
          this.take()
          this.expect('<')
          const key = this.qualified()
          this.expect(',')
          const value = this.qualified()
          this.expect('>')
          const field = this.field('', 'repeated')
          const entry = [...name, field.name.split('_').map(part => part[0]!.toUpperCase() + part.slice(1)).join('') + 'Entry']
          this.file.definitions.push({
            kind: 'message', file: this.file, name: entry, fields: [
              { name: 'key', number: 1, type: key, options: {}, map_entry_field: true },
              { name: 'value', number: 2, type: value, options: {}, map_entry_field: true },
            ],
          })
          field.type = '.' + [this.file.package, ...entry].join('.')
          message.fields.push(field)
          break
        }
        default: {
          const next = this.peek()
          const label = next === 'required' || next === 'optional' || next === 'repeated'
            ? this.take() as Label
            : undefined
          message.fields.push(this.field(this.qualified(), label))
        }
      }
    }
  }

  private enumeration(parent: string[]): void {
    const name = [...parent, this.name()]
    const values: EnumValue[] = []
    this.file.definitions.push({ kind: 'enum', file: this.file, name, values })
    this.expect('{')
    while (!this.accept('}')) {
      if (this.accept(';')) continue
      if (this.peek() === 'option' || this.peek() === 'reserved') {
        this.statement()
        continue
      }
      const label = this.name()
      this.expect('=')
      const number = this.number()
      values.push({ name: label, number, options: this.options() })
      this.expect(';')
    }
  }

  parse(): void {
    while (this.peek() !== undefined) {
      const token = this.take()
      switch (token) {
        case 'syntax':
          this.expect('=')
          this.file.syntax = JSON.parse(this.take()) as string
          this.expect(';')
          break
        case 'package':
          this.file.package = this.qualified()
          this.expect(';')
          break
        case 'option':
        case 'import':
          this.statement()
          break
        case 'message':
          this.message([])
          break
        case 'enum':
          this.enumeration([])
          break
        case ';':
          break
        default:
          this.fail('unexpected declaration ' + token)
      }
    }
    if (!['proto2', 'proto3'].includes(this.file.syntax) || !this.file.package)
      this.fail('unsupported file syntax or missing package')
  }
}

const upstream = join(checkout, 'proto', 'descriptors')
const names = readdirSync(upstream).filter(name => name.endsWith('.proto')).sort()
if (names.length !== 14) throw new Error('expected exactly 14 Valhalla .proto files')
const files = names.map(name => {
  const file: File = { name, syntax: '', package: '', definitions: [] }
  new Parser(file, tokenize(readFileSync(join(upstream, name), 'utf8'))).parse()
  return file
})
const fullName = (definition: Path) => [definition.file.package, ...definition.name].join('.')
const definitions = new Map<string, Definition>()
for (const file of files) {
  for (const item of file.definitions) {
    const name = fullName(item)
    if (definitions.has(name)) throw new Error('duplicate proto name ' + name)
    definitions.set(name, item)
  }
}

const scalars = new Set([
  'double', 'float', 'int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64',
  'fixed32', 'fixed64', 'sfixed32', 'sfixed64', 'bool', 'string', 'bytes',
])
const zigKeywords = new Set([
  'addrspace', 'align', 'allowzero', 'and', 'anyframe', 'anytype', 'asm', 'async', 'await',
  'break', 'callconv', 'catch', 'comptime', 'const', 'continue', 'defer', 'else', 'enum',
  'errdefer', 'error', 'export', 'extern', 'fn', 'for', 'if', 'inline', 'noalias', 'noinline',
  'nosuspend', 'opaque', 'or', 'orelse', 'packed', 'pub', 'resume', 'return', 'struct',
  'suspend', 'switch', 'test', 'threadlocal', 'try', 'union', 'unreachable', 'usingnamespace',
  'var', 'volatile', 'while', 'null', 'undefined', 'true', 'false',
])
const zigName = (name: string) => zigKeywords.has(name) ? '@' + JSON.stringify(name) : name
const zigSymbol = (definition: Path) => zigName(definition.name.join('_'))
const stem = (file: File) => file.name.slice(0, -'.proto'.length)

function resolve(owner: Path, name: string): Definition {
  const parts = fullName(owner).split('.')
  if (name.startsWith('.')) parts.length = 0
  while (true) {
    const key = [...parts, name.replace(/^\./, '')].join('.')
    const found = definitions.get(key)
    if (found) return found
    if (parts.length === 0) throw new Error('cannot resolve ' + name + ' in ' + fullName(owner))
    parts.pop()
  }
}

function defaultLiteral(kind: string, value: string, enumeration?: Definition & { kind: 'enum' }): string {
  if (enumeration) {
    const member = enumeration.values.find(candidate => candidate.name === value)
    if (!member) throw new Error('unknown enum default ' + value + ' in ' + fullName(enumeration))
    return '.{ .integer = ' + member.number + ' }'
  }
  switch (kind) {
    case 'string':
    case 'bytes': return '.{ .bytes = ' + value + ' }'
    case 'bool': return '.{ .boolean = ' + value + ' }'
    case 'float':
    case 'double': return '.{ .floating = ' + value + ' }'
    default: return '.{ .integer = ' + value + ' }'
  }
}

function render(file: File): string {
  const imports = new Set<string>()
  const symbols = new Set<string>()
  function reference(definition: Definition): string {
    if (definition.file === file) return zigSymbol(definition)
    const packageName = stem(definition.file)
    imports.add(packageName)
    return zigName(packageName) + '.' + zigSymbol(definition)
  }

  const declarations = file.definitions.map(definition => {
    const name = zigSymbol(definition)
    if (symbols.has(name)) throw new Error('duplicate Zig name ' + name + ' in ' + file.name)
    symbols.add(name)
    if (definition.kind === 'enum') {
      const lines = definition.values.map(value => '    ' + zigName(value.name) + ' = ' + value.number + ',' +
        (value.options.deprecated === 'true' ? ' // Deprecated.' : ''))
      return ['pub const ' + name + ' = enum(i32) {', ...lines, '    _,', '};'].join('\n')
    }
    const lines = definition.fields.map(field => {
      const type = scalars.has(field.type) ? undefined : resolve(definition, field.type)
      const kind = type?.kind === 'enum' ? 'enumeration' : (type?.kind === 'message' ? 'message' : field.type)
      if (!field.label && !field.map_entry_field && file.syntax === 'proto2')
        throw new Error('proto2 field lacks presence label in ' + fullName(definition) + '.' + field.name)
      const presence = field.label ?? (kind === 'message' ? 'optional' : 'implicit')
      const opts = ['.name = ' + JSON.stringify(field.name), '.number = ' + field.number, '.kind = .' + kind]
      if (presence !== 'implicit') opts.push('.presence = .' + presence)
      if (type?.kind === 'enum') opts.push('.enum_type = ' + reference(type))
      if (type?.kind === 'message') opts.push('.message = ' + reference(type))
      const packable = presence === 'repeated' && kind !== 'message' && kind !== 'string' && kind !== 'bytes'
      if (packable && (field.options.packed ?? (file.syntax === 'proto3' ? 'true' : 'false')) === 'true')
        opts.push('.packed_encoding = true')
      if (field.options.default !== undefined)
        opts.push('.default_value = ' + defaultLiteral(kind, field.options.default, type?.kind === 'enum' ? type : undefined))
      else if (type?.kind === 'enum' && presence === 'optional' && file.syntax === 'proto2' && type.values[0]!.number !== 0)
        opts.push('.default_value = ' + defaultLiteral(kind, type.values[0]!.name, type))
      if (field.map_entry_field && presence === 'implicit') opts.push('.encode_default = true')
      const comments = [field.oneof && 'oneof ' + field.oneof, field.options.deprecated === 'true' && 'Deprecated.'].filter(Boolean)
      return '    .{ ' + opts.join(', ') + ' },' + (comments.length ? ' // ' + comments.join(', ') : '')
    })
    if (lines.length === 0) return 'pub const ' + name + ' = proto.Message(&.{});'
    return ['pub const ' + name + ' = proto.Message(&.{', ...lines, '});'].join('\n')
  })
  const head = ['// Ported from proto/descriptors/' + file.name + ' (Valhalla 3.9.3).',
    '// Generated by tools/proto/valhalla.ts.']
  if (file.definitions.some(definition => definition.kind === 'message')) head.push('const proto = @import("protobuf");')
  for (const dependency of [...imports].sort())
    head.push('const ' + zigName(dependency) + ' = @import("' + dependency + '.zig");')
  return head.join('\n') + '\n\n' + declarations.join('\n\n') + '\n'
}

const output = join(import.meta.dir, '..', '..', 'src', 'api', 'proto')
if (mode === '--write') mkdirSync(output, { recursive: true })
let mismatches = 0
for (const file of files) {
  const path = join(output, stem(file) + '.zig')
  const expected = run([process.env.ZIG ?? 'zig', 'fmt', '--stdin'], render(file))
  if (mode === '--write') {
    writeFileSync(path, expected)
    continue
  }
  const actual = readFileSync(path, 'utf8')
  if (actual !== expected) {
    const left = actual.split('\n')
    const right = expected.split('\n')
    const at = right.findIndex((line, i) => line !== left[i])
    console.error(stem(file) + '.zig differs at line ' + (at + 1))
    if (at >= 0) console.error('  found: ' + (left[at] ?? '') + '\n  expected: ' + right[at])
    mismatches++
  }
}
const fieldCount = [...definitions.values()].reduce((count, item) => count + (item.kind === 'message' ? item.fields.length : 0), 0)
const enumCount = [...definitions.values()].reduce((count, item) => count + (item.kind === 'enum' ? item.values.length : 0), 0)
console.log(files.length + ' files, ' + fieldCount + ' fields, ' + enumCount + ' enum values, ' + mismatches + ' mismatched files')
if (mismatches > 0) process.exit(1)
