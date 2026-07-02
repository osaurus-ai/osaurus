//
//  OsaurusObjCSupport.h
//  osaurus
//
//  Small Objective-C shim for the handful of framework calls that can raise
//  an NSException that Swift cannot `catch`.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try`/`@catch`. Returns `nil` when the
/// block completes normally, or the caught `NSException` when one is raised.
///
/// Swift's `do`/`catch` only handles `Error`, not Objective-C `NSException`, so
/// an exception thrown by a framework call (e.g. AppKit's non-thread-safe
/// `NSPasteboard` type-cache mutation racing another access) otherwise
/// terminates the process. Wrapping such a call in this helper lets the Swift
/// caller treat it as a recoverable failure instead of a crash.
NSException *_Nullable osr_catch_exception(void(NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
