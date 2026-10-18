// The formula language (ADR 0088). Mirrors formula.gd: bindings are
// replaced by placeholders, the token check rejects anything outside the
// language, and the rest evaluates with the reference semantics:
//   - every number is a float,
//   - arithmetic on a boolean is an error, and an error gives 0.0,
//   - `and`, `or` and `not` take truthiness and evaluate both operands
//     (no short circuit), so a randf() call always rolls,
//   - == between two different types is false, < between them is an error.
import { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { SpecRandom } from "./random.ts";
import { type Value, Vec2, Vec3, equals, isDict, lessThan } from "./value.ts";

export const FUNCTIONS = [
  "abs", "floor", "ceil", "round", "min", "max", "clamp", "lerp",
  "sqrt", "pow", "sin", "cos", "tan", "atan2", "randf", "float",
];
const KEYWORDS = ["and", "or", "not", "true", "false"];

export type FormulaContext = { [root: string]: unknown };

class FormulaError extends Error {}

const TOKEN_RX = /\s+|(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?|[A-Za-z_]\w*|\*\*|==|!=|<=|>=|[-+*/()[\],<>]/y;

type Node =
  | { k: "num"; v: number }
  | { k: "bool"; v: boolean }
  | { k: "var"; i: number }
  | { k: "un"; op: string; a: Node }
  | { k: "bin"; op: string; a: Node; b: Node }
  | { k: "call"; f: string; args: Node[] }
  | { k: "idx"; a: Node; i: Node };

const cache = new Map<string, Node>();

export function evaluate(formula: unknown, context: FormulaContext, env: Env | null = null): unknown {
  if (typeof formula !== "string") return formula;
  if (formula === "") return 0;
  let rewritten = formula;
  const names: string[] = [];
  const values: unknown[] = [];
  const roots = Object.keys(context).sort((a, b) => b.length - a.length);
  for (const root of roots) {
    if (!rewritten.includes(root)) continue;
    const rx = new RegExp("\\b" + escapeRx(root) + "(\\.[A-Za-z_][A-Za-z0-9_]*)+", "g");
    const found = [...rewritten.matchAll(rx)];
    for (let i = found.length - 1; i >= 0; i--) {
      const m = found[i];
      const path = m[0].slice(root.length + 1);
      const ph = `__v${names.length}`;
      names.push(ph);
      values.push(resolvePath(context[root], path));
      rewritten = rewritten.slice(0, m.index!) + ph + rewritten.slice(m.index! + m[0].length);
    }
  }
  const key = rewritten + "|" + names.join(",");
  let ast = cache.get(key);
  if (!ast) {
    const checked = checkLanguage(rewritten, names);
    if (typeof checked === "string") {
      if (env) raise(env, checked.split("|")[0], `Formula '${formula}': ${checked.split("|")[1]}`);
      return 0;
    }
    try {
      ast = new Parser(checked, names).parseAll();
    } catch (e) {
      if (env) raise(env, "formula.parse_failed", `Formula parse error: '${formula}' — ${(e as Error).message}`);
      return 0;
    }
    cache.set(key, ast);
  }
  try {
    return evalNode(ast, values);
  } catch (e) {
    if (e instanceof FormulaError) {
      if (env) raise(env, "formula.exec_failed", `Formula exec failed: '${formula}' — ${e.message}`);
      return 0;
    }
    throw e;
  }
}

/** Mirrors Formula.looks_like_formula: a lower-case start and an operator or dot. */
export function looksLikeFormula(s: string): boolean {
  if (s === "") return false;
  if (!/^[a-z0-9(\-+_@]/.test(s)) return false;
  return [" ", "+", "-", "*", "/", "(", ")", "."].some((c) => s.includes(c));
}

export function resolvePath(root: unknown, path: string): unknown {
  let cur: unknown = root;
  for (const p of path.split(".")) {
    if (p === "") continue;
    if (cur instanceof Entity) {
      if (p === "state") cur = cur.state;
      else if (p === "tags") cur = cur.tags;
      else if (p === "properties") cur = cur.properties;
      else if (p === "id") cur = cur.id;
      else if (p === "def_id") cur = cur.defId;
      else return 0;
      continue;
    }
    if (cur instanceof Vec2) {
      if (p === "x") cur = cur.x;
      else if (p === "y") cur = cur.y;
      else return 0;
      continue;
    }
    if (cur instanceof Vec3) {
      if (p === "x") cur = cur.x;
      else if (p === "y") cur = cur.y;
      else if (p === "z") cur = cur.z;
      else return 0;
      continue;
    }
    if (isDict(cur)) {
      if (!(p in cur)) return 0;
      cur = cur[p];
      continue;
    }
    return 0;
  }
  return cur;
}

/** Port of Formula._check_language. Returns the token list, or "code|message". */
function checkLanguage(src: string, inputs: string[]): string[] | string {
  const tokens: string[] = [];
  const isNumTok: boolean[] = [];
  let pos = 0;
  while (pos < src.length) {
    TOKEN_RX.lastIndex = pos;
    const m = TOKEN_RX.exec(src);
    if (!m || m.index !== pos) return `formula.parse_failed|'${src[pos]}' is not in the formula language.`;
    if (m[0].trim() !== "") {
      tokens.push(m[0]);
      isNumTok.push(m[1] !== undefined);
    }
    pos = TOKEN_RX.lastIndex;
  }
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    const next = tokens[i + 1] ?? "";
    const prev = tokens[i - 1] ?? "";
    if (tok === "**") return "formula.parse_failed|'**' is not in the formula language.";
    if (/^[A-Za-z_]/.test(tok)) {
      if (tok === "if" || tok === "else") return "formula.parse_failed|The formula language has no ternary.";
      if (next === "(" && inputs.includes(tok)) return "formula.parse_failed|A method call is not in the formula language.";
      if (next === "(" && !KEYWORDS.includes(tok)) {
        if (!FUNCTIONS.includes(tok)) return `formula.unknown_function|'${tok}' is not a formula function.`;
      } else if (!(inputs.includes(tok) || KEYWORDS.includes(tok))) {
        return `formula.parse_failed|'${tok}' is not a binding the rule provides.`;
      }
    } else if (tok === "[" && !(prev === "]" || prev === ")" || inputs.includes(prev))) {
      return "formula.parse_failed|An array literal is not in the formula language.";
    }
    void isNumTok;
  }
  return tokens;
}

class Parser {
  private i = 0;
  private toks: string[];
  private names: string[];
  constructor(toks: string[], names: string[]) {
    this.toks = toks;
    this.names = names;
  }
  private peek(): string {
    return this.toks[this.i] ?? "";
  }
  private eat(t: string): void {
    if (this.peek() !== t) throw new Error(`expected '${t}', got '${this.peek()}'`);
    this.i++;
  }
  parseAll(): Node {
    const n = this.or();
    if (this.i !== this.toks.length) throw new Error(`unexpected '${this.peek()}'`);
    return n;
  }
  private or(): Node {
    let a = this.and();
    while (this.peek() === "or") {
      this.i++;
      a = { k: "bin", op: "or", a, b: this.and() };
    }
    return a;
  }
  private and(): Node {
    let a = this.not();
    while (this.peek() === "and") {
      this.i++;
      a = { k: "bin", op: "and", a, b: this.not() };
    }
    return a;
  }
  private not(): Node {
    if (this.peek() === "not") {
      this.i++;
      return { k: "un", op: "not", a: this.not() };
    }
    return this.compare();
  }
  private compare(): Node {
    let a = this.sum();
    while (["==", "!=", "<", "<=", ">", ">="].includes(this.peek())) {
      const op = this.toks[this.i++];
      a = { k: "bin", op, a, b: this.sum() };
    }
    return a;
  }
  private sum(): Node {
    let a = this.product();
    while (this.peek() === "+" || this.peek() === "-") {
      const op = this.toks[this.i++];
      a = { k: "bin", op, a, b: this.product() };
    }
    return a;
  }
  private product(): Node {
    let a = this.unary();
    while (this.peek() === "*" || this.peek() === "/") {
      const op = this.toks[this.i++];
      a = { k: "bin", op, a, b: this.unary() };
    }
    return a;
  }
  private unary(): Node {
    if (this.peek() === "-" || this.peek() === "+") {
      const op = this.toks[this.i++];
      return { k: "un", op, a: this.unary() };
    }
    return this.postfix();
  }
  private postfix(): Node {
    let a = this.atom();
    while (this.peek() === "[") {
      this.i++;
      const idx = this.or();
      this.eat("]");
      a = { k: "idx", a, i: idx };
    }
    return a;
  }
  private atom(): Node {
    const t = this.peek();
    if (t === "") throw new Error("unexpected end");
    if (t === "(") {
      this.i++;
      const n = this.or();
      this.eat(")");
      return n;
    }
    if (/^(\d|\.\d)/.test(t)) {
      this.i++;
      return { k: "num", v: parseFloat(t) };
    }
    if (t === "true" || t === "false") {
      this.i++;
      return { k: "bool", v: t === "true" };
    }
    if (FUNCTIONS.includes(t) && this.toks[this.i + 1] === "(") {
      this.i += 2;
      const args: Node[] = [];
      if (this.peek() !== ")") {
        args.push(this.or());
        while (this.peek() === ",") {
          this.i++;
          args.push(this.or());
        }
      }
      this.eat(")");
      return { k: "call", f: t, args };
    }
    const vi = this.names.indexOf(t);
    if (vi >= 0) {
      this.i++;
      return { k: "var", i: vi };
    }
    throw new Error(`unexpected '${t}'`);
  }
}

function truthy(v: unknown): boolean {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0;
  if (typeof v === "string") return v !== "";
  if (v === null || v === undefined) return false;
  if (Array.isArray(v)) return v.length > 0;
  if (v instanceof Vec2) return v.x !== 0 || v.y !== 0;
  if (v instanceof Vec3) return v.x !== 0 || v.y !== 0 || v.z !== 0;
  if (isDict(v)) return Object.keys(v).length > 0;
  return true;
}

function num(v: unknown, what: string): number {
  if (typeof v === "number") return v;
  throw new FormulaError(`${what} needs a number`);
}

function arith(op: string, a: unknown, b: unknown): unknown {
  if (typeof a === "number" && typeof b === "number") {
    if (op === "+") return a + b;
    if (op === "-") return a - b;
    if (op === "*") return a * b;
    return a / b;
  }
  if (op === "+" && typeof a === "string" && typeof b === "string") return a + b;
  if (a instanceof Vec2 && b instanceof Vec2 && (op === "+" || op === "-")) {
    return op === "+" ? new Vec2(a.x + b.x, a.y + b.y) : new Vec2(a.x - b.x, a.y - b.y);
  }
  if (a instanceof Vec3 && b instanceof Vec3 && (op === "+" || op === "-")) {
    const s = op === "+" ? 1 : -1;
    return new Vec3(a.x + s * b.x, a.y + s * b.y, a.z + s * b.z);
  }
  if ((a instanceof Vec2 || a instanceof Vec3) && typeof b === "number" && (op === "*" || op === "/")) {
    const f = op === "*" ? b : 1 / b;
    return a instanceof Vec2 ? new Vec2(a.x * f, a.y * f) : new Vec3(a.x * f, a.y * f, a.z * f);
  }
  throw new FormulaError(`invalid operands for '${op}'`);
}

function evalNode(n: Node, vals: unknown[]): unknown {
  switch (n.k) {
    case "num":
      return n.v;
    case "bool":
      return n.v;
    case "var":
      return vals[n.i];
    case "un": {
      const a = evalNode(n.a, vals);
      if (n.op === "not") return !truthy(a);
      if (n.op === "-") {
        if (typeof a === "number") return -a;
        if (a instanceof Vec2) return new Vec2(-a.x, -a.y);
        if (a instanceof Vec3) return new Vec3(-a.x, -a.y, -a.z);
        throw new FormulaError("invalid operand for unary '-'");
      }
      if (typeof a === "number" || a instanceof Vec2 || a instanceof Vec3) return a;
      throw new FormulaError("invalid operand for unary '+'");
    }
    case "bin": {
      // Both operands always evaluate: the reference has no short circuit.
      const a = evalNode(n.a, vals);
      const b = evalNode(n.b, vals);
      switch (n.op) {
        case "and":
          return truthy(a) && truthy(b);
        case "or":
          return truthy(a) || truthy(b);
        case "==":
          return equals(a, b);
        case "!=":
          return !equals(a, b);
        case "<":
        case ">":
        case "<=":
        case ">=": {
          const lt = n.op === "<" || n.op === ">=" ? lessThan(a, b) : lessThan(b, a);
          if (lt === null) throw new FormulaError(`invalid operands for '${n.op}'`);
          return n.op === "<" || n.op === ">" ? lt : !lt;
        }
        default:
          return arith(n.op, a, b);
      }
    }
    case "idx": {
      const a = evalNode(n.a, vals);
      const iv = evalNode(n.i, vals);
      if (Array.isArray(a)) {
        let i = Math.trunc(num(iv, "an index"));
        if (i < 0) i += a.length;
        if (i < 0 || i >= a.length) throw new FormulaError("index out of range");
        return a[i];
      }
      if (a instanceof Vec2 || a instanceof Vec3) {
        const i = Math.trunc(num(iv, "an index"));
        const parts = a instanceof Vec2 ? [a.x, a.y] : [a.x, a.y, a.z];
        if (i < 0 || i >= parts.length) throw new FormulaError("index out of range");
        return parts[i];
      }
      if (isDict(a) && typeof iv === "string" && iv in a) return a[iv];
      throw new FormulaError("value is not indexable");
    }
    case "call":
      return call(n.f, n.args.map((x) => evalNode(x, vals)));
  }
}

function call(f: string, a: unknown[]): unknown {
  const need = (k: number) => {
    if (a.length !== k) throw new FormulaError(`${f}() takes ${k} arguments`);
  };
  switch (f) {
    case "abs":
      need(1);
      return Math.abs(num(a[0], f));
    case "floor":
      need(1);
      return Math.floor(num(a[0], f));
    case "ceil":
      need(1);
      return Math.ceil(num(a[0], f));
    case "round": {
      need(1);
      const x = num(a[0], f);
      return Math.sign(x) * Math.floor(Math.abs(x) + 0.5);
    }
    case "min":
      need(2);
      return Math.min(num(a[0], f), num(a[1], f));
    case "max":
      need(2);
      return Math.max(num(a[0], f), num(a[1], f));
    case "clamp": {
      need(3);
      const x = num(a[0], f);
      const lo = num(a[1], f);
      const hi = num(a[2], f);
      return x < lo ? lo : x > hi ? hi : x;
    }
    case "lerp": {
      need(3);
      const x = num(a[0], f);
      return x + (num(a[1], f) - x) * num(a[2], f);
    }
    case "sqrt":
      need(1);
      return Math.sqrt(num(a[0], f));
    case "pow":
      need(2);
      return Math.pow(num(a[0], f), num(a[1], f));
    case "sin":
      need(1);
      return Math.sin(num(a[0], f));
    case "cos":
      need(1);
      return Math.cos(num(a[0], f));
    case "tan":
      need(1);
      return Math.tan(num(a[0], f));
    case "atan2":
      need(2);
      return Math.atan2(num(a[0], f), num(a[1], f));
    case "randf":
      need(0);
      return SpecRandom.shared.randf();
    case "float": {
      need(1);
      const v = a[0];
      if (typeof v === "boolean") return v ? 1 : 0;
      if (typeof v === "number") return v;
      if (typeof v === "string") {
        const p = parseFloat(v);
        return Number.isNaN(p) ? 0 : p;
      }
      throw new FormulaError("float() needs a number, a boolean or a string");
    }
  }
  throw new FormulaError(`unknown function ${f}`);
}

function escapeRx(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export type { Value };
