import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { Config, MAX_BYTES, emptyConfig, parseConfig, validateConfig } from "./config";
const missing = (e: unknown) => (e as NodeJS.ErrnoException).code === "ENOENT";
export class ConfigStore {
  readonly file: string; readonly lock: string;
  constructor(readonly directory: string) { this.file = path.join(directory, "config.json"); this.lock = path.join(directory, "config.lock"); }
  private async prepare() {
    await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
    const stat = await fs.lstat(this.directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("Config directory must not be a symlink");
    await fs.chmod(this.directory, 0o700);
  }
  async read(): Promise<Config> {
    let handle;
    try { handle = await fs.open(this.file, constants.O_RDONLY | constants.O_NOFOLLOW); }
    catch (e) { if (missing(e)) return emptyConfig(); throw e; }
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.size > MAX_BYTES) throw new Error("Invalid config file type or size");
      // Bound the read even if another process grows the file after stat.
      const bytes = Buffer.alloc(MAX_BYTES + 1);
      let length = 0;
      while (length < bytes.length) { const r = await handle.read(bytes, length, bytes.length - length, null); if (!r.bytesRead) break; length += r.bytesRead; }
      return parseConfig(bytes.subarray(0, length));
    } finally { await handle.close(); }
  }
  async update(mutate: (current: Config) => Config): Promise<Config> {
    await this.prepare();
    let lockHandle;
    try { lockHandle = await fs.open(this.lock, "wx", 0o600); }
    catch (e) {
      if ((e as NodeJS.ErrnoException).code === "EEXIST") throw new Error("Config busy: exclusive lock exists. A stale lock must only be removed manually after verifying no writer is active.");
      throw e;
    }
    const temp = path.join(this.directory, `.config-${randomUUID()}.tmp`);
    let created = false;
    try {
      await lockHandle.writeFile(JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString() }));
      await lockHandle.sync();
      const next = validateConfig(mutate(await this.read()));
      const text = JSON.stringify(next, null, 2) + "\n";
      if (Buffer.byteLength(text) > MAX_BYTES) throw new Error("Serialized config exceeds 1 MiB");
      const out = await fs.open(temp, "wx", 0o600); created = true;
      try { await out.chmod(0o600); await out.writeFile(text, "utf8"); await out.sync(); } finally { await out.close(); }
      await fs.rename(temp, this.file); created = false;
      const dir = await fs.open(this.directory, "r");
      try { await dir.sync(); } finally { await dir.close(); }
      return next;
    } finally {
      try { if (created) await fs.unlink(temp); }
      finally { await lockHandle.close(); await fs.unlink(this.lock); }
    }
  }
}
