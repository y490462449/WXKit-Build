#import "WXKHook.h"
#import "WXKLog.h"
#import "WXKPrefs.h"

@implementation WXKHookRecord
- (NSString *)description {
    return [NSString stringWithFormat:@"%@ [%@ %@] %@",
            self.attached ? @"✔" : @"✘",
            self.className ?: @"?",
            self.selector ?: @"?",
            self.note ?: @""];
}
@end

static NSMutableArray<WXKHookRecord *> *gRecords = nil;

static void WXKRecord(NSString *cls, NSString *sel, BOOL attached, NSString *note) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecords = [NSMutableArray array];
    });
    @synchronized (gRecords) {
        WXKHookRecord *r = [[WXKHookRecord alloc] init];
        r.className = cls;
        r.selector = sel;
        r.attached = attached;
        r.note = note;
        [gRecords addObject:r];
    }
}

@implementation WXKHook

+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selector
    isClassMethod:(BOOL)isClassMethod
      replacement:(IMP)replacement
         original:(IMP *)originalOut
             note:(NSString *)note {
    if (!className.length || !selector.length || !replacement) {
        WXKRecord(className, selector, NO, @"参数不合法");
        return NO;
    }
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) {
        WXKRecord(className, selector, NO, @"类不存在");
        return NO;
    }
    Class target = isClassMethod ? object_getClass(cls) : cls;
    SEL sel = NSSelectorFromString(selector);
    Method method = class_getInstanceMethod(target, sel);
    if (!method) {
        WXKRecord(className, selector, NO, isClassMethod ? @"类方法不存在" : @"实例方法不存在");
        return NO;
    }
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    @try {
        class_replaceMethod(target, sel, replacement, types);
    } @catch (NSException *e) {
        WXKRecord(className, selector, NO, [NSString stringWithFormat:@"交换异常: %@", e.reason]);
        return NO;
    }
    if (originalOut) {
        *originalOut = original;
    }
    // 把方法签名也写进记录：微信各版本参数个数可能不同，靠这个能判断替换函数的参数是否匹配
    NSString *signature = types ? [NSString stringWithUTF8String:types] : @"?";
    WXKRecord(className, selector, YES,
              [NSString stringWithFormat:@"%@ | types=%@", note ?: @"", signature]);
    WXKLog(@"[hook] ✔ %@%@ %@ types=%@", isClassMethod ? @"+" : @"-", className, selector, signature);
    return YES;
}

+ (BOOL)hookAnyClass:(NSArray<NSString *> *)classNames
            selector:(NSString *)selector
       isClassMethod:(BOOL)isClassMethod
         replacement:(IMP)replacement
            original:(IMP *)originalOut
                note:(NSString *)note {
    for (NSString *name in classNames) {
        if ([self hookClass:name selector:selector isClassMethod:isClassMethod
                replacement:replacement original:originalOut note:note]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)hookClass:(NSString *)className
      anySelector:(NSArray<NSString *> *)selectors
     isClassMethod:(BOOL)isClassMethod
       replacement:(IMP)replacement
          original:(IMP *)originalOut
              note:(NSString *)note {
    for (NSString *sel in selectors) {
        if ([self hookClass:className selector:sel isClassMethod:isClassMethod
                replacement:replacement original:originalOut note:note]) {
            return YES;
        }
    }
    return NO;
}

+ (NSArray<WXKHookRecord *> *)records {
    if (!gRecords) {
        return @[];
    }
    @synchronized (gRecords) {
        return [gRecords copy];
    }
}

+ (void)clearRecords {
    @synchronized (gRecords) {
        [gRecords removeAllObjects];
    }
}

@end

BOOL WXKClassExists(NSString *className) {
    return className.length && objc_getClass(className.UTF8String) != Nil;
}

Class WXKFirstClassResponding(NSArray<NSString *> *classNames, NSString *selector, BOOL isClassMethod) {
    SEL sel = NSSelectorFromString(selector);
    for (NSString *name in classNames) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) {
            continue;
        }
        Class target = isClassMethod ? object_getClass(cls) : cls;
        if (class_getInstanceMethod(target, sel)) {
            return cls;
        }
    }
    return Nil;
}

static id WXKInvoke(id target, NSString *selector, id a1, id a2, id a3, NSInteger argc) {
    if (!target || !selector.length) {
        return nil;
    }
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) {
        return nil;
    }
    @try {
        IMP imp = [target methodForSelector:sel];
        switch (argc) {
            case 0: return ((id (*)(id, SEL))imp)(target, sel);
            case 1: return ((id (*)(id, SEL, id))imp)(target, sel, a1);
            case 2: return ((id (*)(id, SEL, id, id))imp)(target, sel, a1, a2);
            default: return ((id (*)(id, SEL, id, id, id))imp)(target, sel, a1, a2, a3);
        }
    } @catch (NSException *e) {
        WXKLog(@"[call] %@ 异常: %@", selector, e.reason);
        return nil;
    }
}

id WXKCall(id target, NSString *selector)                          { return WXKInvoke(target, selector, nil, nil, nil, 0); }
id WXKCall1(id target, NSString *selector, id a1)                  { return WXKInvoke(target, selector, a1, nil, nil, 1); }
id WXKCall2(id target, NSString *selector, id a1, id a2)           { return WXKInvoke(target, selector, a1, a2, nil, 2); }
id WXKCall3(id target, NSString *selector, id a1, id a2, id a3)    { return WXKInvoke(target, selector, a1, a2, a3, 3); }

id WXKCallClass(NSString *className, NSString *selector) {
    Class cls = WXKClassExists(className) ? objc_getClass(className.UTF8String) : Nil;
    if (!cls) {
        return nil;
    }
    return WXKInvoke(cls, selector, nil, nil, nil, 0);
}

id WXKValueAny(id object, NSArray<NSString *> *keyCandidates) {
    if (!object) {
        return nil;
    }
    for (NSString *key in keyCandidates) {
        if (!key.length) {
            continue;
        }
        @try {
            id value = [object valueForKey:key];
            if (value) {
                return value;
            }
        } @catch (NSException *e) {
            // 该版本没有这个字段，继续试下一个
        }
    }
    return nil;
}
