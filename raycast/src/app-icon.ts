import { spawnSync } from "node:child_process";

export interface ResolvedApp { name: string; path: string }

export type CommandRunner = (cmd: string, args: string[]) => { status: number | null; stdout: string };

function defaultRunner(cmd: string, args: string[]): { status: number | null; stdout: string } {
  return spawnSync(cmd, args, { encoding: "utf8", timeout: 3000 });
}

/** 按 bundle id 反查应用路径（用于显示 logo / fileIcon）。
 *
 * 刻意不使用 Raycast 的 getApplications()：枚举全量应用列表会污染
 * getFrontmostApplication() 共享的应用状态缓存（列表第一项会被当成默认前台值，
 * 表现为自动获取的 appid 错误）。这里的查询只针对单个 id：
 *  1) Spotlight：mdfind "kMDItemCFBundleIdentifier == '<id>'"
 *  2) 运行中的应用：lsappinfo list 中该 bundleID 块的 bundle path
 *  查不到时返回 undefined（不填图标即可，不影响流程）。 */
export async function resolveAppPath(bundleId: string, run: CommandRunner = defaultRunner): Promise<string | undefined> {
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(bundleId)) return undefined;
  try {
    const m = run("/usr/bin/mdfind", [`kMDItemCFBundleIdentifier == '${bundleId}'`]);
    if (m.status === 0) {
      const path = (m.stdout ?? "").split("\n").map(s => s.trim()).find(Boolean);
      if (path) return path;
    }
  } catch { /* fall through to lsappinfo */ }
  try {
    const l = run("/usr/bin/lsappinfo", ["list"]);
    if (l.status === 0) {
      const lines = (l.stdout ?? "").split("\n");
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].includes(`bundleID="${bundleId}"`)) {
          for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
            const m = lines[j].match(/^\s*bundle path="(.*)"\s*$/);
            if (m) return m[1];
          }
          return undefined;
        }
      }
    }
  } catch { /* nothing more to try */ }
  return undefined;
}

/** 从 .app 路径派生显示名（如 Safar 的 "Harness Dev.app" → "Harness Dev"）。 */
export function appNameFromPath(path: string, fallback: string): string {
  const base = path.split("/").pop() ?? "";
  const name = base.replace(/\.app$/, "");
  return name || fallback;
}