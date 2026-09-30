# AppBind diagnostic helper

Swift package with a pure `AppBindCore` library and one-request `appbind-helper` executable. Requires macOS 13+; verified locally with Apple Swift 6.4 on arm64 macOS. No external dependencies.

## Build and test

From this directory:

```sh
mkdir -p .cache/clang .cache/swiftpm
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang"
swift build --disable-sandbox --cache-path "$PWD/.cache/swiftpm"
swift test --disable-sandbox --cache-path "$PWD/.cache/swiftpm"
printf '%s\n' '{"protocolVersion":1,"command":"status"}' | .build/debug/appbind-helper
```

`--disable-sandbox` avoids nested SwiftPM manifest sandboxing in restricted development environments; it does not grant helper execution capabilities. SwiftPM may warn that user-level configuration/security caches are inaccessible. Module and package caches above remain local. Build first to ensure CLI tests can locate the executable; they explicitly skip if unavailable.

## Scope and safety

See the workspace contract for the exact JSON schemas. Input is UTF-8 stdin, EOF-terminated, limited to 1MiB; stdout is one JSON response line. Success exits 0, request/application failure exits 1. Errors do not echo configuration, titles, or window contents.

- `status`: version, Accessibility trust status (without prompting), execution disabled.
- `inspect`: frontmost bundle ID and PID plus focused AX window frame, diagnostic only. Rejects Raycast, hidden/unavailable apps, nonstandard/minimized/modal windows, attached sheets when detectable, missing required safety attributes, invalid geometry and focus changes detected during the query. It never reads window titles.
- `dry-run`: validates the entire configuration, binding identity/enabled state, matching frontmost bundle, focused AX frame, target containment in both the half-open window and the active CG display union. No client geometry is accepted. Coordinates are logical desktop X-right/Y-down without scaling. Returns `diagnosticOnly:true`.
- `capture`: point picking overlay for the Raycast form. Request is `{"protocolVersion":1,"command":"capture","bundleId":"…","anchor":"top-left"}` (no config/bindingId). Fail-closed preconditions resolve before any overlay appears: AX trust (else PERMISSION_DENIED, no prompt), target app running (else APP_NOT_RUNNING), focused window retrievable with valid geometry (else UNSAFE_TARGET). The overlay dims every display with a gradient plus vignette, keeps the target window visible with an animated highlight (rounded cutout, breathing glow halo, corner brackets), draws crosshair plus live anchor/X/Y readout in logical coordinates, includes full-display alignment guides and a pointer-coordinate pill, and turns the crosshair accent yellow while the pointer is inside the target window; it is keyboard-driven on its key window: Enter confirms, Esc cancels, arrow keys nudge the picked point ±1 (Shift ±10) without moving the real cursor. Confirm re-reads the live AX frame, verifies finiteness, abs(offset)<=100000 and half-open containment in the window and an active display, then responds `bundleId/pid/frame/anchor/offset/target/durationMs`. Esc, focus loss and a 120s inactivity timeout return USER_CANCELLED. The overlay is an accessory app window; it swallows mouse clicks instead of letting them through, never posts events and never activates other apps.
- `execute`: validates the request/config/binding, then always returns `SAFETY_NOT_IMPLEMENTED`, without querying AX or producing any input.

Unknown fields are rejected at every schema level. Names use JavaScript-compatible UTF-16 length and ECMAScript edge-whitespace rules for parity with the Raycast client. Duplicate hotkeys include disabled bindings and normalize modifier ordering.

No clicks, event posting, real cursor movement, permission prompts, app activation of third-party apps, focus restoration, services, hotkey registration, or title queries exist in this implementation. The only activation is the helper itself becoming the key window during `capture`, justified by the explicit picking gesture. Diagnostic success does **not** attest that a click would be safe. Occlusion, persistent authenticated target identity, nested/custom modal UI, and user-intervention safety are unfinished. AX attributes vary by app; unsupported required modal/minimized attributes conservatively reject. A window can span displays; only the computed target must be inside an active display, so display gaps reject.

## Verification boundary

XCTest covers config/request type strictness, unknown keys, IDs, duplicate normalized shortcuts, fixed enums, Unicode trim parity, resource limits, all five anchors, negative desktop origins, half-open edges, display gaps, invalid arithmetic, offset/anchor inverse round-trips, Cocoa→CG coordinate conversion, capture request shape rules and fail-closed CLI behavior (22 tests). CLI integration tests cover structured status, bounded input, invalid UTF-8, fail-closed execution/error exit codes, malformed capture rejection without overlay, and capture preconditions failing closed (PERMISSION_DENIED or APP_NOT_RUNNING). Live permission-granted AX behavior, overlay keyboard/focus interaction, focus handoff from a closed Raycast panel, multi-monitor layouts and mixed-scale hardware require manual verification; pure geometry tests are not substitutes for those checks.
