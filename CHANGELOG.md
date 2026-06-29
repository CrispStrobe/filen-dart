# Changelog

## 0.2.0 — Bounded chunk + file-level concurrency

Chunk and file transfers now run with **bounded concurrency** instead of
one-at-a-time — the single biggest throughput win for the client.

### Added
- **Bounded chunk concurrency (Step 1):** uploads (`uploadFileChunked`,
  `uploadBytes`) and downloads (`downloadFile`, `downloadFileBytes`) transfer
  multiple 1 MB chunks in parallel, bounded by a `ChunkSemaphore` (count) **and**
  the `MemoryGate` (bytes in flight). Configurable via `maxConcurrentChunks`
  (default 4).
- **File-level concurrency (Step 2):** batch directory upload/download transfer
  multiple whole files at once, sharing one global memory budget.

### Fixed
- Resume now tracks a completed-index **set** (safe with out-of-order chunk
  completion) and reuses the original file key on restart — previously a fresh
  key made already-uploaded chunks undecryptable.

### Preserved invariants
- In-order whole-file SHA-512 hashing (parallel uploads produce the identical
  hash to the sequential path); tiny files stay on the simple sequential path.

### CI
- Pinned Dart SDK, `coverage` dev-dependency, per-job timeouts, `workflow_dispatch`.

## 0.1.0

- Initial release: chunked upload/download with resume, batch operations,
  recursive transfers, conflict handling, integrity verification, WebDAV server.
