# History

Audit trail of bugs found, issues discovered, and fixes applied during
development and the monolith-to-modules migration.

## 2026-05-29 — Modularization

### Architecture overhaul
- **Monolith extracted**: Single 4,131-line `filen.dart` decomposed into
  15 modules following internxt-dart's architecture pattern.
- **Stale copy deleted**: `filen_1.dart` (v0.0.3) was an outdated copy
  that diverged from the main `filen.dart` (v0.0.4). Deleted since nothing
  imported it.

### Issues found during extraction
- **Private method visibility**: All crypto/API methods were `_private` on
  `FilenClient`, making them inaccessible to extracted modules. Converted to
  public methods on their respective module classes (e.g., `_encryptMetadata002`
  became `FilenCrypto.encryptMetadata002`).
- **WebDAV `_log` extension hack**: `webdav_filesystem.dart` used a Dart
  extension to add a `_log` method to `FilenClient` because the real `_log`
  was private. Replaced with a public `log()` method on `FilenClient`.
- **State coupling**: `masterKeys`, `email`, `apiKey`, `baseFolderUUID` were
  mutable fields scattered across `FilenClient`. Centralized: auth state on
  `FilenApi` (apiKey) and `FilenDrive` (masterKeys, email, baseFolderUUID),
  with `setAuth()` on the facade propagating to both.
- **Path cache coupling**: `_pathCache` was used by both `resolvePath` and
  `createFolderRecursive` (drive) but also cleared by mutations. Moved to
  `FilenCache` with explicit `clearPathCache()`.

### CrispCloud integration
- **Embedded copy removed**: CrispCloud had a 4,497-line embedded copy of
  `filen.dart` in `lib/services/filen.dart`. Replaced with a git dependency
  on `CrispStrobe/filen-dart` (same pattern as the earlier internxt-dart
  migration in Phase 6.c).
- **Missing Web APIs**: CrispCloud's embedded copy had `uploadBytes()` and
  `downloadFileBytes()` methods for Web platform support that weren't in the
  original filen-dart. Added these to the library.

## Pre-migration (v0.0.1 – v0.0.4)

### Known issues inherited from initial development
- **Hardcoded WebDAV credentials**: Username `filen` / password `filen-webdav`
  are hardcoded. Not yet configurable.
- **No SSL for WebDAV**: HTTP only. Fixed in v0.0.5 with `--ssl-cert`/`--ssl-key`
  flags.
- **2FA placeholder**: `twoFactorCode` defaults to `"XXXXXX"` — the Filen API
  skips 2FA when this value is passed.
- **No concurrent uploads**: Uploads were strictly sequential. Fixed in v0.0.5
  with `MemoryGate` for memory-bounded concurrency.
