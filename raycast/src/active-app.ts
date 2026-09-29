export interface ActiveApplication { name: string; bundleId: string }

/** Resolve configuration identity only; never a token authorizing window operations. */
export async function resolveActiveApplication(query: () => Promise<{ name?: string; bundleId?: string }>): Promise<ActiveApplication> {
  const app = await query();
  const id = app?.bundleId;
  if (app?.name?.toLowerCase() === "raycast" || id?.toLowerCase() === "com.raycast" || id?.toLowerCase().startsWith("com.raycast.")) {
    throw new Error("当前目标是 Raycast。请先激活目标应用窗口，再重新打开 Create Binding。");
  }
  if (typeof id !== "string" || id.length > 255 || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$(?![\s\S])/.test(id)) {
    throw new Error("无法从当前激活应用取得有效 Bundle ID；请切换目标窗口后重试，或手动填写。");
  }
  return { bundleId: id, name: app.name || id };
}
