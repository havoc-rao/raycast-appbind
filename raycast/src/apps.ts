import { getApplications } from "@raycast/api";

export interface AppInfo { name: string; path: string; bundleId: string }

/** Every installed app with a bundle id, sorted by display name. Duplicate bundle ids (the same app
 *  installed in several locations) are collapsed to one entry, preferring the /Applications copy. */
export async function installedApps(): Promise<AppInfo[]> {
  const list = await getApplications();
  const seen = new Map<string, AppInfo>();
  for (const app of list) {
    if (typeof app.bundleId !== "string" || !app.bundleId) continue;
    const info: AppInfo = { name: app.name, path: app.path, bundleId: app.bundleId };
    const existing = seen.get(info.bundleId);
    if (!existing) seen.set(info.bundleId, info);
    else if (!existing.path.startsWith("/Applications/") && info.path.startsWith("/Applications/")) seen.set(info.bundleId, info);
  }
  const installed = [...seen.values()];
  installed.sort((a, b) => a.name.localeCompare(b.name));
  return installed;
}