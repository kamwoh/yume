// The dev server of the browser viewer (ADR 0095 phase 2). It needs no
// build step: it strips the types from each .ts file when it serves it.
//
//   node src/serve.ts [--port=8095] [--data=../../godot/data]
//   open http://localhost:8095/?game=demo_sokoban
//
// Routes:
//   /                   the viewer page
//   /src/<file>.ts      a source file, as JavaScript
//   /vendor/three.js    three.js from node_modules
//   /bundle/<game>      one JSON map of the game, lib/ and the shape and mesh libraries
//   /games              the game folders that have a scene.json
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle } from "./bundle.ts";
import { NodeFiles } from "./node_files.ts";

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, "..");
const args = process.argv.slice(2);
const opt = (name: string, dflt: string) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? dflt;
const port = Number(opt("port", "8095"));
const dataRoot = resolve(webRoot, opt("data", "../../godot/data"));
const files = new NodeFiles();

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  const send = (code: number, type: string, body: string | Buffer) => {
    res.writeHead(code, { "content-type": type, "cache-control": "no-store" });
    res.end(body);
  };
  try {
    if (url.pathname === "/") return send(200, "text/html", readFileSync(join(webRoot, "src/viewer/index.html")));
    if (url.pathname === "/vendor/three.js") {
      return send(200, "text/javascript", readFileSync(join(webRoot, "node_modules/three/build/three.module.js")));
    }
    if (url.pathname === "/games") {
      const games = files.list(dataRoot).filter((g) => files.exists(join(dataRoot, g, "scene.json")));
      return send(200, "application/json", JSON.stringify(games));
    }
    if (url.pathname.startsWith("/bundle/")) {
      const b = bundle(dataRoot, url.pathname.slice("/bundle/".length));
      return b ? send(200, "application/json", JSON.stringify(b)) : send(404, "text/plain", "no such game");
    }
    if (url.pathname.startsWith("/src/") && url.pathname.endsWith(".ts")) {
      const path = resolve(webRoot, `.${url.pathname}`);
      if (!path.startsWith(join(webRoot, "src"))) return send(403, "text/plain", "forbidden");
      return send(200, "text/javascript", stripTypeScriptTypes(readFileSync(path, "utf8")));
    }
    send(404, "text/plain", "not found");
  } catch (e) {
    send(500, "text/plain", String(e));
  }
});

server.listen(port, () => console.log(`Yume viewer: http://localhost:${port}/?game=demo_sokoban  (data: ${dataRoot})`));
