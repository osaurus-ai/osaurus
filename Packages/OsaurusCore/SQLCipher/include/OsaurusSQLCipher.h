/*
 *  OsaurusSQLCipher.h
 *
 *  Module umbrella header for the vendored SQLCipher amalgamation.
 *  Consumers `import OsaurusSQLCipher` (Swift) and call the standard
 *  SQLite C API plus the SQLCipher codec functions.
 *
 *  ⚠️  LOAD-BEARING: this file is NOT just a re-export of
 *      `sqlite3.h`. It force-defines `SQLITE_HAS_CODEC` BEFORE
 *      `#include "sqlite3.h"` so the codec entry points
 *      (`sqlite3_key`, `sqlite3_key_v2`, `sqlite3_rekey`,
 *      `sqlite3_rekey_v2`, `sqlite3_activate_*`) are visible to
 *      Swift's Clang module parse. The C target's
 *      `cSettings.define("SQLITE_HAS_CODEC")` covers the .c
 *      compilation but does NOT propagate to the Clang module
 *      compilation that Swift uses, so without the local define
 *      here `EncryptedSQLiteOpener.swift` fails with
 *      "cannot find 'sqlite3_key_v2' in scope". Tested: deleting
 *      this file breaks the build immediately.
 *
 *      If you bump SQLCipher and the codec functions become
 *      gated behind a new macro, add the corresponding
 *      `#ifndef X #define X #endif` block here.
 */

#ifndef OSAURUS_SQLCIPHER_H
#define OSAURUS_SQLCIPHER_H

#ifndef SQLITE_HAS_CODEC
#define SQLITE_HAS_CODEC 1
#endif

#ifndef OSAURUS_OMIT_FTS5_HEADERS
#define OSAURUS_OMIT_FTS5_HEADERS 1
#endif

#include "sqlite3.h"
/* `sqlite3ext.h` lives in the same `include/` dir alongside us, so
 * Clang's umbrella-header consistency check requires it to either
 * be included from this umbrella or excluded via a module map.
 * We include it with the loadable-extension API hidden because
 * Osaurus does not compile SQLite loadable extensions, and newer
 * macOS SDKs may expose extension fields that SQLCipher 4.6.1 does
 * not. This silences the
 *
 *   warning: umbrella header for module 'OsaurusSQLCipher' does not
 *            include header 'sqlite3ext.h'
 *
 * without reintroducing Swift Clang-importer type collisions against
 * Apple's system SQLite3 module. */
#ifndef OSAURUS_OMIT_SQLITE_EXTENSION_API
#define OSAURUS_OMIT_SQLITE_EXTENSION_API 1
#endif
#include "sqlite3ext.h"

#endif
