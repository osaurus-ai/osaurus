# Vendored SQLCipher

This directory contains a vendored copy of the
[SQLCipher](https://github.com/sqlcipher/sqlcipher) amalgamation,
exposed to Osaurus Swift code as the `OsaurusSQLCipher` SwiftPM C
target.

## Why vendor?

SQLCipher upstream does not ship pre-built amalgamations or a
SwiftPM-friendly source layout. Vendoring the generated amalgamation
lets us:

- Pin to a specific reviewed SQLCipher release.
- Audit exactly what ships in the binary.
- Build on macOS without OpenSSL (we use the CommonCrypto provider).

## Version

| File          | Source                                                                       |
|---------------|------------------------------------------------------------------------------|
| `sqlite3.c`   | SQLCipher 4.6.1 amalgamation, generated from upstream tag `v4.6.1`.          |
| `include/sqlite3.h`    | Matching public header.                                              |
| `include/sqlite3ext.h` | Matching extension header.                                          |

## Re-generating the amalgamation

If you need to bump SQLCipher (security release, FTS5 fix, etc.), run:

```bash
git clone --branch v4.6.1 https://github.com/sqlcipher/sqlcipher.git
cd sqlcipher

./configure \
    --enable-tempstore=yes \
    --enable-fts5 \
    --with-crypto-lib=commoncrypto \
    --disable-tcl \
    CFLAGS="-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC -DSQLITE_TEMP_STORE=2 \
           -DSQLITE_THREADSAFE=2 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE \
           -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_COLUMN_METADATA \
           -DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ENABLE_DBSTAT_VTAB" \
    LDFLAGS="-framework Security"

make sqlite3.c
cp sqlite3.c     <osaurus>/Packages/OsaurusCore/SQLCipher/sqlite3.c
cp sqlite3.h     <osaurus>/Packages/OsaurusCore/SQLCipher/include/sqlite3.h
cp sqlite3ext.h  <osaurus>/Packages/OsaurusCore/SQLCipher/include/sqlite3ext.h
```

Bump the version table above and the SQLCipher pin in the audit notes
when you do.

### Re-applying the FTS5 and sqlite3ext header guards

`include/sqlite3.h` has an OSAURUS LOCAL MODIFICATION that wraps the
entire `_FTS5_H` block in `#ifndef OSAURUS_OMIT_FTS5_HEADERS`. Without
that guard, the FTS5 C-extension typedefs (`Fts5ExtensionApi`,
`fts5_api`, `Fts5Context`, `Fts5PhraseIter`,
`fts5_extension_function`) collide at Swift Clang-importer level with
the same typedefs from Apple's system `SQLite3` module imported by
other workspace deps (notably `vmlx-swift-lm`'s `DiskCache`).

After copying a fresh `sqlite3.h` over the top, re-apply by:

1. Find the `#ifndef _FTS5_H` line. Insert this block immediately
   after `#define _FTS5_H`:

   ```c
   #ifndef OSAURUS_OMIT_FTS5_HEADERS
   ```

2. Find the matching `#endif /* _FTS5_H */` line near the end. Insert
   immediately before it:

   ```c
   #endif /* OSAURUS_OMIT_FTS5_HEADERS — END OSAURUS LOCAL MODIFICATION */
   ```

3. Confirm `OsaurusSQLCipher.h` still defines
   `OSAURUS_OMIT_FTS5_HEADERS` before it includes `sqlite3.h`, and
   `Package.swift` still defines the same flag in the
   `OsaurusSQLCipher` target `cSettings`.

The amalgamation `sqlite3.c` itself is **not** modified — it inlines
its own copy of sqlite3.h text, so the C compilation of FTS5 keeps
working.

### Re-applying the sqlite3ext import guard

`include/sqlite3ext.h` has an OSAURUS LOCAL MODIFICATION that hides the
loadable-extension API behind `OSAURUS_OMIT_SQLITE_EXTENSION_API`.
`include/OsaurusSQLCipher.h` defines that macro before including
`sqlite3ext.h`.

This exists because Osaurus imports SQLCipher from Swift for the core
SQLite API, not for compiling SQLite loadable extensions. Apple's
system `SQLite3` module is also imported by dependencies in the same
Swift build. When newer macOS SDKs append fields to
`sqlite3_api_routines` before this pinned SQLCipher version adopts the
same upstream SQLite release, Swift's Clang importer rejects the build
with a cross-module struct-definition mismatch.

After copying a fresh `sqlite3ext.h` over the top, re-apply by:

1. Find `#include "sqlite3.h"` near the top of the file. Insert the
   `#ifndef OSAURUS_OMIT_SQLITE_EXTENSION_API` block immediately after
   it.
2. Insert the matching close immediately before the final
   `#endif /* SQLITE3EXT_H */`.
3. Confirm `OsaurusSQLCipher.h` still defines
   `OSAURUS_OMIT_SQLITE_EXTENSION_API` immediately before it includes
   `sqlite3ext.h`.

## Why CommonCrypto?

`SQLCIPHER_CRYPTO_CC` selects Apple's CommonCrypto library as the
underlying cryptographic provider. This means:

- No OpenSSL dependency to ship or notarize.
- AES-256 + HMAC-SHA512 + PBKDF2 are implemented by Apple-maintained
  primitives.
- Linker pulls `Security.framework` (already required by Osaurus).

## Compile-time options enabled

- `SQLITE_HAS_CODEC` — required by SQLCipher.
- `SQLCIPHER_CRYPTO_CC` — CommonCrypto provider.
- `SQLITE_TEMP_STORE=2` — temp tables in memory (matches our PRAGMA).
- `SQLITE_THREADSAFE=2` — multi-thread mode (each connection its own thread).
- `SQLITE_ENABLE_FTS5` — full-text search 5 (memory FTS depends on this).
- `SQLITE_ENABLE_RTREE`, `SQLITE_ENABLE_JSON1`, `SQLITE_ENABLE_DBSTAT_VTAB`,
  `SQLITE_ENABLE_LOAD_EXTENSION`, `SQLITE_ENABLE_COLUMN_METADATA` — parity
  with what the system `libsqlite3` exposes.

## Symbol-collision note

Other SwiftPM dependencies in this workspace (notably
`vmlx-swift-lm/Libraries/MLXLMCommon/Cache/DiskCache.swift`) do
`import SQLite3` against the system `libsqlite3.dylib`. macOS's
two-level namespacing keeps both copies of `sqlite3_*` symbols from
colliding at runtime: vmlx's calls resolve to `libsqlite3.dylib`,
ours resolve to the statically-linked SQLCipher inside OsaurusCore.
If a future toolchain regression breaks this assumption (look for
`duplicate symbol` link errors or vmlx caching misbehaving), the
escape hatch is to redefine `SQLITE_API` to a per-target visibility
attribute and rebuild — see
<https://www.sqlite.org/c3ref/c_api_int.html>.

## License

SQLCipher is BSD-licensed (no GPL clauses). See
[`sqlite3.c`](./sqlite3.c) header comment.
