// A capture tool for the viewer (visual QA, ADR 0095 phase 2). It drives a
// headless Chromium over the DevTools protocol: it opens the game, waits
// until every asset has loaded, plays real key presses, and saves a PNG.
//
//   node src/capture.ts --game=demo_sokoban --out=shot.png
//     [--keys=D:0.3,wait:1,R:0.1]   spec key names (ADR 0090) held for N seconds, or wait:N.
//                                   K:down keeps key K down through the capture (a walk pose).
//     [--size=960x540] [--server=http://localhost:8095] [--timeout=120] [--verbose]
//     [--browser=<path>]            default: $YUME_CHROME, else a Playwright headless shell
//     [--eval=<expr>]               print a page expression after the keys, e.g. a player position
//
// The dev server (src/serve.ts) must be running.
import { spawn } from "node:child_process";
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { codesOf } from "./viewer/keys.ts";

const args = process.argv.slice(2);
const opt = (name: string, dflt: string) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? dflt;
const game = opt("game", "demo_sokoban");
const out = opt("out", `${game}.png`);
const [width, height] = opt("size", "960x540").split("x").map(Number);
const server = opt("server", "http://localhost:8095");
const timeoutS = Number(opt("timeout", "120"));
const keys = opt("keys", "");
const evalExpr = opt("eval", "");
// A port of its own, so a browser left by a killed run cannot answer.
const port = 9300 + Math.floor(Math.random() * 600);
const verbose = args.includes("--verbose");

function findBrowser(): string {
  const given = opt("browser", process.env.YUME_CHROME ?? "");
  if (given !== "") return given;
  const root = join(homedir(), ".cache/ms-playwright");
  if (existsSync(root)) {
    for (const d of readdirSync(root).filter((x) => x.startsWith("chromium_headless_shell-")).sort().reverse()) {
      const p = join(root, d, "chrome-headless-shell-linux64/chrome-headless-shell");
      if (existsSync(p)) return p;
    }
  }
  throw new Error("no browser: pass --browser=<path> or set YUME_CHROME");
}

/** The DOM key, the typed text and the Windows virtual key code of a spec key name. */
function keyInfo(name: string): { key: string; text: string | undefined; vk: number } {
  const named: Record<string, [string, string | undefined, number]> = {
    Enter: ["Enter", "\r", 13], Space: [" ", " ", 32], Escape: ["Escape", undefined, 27], Tab: ["Tab", undefined, 9],
    Up: ["ArrowUp", undefined, 38], Down: ["ArrowDown", undefined, 40], Left: ["ArrowLeft", undefined, 37], Right: ["ArrowRight", undefined, 39],
    Shift: ["Shift", undefined, 16], Backspace: ["Backspace", undefined, 8],
  };
  if (name in named) {
    const [key, text, vk] = named[name];
    return { key, text, vk };
  }
  if (/^[A-Z]$/.test(name)) return { key: name.toLowerCase(), text: name.toLowerCase(), vk: name.charCodeAt(0) };
  if (/^[0-9]$/.test(name)) return { key: name, text: name, vk: name.charCodeAt(0) };
  return { key: name, text: undefined, vk: 0 };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

class Cdp {
  private ws: WebSocket;
  private seq = 0;
  private waiting = new Map<number, (v: unknown) => void>();
  constructor(ws: WebSocket) {
    this.ws = ws;
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(String(ev.data));
      if (verbose && msg.method === "Runtime.consoleAPICalled") {
        console.log(`[page] ${msg.params.args.map((a: { value?: unknown; description?: string }) => a.value ?? a.description).join(" ")}`);
      }
      if (msg.method === "Runtime.exceptionThrown") console.log(`[page error] ${msg.params.exceptionDetails?.exception?.description ?? msg.params.exceptionDetails?.text}`);
      if (msg.method === "Inspector.targetCrashed") console.log("[page] crashed");
      if (msg.id && this.waiting.has(msg.id)) {
        this.waiting.get(msg.id)!(msg.error ? Promise.reject(new Error(msg.error.message)) : msg.result);
        this.waiting.delete(msg.id);
      }
    });
  }
  send(method: string, params: object = {}, timeoutMs = 30_000): Promise<Record<string, unknown>> {
    const id = ++this.seq;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((r, j) => {
      // A busy or crashed page never answers. Fail instead of waiting forever.
      // An answer clears the timer, so that no timer keeps Node alive after the capture.
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        j(new Error(`${method}: no answer in ${timeoutMs / 1000} s`));
      }, timeoutMs);
      this.waiting.set(id, (v: unknown) => {
        clearTimeout(timer);
        r(v as Record<string, unknown>);
      });
    });
  }
  async eval(expr: string): Promise<unknown> {
    const r = (await this.send("Runtime.evaluate", { expression: expr, returnByValue: true })) as { result?: { value?: unknown } };
    return r.result?.value;
  }
}

async function main(): Promise<void> {
  const browser = spawn(
    findBrowser(),
    ["--no-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", `--window-size=${width},${height}`, `--remote-debugging-port=${port}`, "about:blank"],
    { stdio: "ignore" },
  );
  // A killed run must not leave its browser behind.
  for (const sig of ["SIGTERM", "SIGINT"] as const) {
    process.on(sig, () => {
      browser.kill("SIGKILL");
      process.exit(1);
    });
  }
  try {
    let wsUrl = "";
    for (let i = 0; i < 50 && wsUrl === ""; i++) {
      await sleep(200);
      try {
        const list = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()) as { type: string; webSocketDebuggerUrl: string }[];
        wsUrl = list.find((t) => t.type === "page")?.webSocketDebuggerUrl ?? "";
      } catch {
        // The browser is still starting.
      }
    }
    if (wsUrl === "") throw new Error("the browser gave no page");
    const ws = new WebSocket(wsUrl);
    await new Promise((r, j) => {
      ws.addEventListener("open", r);
      ws.addEventListener("error", j);
      setTimeout(() => j(new Error("the page socket did not open in 10 s")), 10_000);
    });
    const cdp = new Cdp(ws);
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Inspector.enable");
    await cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
    await cdp.send("Page.navigate", { url: `${server}/?game=${encodeURIComponent(game)}` });
    const deadline = Date.now() + timeoutS * 1000;
    const t0 = Date.now();
    let lastLog = 0;
    // Parsing a large GLB blocks the page for a while. A missed answer is not a failure.
    const assetsLoaded = () => cdp.eval("document.body && document.body.dataset.assets").catch(() => "busy");
    while ((await assetsLoaded()) !== "loaded") {
      if (Date.now() > deadline) throw new Error(`assets did not load in ${timeoutS} s`);
      if (verbose && Date.now() - lastLog > 5000) {
        lastLog = Date.now();
        console.log(`[capture] ${Math.round((Date.now() - t0) / 1000)} s: still loading`);
      }
      await sleep(250);
    }
    if (verbose) console.log(`[capture] loaded after ${Math.round((Date.now() - t0) / 1000)} s`);
    for (const step of keys.split(",").filter((s) => s !== "")) {
      const [name, secs] = step.split(":");
      const ms = secs === "down" ? 0 : Number(secs ?? "0.1") * 1000;
      if (name === "wait") {
        await sleep(ms);
        continue;
      }
      const code = codesOf(name)[0];
      if (!code) throw new Error(`'${name}' is not a spec key name`);
      // A key with text and a virtual key code acts as a real key: Enter and Space press a focused button.
      const k = keyInfo(name);
      await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", code, key: k.key, text: k.text, windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk });
      if (secs === "down") continue;
      await sleep(ms);
      await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", code, key: k.key, windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk });
    }
    // Let a few frames draw the last state.
    await sleep(500);
    if (evalExpr !== "") console.log(`eval: ${JSON.stringify(await cdp.eval(evalExpr))}`);
    // A large scene on the CPU renderer (SwiftShader) can take many seconds per frame.
    const shot = (await cdp.send("Page.captureScreenshot", { format: "png" }, timeoutS * 1000)) as { data: string };
    writeFileSync(out, Buffer.from(shot.data, "base64"));
    console.log(`captured: ${out}`);
    ws.close();
  } finally {
    browser.kill();
  }
}

main().then(
  () => process.exit(0),
  (e) => {
    console.error(String(e));
    process.exit(1);
  },
);
