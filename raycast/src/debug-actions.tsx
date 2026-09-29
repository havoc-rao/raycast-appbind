import { Action } from "@raycast/api";
import { Config } from "./config";
import { Diagnostic } from "./debug-ui";

export function BindingDebugActions({ config, bindingId }: { config: Config; bindingId: string }) {
  return <Action.Push title="Diagnostic Dry-Run (No Click)" target={<Diagnostic request={{ protocolVersion: 1, command: "dry-run", config, bindingId }} />} />;
}
