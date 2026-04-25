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

## License

SQLCipher is BSD-licensed (no GPL clauses). See
[`sqlite3.c`](./sqlite3.c) header comment.
