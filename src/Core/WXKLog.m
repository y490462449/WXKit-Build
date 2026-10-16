#import "WXKLog.h"
#import "WXKCommon.h"
#import "WXKPrefs.h"
#import <os/log.h>
#import <pthread.h>
#import <stdarg.h>

#define WXK_LOG_MAX 1000

static NSMutableArray<NSString *> *gLines = nil;
static NSDateFormatter *gFormatter = nil;
static os_log_t gOSLog = NULL;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gFileSinkFailed = NO;

static void WXKLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLines = [NSMutableArray arrayWithCapacity:WXK_LOG_MAX];
        gOSLog = os_log_create("com.wxkit.tweak", "log");
        gFormatter = [[NSDateFormatter alloc] init];
        gFormatter.dateFormat = @"HH:mm:ss.SSS";
        gFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
}

static NSString *WXKLogFilePathUnlocked(void) {
    return [[WXKPrefs configDirectory] stringByAppendingPathComponent:WXK_LOG_FILE];
}

static void WXKLogAppendToFile(NSString *line) {
    if (gFileSinkFailed) {
        return;
    }
    NSString *path = WXKLogFilePathUnlocked();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        gFileSinkFailed = YES;
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[(line ?: @"") stringByAppendingString:@"\n"]];
        [fh closeFile];
    } @catch (NSException *e) {
        gFileSinkFailed = YES;
    }
}

static void WXKLogWrite(BOOL verbose, NSString *fmt, va_list ap) {
    WXKLogInit();
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    if (verbose && ![WXKPrefs shared].boolVerbose) {
        return;
    }
    NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
    NSString *line = nil;
    pthread_mutex_lock(&gLock);
    line = [NSString stringWithFormat:@"[%@] %@", [gFormatter stringFromDate:[NSDate date]], msg];
    [gLines addObject:line];
    while (gLines.count > WXK_LOG_MAX) {
        [gLines removeObjectAtIndex:0];
    }
    NSString *full = [NSString stringWithFormat:@"%@ %@", proc, line];
    WXKLogAppendToFile(full);
    pthread_mutex_unlock(&gLock);

    if (gOSLog) {
        os_log_info(gOSLog, "%{public}s", full.UTF8String);
    }
}

void WXKLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    WXKLogWrite(NO, fmt, ap);
    va_end(ap);
}

void WXKLogVerbose(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    WXKLogWrite(YES, fmt, ap);
    va_end(ap);
}

NSArray<NSString *> *WXKLogSnapshot(void) {
    WXKLogInit();
    pthread_mutex_lock(&gLock);
    NSArray<NSString *> *copy = [gLines copy];
    pthread_mutex_unlock(&gLock);
    return copy;
}

void WXKLogClear(void) {
    WXKLogInit();
    pthread_mutex_lock(&gLock);
    [gLines removeAllObjects];
    pthread_mutex_unlock(&gLock);
}

NSString *WXKLogFilePath(void) {
    WXKLogInit();
    return WXKLogFilePathUnlocked();
}

BOOL WXKLogFlushToFile(void) {
    NSArray<NSString *> *lines = WXKLogSnapshot();
    NSString *body = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    BOOL ok = [body writeToFile:WXKLogFilePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    pthread_mutex_lock(&gLock);
    gFileSinkFailed = NO;
    pthread_mutex_unlock(&gLock);
    return ok;
}
