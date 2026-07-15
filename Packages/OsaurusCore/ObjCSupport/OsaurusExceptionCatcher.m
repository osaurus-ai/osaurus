//
//  OsaurusExceptionCatcher.m
//  osaurus
//

#import "OsaurusObjCSupport.h"

NSException *_Nullable osr_catch_exception(void(NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
