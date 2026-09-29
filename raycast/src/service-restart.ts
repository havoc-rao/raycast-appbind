import { ServiceCommand, ServiceState } from "./service-transport";

export async function restartService(call: (command: ServiceCommand) => Promise<ServiceState>): Promise<ServiceState> {
  const stopped = await call("stop");
  if (stopped.running || stopped.executionEnabled) throw new Error("服务未停止，已取消重启。");
  const started = await call("start");
  if (!started.running) throw new Error(started.lastError ?? "旧服务已停止，但新服务未启动。");
  return started;
}
