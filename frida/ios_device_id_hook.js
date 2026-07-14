/*
 * Companion Frida script for the NK DeviceID Changer (iOS) tweak.
 *
 * The tweak (Tweak.xm) patches identifierForVendor (IDFV) persistently
 * for configured bundle IDs. It intentionally does NOT touch:
 *   - IDFA (advertisingIdentifier)   -- device-wide, not per-app, and
 *     resettable by the user anyway (Settings > Privacy > Tracking)
 *   - Keychain-stored UUIDs          -- apps invent their own key names,
 *     no fixed schema to patch generically the way settings_ssaid.xml
 *     has one on Android
 *   - Carrier/telephony info         -- CTTelephonyNetworkInfo
 *   - Real UDID/serial               -- no public API has exposed these
 *     since iOS 5; nothing to patch, nothing to restore
 *
 * For an app under test that reads any of the above as part of its own
 * device-binding or fraud-scoring logic, this script hooks the API
 * surface at runtime so you can observe how the app behaves with a
 * different reported identity -- fully reversible by detaching Frida.
 *
 * Usage (authorized engagement only, jailbroken device):
 *   frida -U -f <bundle.id> -l ios_device_id_hook.js --no-pause
 *   # or attach to a running process:
 *   frida -U -n <ProcessName> -l ios_device_id_hook.js
 *
 * Edit FAKE_* below before running.
 */

const FAKE_IDFA = "00000000-0000-0000-0000-000000000000";
const FAKE_CARRIER_NAME = "Fake Telecom";
const FAKE_CARRIER_MCC = "001";
const FAKE_CARRIER_MNC = "01";
const FAKE_KEYCHAIN_UUID_HINT = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";

function log(msg) {
  console.log(`[ios-device-id-hook] ${msg}`);
}

function hookIDFA() {
  const ASIdentifierManager = ObjC.classes.ASIdentifierManager;
  if (!ASIdentifierManager) {
    log("ASIdentifierManager not loaded (AdSupport not linked yet) -- skipping IDFA hook");
    return;
  }
  const method = ASIdentifierManager["- advertisingIdentifier"];
  if (!method) return;

  Interceptor.attach(method.implementation, {
    onLeave(retval) {
      const uuid = ObjC.Object(retval);
      const real = uuid.UUIDString().toString();
      const fake = ObjC.classes.NSUUID.UUIDWithString_(FAKE_IDFA);
      log(`advertisingIdentifier real="${real}" -> spoofed="${FAKE_IDFA}"`);
      retval.replace(fake.handle);
    },
  });
}

function hookCarrier() {
  const CTCarrier = ObjC.classes.CTCarrier;
  if (!CTCarrier) {
    log("CTCarrier not loaded (CoreTelephony not linked yet) -- skipping carrier hook");
    return;
  }

  const stringMethods = [
    ["- carrierName", FAKE_CARRIER_NAME],
    ["- mobileCountryCode", FAKE_CARRIER_MCC],
    ["- mobileNetworkCode", FAKE_CARRIER_MNC],
  ];

  for (const [sel, fake] of stringMethods) {
    const method = CTCarrier[sel];
    if (!method) continue;
    Interceptor.attach(method.implementation, {
      onLeave(retval) {
        const real = retval.isNull() ? "(null)" : new ObjC.Object(retval).toString();
        const fakeStr = ObjC.classes.NSString.stringWithString_(fake);
        log(`CTCarrier${sel.slice(1)} real="${real}" -> spoofed="${fake}"`);
        retval.replace(fakeStr.handle);
      },
    });
  }
}

function hookKeychainUUIDHint() {
  // Best-effort only: apps invent their own Keychain key names for a
  // self-generated persistent UUID, so there is no single method to hook
  // the way there is for IDFA/IDFV. This just logs every SecItemCopyMatching
  // call whose query dictionary looks like it's fetching a UUID-shaped
  // value, so you can identify the key name to target manually.
  const SecItemCopyMatching = Module.findExportByName("Security", "SecItemCopyMatching");
  if (!SecItemCopyMatching) return;

  Interceptor.attach(SecItemCopyMatching, {
    onEnter(args) {
      const query = new ObjC.Object(args[0]);
      log(`SecItemCopyMatching query=${query.toString()}`);
    },
  });

  log(`Keychain UUID hint value available if you want to hand-patch a match: ${FAKE_KEYCHAIN_UUID_HINT}`);
}

if (ObjC.available) {
  log("attaching...");
  hookIDFA();
  hookCarrier();
  hookKeychainUUIDHint();
  log("hooks installed");
} else {
  log("Objective-C runtime not available -- wrong target?");
}
