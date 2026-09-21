#import "TouchBarPrivateBridge.h"
#import <objc/message.h>
#import <dlfcn.h>
typedef void (*Presence)(CFStringRef, BOOL);
static Presence presence(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY | RTLD_LOCAL);
    return handle ? (Presence)dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") : NULL;
}
BOOL CTBInstall(NSTouchBarItem *item) {
    NSCAssert([NSThread isMainThread], @"Touch Bar requires main thread");
    SEL add = NSSelectorFromString(@"addSystemTrayItem:");
    SEL remove = NSSelectorFromString(@"removeSystemTrayItem:");
    Presence set = presence();
    if (!set || ![NSTouchBarItem respondsToSelector:add] || ![NSTouchBarItem respondsToSelector:remove]) return NO;
    @try {
        ((void (*)(id,SEL,id))objc_msgSend)([NSTouchBarItem class], add, item);
        set((__bridge CFStringRef)item.identifier, YES);
        return YES;
    } @catch (NSException *e) { CTBRemove(item); return NO; }
}
void CTBRemove(NSTouchBarItem *item) {
    @try {
        Presence set = presence();
        if (set) set((__bridge CFStringRef)item.identifier, NO);
        SEL remove = NSSelectorFromString(@"removeSystemTrayItem:");
        if ([NSTouchBarItem respondsToSelector:remove])
            ((void (*)(id,SEL,id))objc_msgSend)([NSTouchBarItem class], remove, item);
    } @catch (NSException *e) {}
}
BOOL CTBPresentDynamic(NSTouchBar *bar) {
    SEL selector = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    if (![NSTouchBar respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, id, long long, id))objc_msgSend)([NSTouchBar class], selector, bar, 0, nil);
        return YES;
    } @catch (NSException *e) { return NO; }
}
void CTBDismissDynamic(NSTouchBar *bar) {
    SEL selector = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if (![NSTouchBar respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], selector, bar); }
    @catch (NSException *e) {}
}
