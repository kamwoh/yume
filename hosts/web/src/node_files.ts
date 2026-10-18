// Files on disk, for the CLI, the tests and the dev server.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import type { Files } from "./files.ts";

export class NodeFiles implements Files {
  exists(path: string): boolean {
    return existsSync(path);
  }
  isDir(path: string): boolean {
    return existsSync(path) && statSync(path).isDirectory();
  }
  read(path: string): string | null {
    return existsSync(path) && !statSync(path).isDirectory() ? readFileSync(path, "utf8") : null;
  }
  list(dir: string): string[] {
    return existsSync(dir) ? readdirSync(dir).sort() : [];
  }
}
