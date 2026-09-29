import { test } from "node:test";
import assert from "node:assert/strict";
import { restartService } from "../src/service-restart";
import { ServiceState } from "../src/service-transport";
const stopped: ServiceState = { running: false, executionEnabled: false, accessibilityTrusted: true, inputMonitoringTrusted: true, enabledBindings: 0, configDigest: null, lastError: null, pid: null };
const running = { ...stopped, running: true, pid: 123 };
test("restart stops before starting and returns new state", async () => {
  const commands: string[] = [];
  assert.equal(await restartService(async command => { commands.push(command); return command === "stop" ? stopped : running; }), running);
  assert.deepEqual(commands, ["stop", "start"]);
});
test("restart never starts after failed or incomplete stop", async () => {
  const commands: string[] = [];
  await assert.rejects(restartService(async command => { commands.push(command); throw new Error("stop failed"); }));
  assert.deepEqual(commands, ["stop"]);
  commands.length = 0;
  await assert.rejects(restartService(async command => { commands.push(command); return running; }));
  assert.deepEqual(commands, ["stop"]);
});
test("restart surfaces startup failure without pretending success", async () => {
  await assert.rejects(restartService(async () => stopped), /新服务未启动/);
});
