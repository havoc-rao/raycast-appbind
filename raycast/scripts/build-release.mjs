import { cp, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
// Stage in a separate directory: never rewrite the live development manifest/source.
await mkdir(join(root, ".release-build"), { recursive: true });
const stage = await mkdtemp(join(root, ".release-build/stage-"));
const excluded = new Set(["shortcut-probe.tsx", "shortcut-probe-model.ts", "helper-status.tsx", "debug-ui.tsx", "debug-actions.tsx", "debug-log.ts"]);
try {
  await mkdir(join(stage, "src"));
  for (const file of await readdir(join(root, "src"))) {
    if (!excluded.has(file)) await cp(join(root, "src", file), join(stage, "src", file), { recursive: true });
  }
  // Compile-time substitutes, not runtime hidden actions; debug implementations
  // and logging file IO never enter the staged production dependency graph.
  await writeFile(join(stage, "src/debug-actions.tsx"), 'import type { Config } from "./config";\nexport function BindingDebugActions(_props: { config: Config; bindingId: string }) { return null; }\n');
  await writeFile(join(stage, "src/debug-log.ts"), 'export async function logDebug(_area: string, _message: string): Promise<void> {}\n');
  const manifest = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
  manifest.commands = manifest.commands.filter(command => !["shortcut-probe", "helper-status"].includes(command.name));
  manifest.description = "Manage app-aware bindings and an explicitly started background execution service.";
  manifest.commands.find(c => c.name === "manage-bindings").description = "Create, edit, enable and delete app-aware bindings";
  await writeFile(join(stage, "package.json"), JSON.stringify(manifest, null, 2) + "\n");
  for (const file of ["tsconfig.json", "raycast-env.d.ts", "README.md", "assets"]) {
    await cp(join(root, file), join(stage, file), { recursive: true });
  }
  await symlink(join(root, "node_modules"), join(stage, "node_modules"), "dir");
  const result = spawnSync(join(root, "node_modules/.bin/ray"), ["build", "-e", "dist", "-o", "dist"], { cwd: stage, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Release build failed: ${result.status}`);
  const output = join(stage, "dist");
  async function check(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { await check(path); continue; }
      if (/shortcut-probe|helper-status/.test(entry.name)) throw new Error(`Debug entry leaked into release: ${entry.name}`);
      if (/\.(js|json|map)$/.test(entry.name)) {
        const text = await readFile(path, "utf8");
        for (const marker of ["Diagnostic Dry-Run (No Click)", "Refresh Diagnostic", "Test Native Shortcut Recording", "appbind.log", "查看完整调试日志"]) {
          if (text.includes(marker)) throw new Error(`Debug code leaked into release: ${marker}`);
        }
      }
    }
  }
  await check(output);
  // Replace only dedicated generated release output after successful build/check.
  await rm(join(root, "dist-release"), { recursive: true, force: true });
  await cp(output, join(root, "dist-release"), { recursive: true });
  console.log("Release verified: manage-bindings, create-binding, background-service only; debug entry points and UI/log implementations excluded.");
  if (process.argv.includes("--install")) {
    // With no output override, the Raycast CLI targets its local extension directory.
    const install = spawnSync(join(root, "node_modules/.bin/ray"), ["build", "-e", "dist"], { cwd: stage, stdio: "inherit" });
    if (install.error) throw install.error;
    if (install.status !== 0) throw new Error(`Local installation failed: ${install.status}`);
    // ray build writes bundles but does not notify the app to re-register commands.
    // Use the pinned CLI's build-success URL protocol, without its start handler
    // (which kills a pid-file process and starts development bookkeeping).
    const refreshURL = `raycast://cli/${encodeURIComponent(manifest.name)}/build-success?cwd=${encodeURIComponent(join(root, "dist-release"))}&info=`;
    const refresh = spawnSync("/usr/bin/open", ["-g", refreshURL], { stdio: "inherit" });
    if (refresh.error) throw refresh.error;
    if (refresh.status !== 0) throw new Error("Release files installed, but Raycast registration notification failed.");
    console.log("Release files installed; command re-registration requested from Raycast. Verify the three commands in Raycast. Stop any ray develop watcher to prevent overwrite.");
  }
} finally {
  await rm(stage, { recursive: true, force: true });
}
