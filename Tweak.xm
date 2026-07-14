/*
 * NK DeviceID Changer (iOS)
 *
 * Rootless (Dopamine/palera1n) MobileSubstrate tweak. Hooks
 * -[UIDevice identifierForVendor] and returns a configured fake NSUUID
 * for whichever app bundle IDs are listed in the CFPreferences domain
 * below, so the app under test sees a different IDFV without touching
 * any real hardware identifier.
 *
 * This is the iOS analog of the Android "NK DeviceID Changer" module's
 * SSAID rewrite: same narrow scope (one OS-managed per-app identity
 * value), same "authorized testing only" intent. It is NOT a 1:1 port —
 * see README.md "Why identifierForVendor, not IMEI/UDID/serial" for why
 * those aren't in scope here either.
 *
 * Config lives in the CFPreferences domain "com.nileshkale.deviceidchangerios",
 * resolved centrally by cfprefsd regardless of which app's sandbox this
 * tweak is running inside:
 *
 *   Enabled  (Boolean)     -- global kill switch, default NO
 *   Bundles  (Dictionary)  -- bundleID -> { IDFV = "<uuid>" | "random"; }
 *
 * Unlike the Android module (which patches settings_ssaid.xml at boot
 * and needs a reboot to take effect), this hook reads its config live on
 * every call -- flipping Enabled off takes effect on the *next* app
 * launch of a targeted app, no respring required for the kill switch
 * itself. Adding a NEW target bundle ID still requires updating the
 * MobileSubstrate filter plist and respringing, since Substrate decides
 * which processes get this dylib injected before the code below ever runs.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const kPrefsDomain = @"com.nileshkale.deviceidchangerios";

// TEMPORARY diagnostic: writes a plain file every time the hook fires, with
// exactly what it read at each step. No log viewer / Frida dependency --
// just `cat` it over SSH. Remove once the core spoof is confirmed working.
static void NKDiag(NSString *line) {
    NSString *path = @"/var/mobile/nkdevice_diag.txt";
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *stamped = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    [[existing stringByAppendingString:stamped] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSDictionary *NKLoadConfig(NSString *bundleIDForDiag) {
    CFPropertyListRef enabledRef = CFPreferencesCopyAppValue(
        CFSTR("Enabled"), (__bridge CFStringRef)kPrefsDomain);
    CFPropertyListRef bundlesRef = CFPreferencesCopyAppValue(
        CFSTR("Bundles"), (__bridge CFStringRef)kPrefsDomain);

    BOOL enabled = enabledRef ? [(__bridge NSNumber *)enabledRef boolValue] : NO;
    NSDictionary *bundles = bundlesRef ? (__bridge_transfer NSDictionary *)bundlesRef : nil;

    NKDiag([NSString stringWithFormat:
        @"hook fired for bundleID=%@ | enabledRef=%@ (enabled=%d) | bundlesRef=%@ (class=%@)",
        bundleIDForDiag,
        enabledRef ? @"present" : @"NIL",
        enabled,
        bundlesRef ? @"present" : @"NIL",
        bundles ? NSStringFromClass([bundles class]) : @"n/a"]);

    if (enabledRef) CFRelease(enabledRef);

    if (!enabled || ![bundles isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return bundles;
}

static NSUUID *NKFakeIDFVForCurrentBundle(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleID.length == 0) { NKDiag(@"bundleIdentifier is EMPTY"); return nil; }

    NSDictionary *bundles = NKLoadConfig(bundleID);
    if (!bundles) return nil;

    NSDictionary *entry = bundles[bundleID];
    NKDiag([NSString stringWithFormat:@"bundles dict keys=%@ | entry for %@ = %@", bundles.allKeys, bundleID, entry]);
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;

    NSString *value = entry[@"IDFV"];
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return nil;

    if ([value caseInsensitiveCompare:@"random"] == NSOrderedSame) {
        return [NSUUID UUID]; // fresh value every launch
    }
    NSUUID *fixed = [[NSUUID alloc] initWithUUIDString:value];
    return fixed; // nil if the configured string isn't a valid UUID -- falls through to real value
}

%hook UIDevice

- (NSUUID *)identifierForVendor {
    NKDiag(@"=== hook entered ===");
    NSUUID *fake = NKFakeIDFVForCurrentBundle();
    NSUUID *real = %orig;
    if (fake) {
        NSLog(@"[NKDeviceIDChangerIOS] identifierForVendor real=%@ spoofed=%@", real, fake);
        return fake;
    }
    return real;
}

%end
