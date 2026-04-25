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

#include "sqlite3.h"

#endif
