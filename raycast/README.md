# AppBind Raycast extension

Manage app-scoped bindings and an explicitly started native background service. Saving does not start the service; starting it can enable real guarded clicks. UI actions themselves are not global app-scoped hotkeys. Builds never start the service or request permissions.

## Development and release

- `npm run dev`: normal Raycast development session, including all debug commands/actions.
- `npm run build:dev`: development bundles in `dist`, including Helper Status, shortcut probe, dry-run and log viewer.
- `npm run build` / `npm run build:release`: release bundles in `dist-release`; only Manage Bindings, Create Binding and Background Service are registered.

Release is built in a temporary isolated staging directory. It excludes debug command sources and debug view implementations, replaces the debug-action module with a null component and the logging module with a no-op, then checks emitted JS/JSON/source maps for debug markers. This is compile-time exclusion, not just hiding actions at runtime. Original development sources and manifest remain unchanged. The dedicated generated release directory is replaced only after a successful build/check. No automatic installation/publication is performed; an existing `ray develop` session remains a dev build.

Release retains user-facing errors, permission/service status, start/stop/restart/reload and shortcut recording/manual entry. Helper diagnostics remain available in the separate native helper; this change removes extension debug UI, not safety checks or the helper diagnostic protocol.

## Reproduce local checks

Node 22.14+ (tested Node 22.22.0). All dependency versions are pinned in [package.json](package.json) and resolved in [package-lock.json](package-lock.json).

```sh
cd raycast
npm --cache .npm-cache ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
npm run build
```

The build uses Raycast's real `ray build -e dist -o dist` to produce local bundles without installing into Raycast. The actual installed API types are checked, not mocked. Tests use workspace-local temporary directories and fake executable helpers; no permissions are granted. A shared [v1 example](../examples/config.v1.json) is tested.

`--ignore-scripts` prevents the optional React DevTools Electron installer from downloading a debugger and writing its external user cache. The compiler, test runner and local Raycast build work without that debugger. An initial unqualified install attempted the Electron cache and was denied; no external cache was changed by this implementation. The initial default Raycast build output likewise attempted extension installation outside the workspace and was denied; the documented local output flag is used instead.

For an **explicit user-controlled install/development session**, run `npm run dev` in a terminal after reviewing the extension and helper. This was **not run** as part of implementation. Set the required **Absolute Helper Path** preference to the built helper executable, not a shell command. No bundled helper path is guessed. Interactive Raycast rendering and macOS Accessibility queries require manual testing in the intended environment.

## Fail-closed behavior

- Exact v1 shape, no unknown fields, finite bounded offsets, unique IDs and normalized same-app hotkey conflicts, including disabled bindings. Keys are lowercase ASCII letters/digits, modifiers a nonempty unique set.
- Config uses Raycast `environment.supportPath/config.json`; parent mode 0700, atomically renamed and fsynced temporary file mode 0600. Read/modify/write holds an exclusive `config.lock`. Missing file alone means empty config; malformed existing files never reset. Symlink config files are rejected. Stale locks require manual removal **only after verifying no writer is active**. External edits can conflict with a form; stale edits are refused.
- One process per helper request, absolute executable path, `spawn` with shell disabled, JSON stdin + EOF, 3-second default timeout (10-second ceiling), combined stdout/stderr 1 MiB cap, fatal UTF-8 decoding and strict envelope/payload/exit validation. stderr is bounded but not displayed to avoid leaking helper diagnostics. Execute is not a supported client request.
- Dry-run checks the live frontmost app. Raycast may itself be frontmost and cause `APP_MISMATCH`; this is explained before results. We never hide Raycast and guess the prior focus. Success is geometry diagnostics only, not click safety, identity persistence or occlusion assurance.

## Distribution boundary

The manifest author `appbind` and license metadata are local scaffolding, not a verified Raycast account, publication approval, trademark clearance or release-license signoff. Do not publish without owner review. Icon is locally generated extension artwork. No helper/service installation or OS permission change is performed by build/tests.
