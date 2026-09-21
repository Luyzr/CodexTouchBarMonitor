#import <AppKit/AppKit.h>
FOUNDATION_EXPORT BOOL CTBInstall(NSTouchBarItem *item);
FOUNDATION_EXPORT void CTBRemove(NSTouchBarItem *item);
// User-approved temporary app-area presentation; preserve Control Strip.
FOUNDATION_EXPORT BOOL CTBPresentDynamic(NSTouchBar *bar);
FOUNDATION_EXPORT void CTBDismissDynamic(NSTouchBar *bar);
