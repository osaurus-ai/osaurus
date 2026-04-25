/*
 *  OsaurusSQLCipher.h
 *  Vendored SQLCipher 4.6.1 amalgamation, built with the CommonCrypto
 *  provider so we don't ship OpenSSL. This umbrella header re-exports
 *  the standard SQLite3 C API; consumers `#import` (Obj-C) or
 *  `import OsaurusSQLCipher` (Swift) and call the SQLite3 functions
 *  exactly as they would against the system `import SQLite3`.
 *
 *  CRITICAL: We force-define SQLITE_HAS_CODEC here so the SQLCipher
 *  codec entry points (`sqlite3_key`, `sqlite3_key_v2`,
 *  `sqlite3_rekey`, `sqlite3_rekey_v2`, `sqlite3_activate_*`) are
 *  visible to Swift when it imports this module. The C target
 *  itself sets the same macro via cSettings; this duplicate keeps
 *  the Swift-side declaration in sync without needing a custom
 *  module map.
 */

#ifndef OSAURUS_SQLCIPHER_H
#define OSAURUS_SQLCIPHER_H

#ifndef SQLITE_HAS_CODEC
#define SQLITE_HAS_CODEC 1
#endif

#include "sqlite3.h"

#endif
