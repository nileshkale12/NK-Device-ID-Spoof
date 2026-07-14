# NK DeviceID Changer (iOS)

Rootless MobileSubstrate tweak (Dopamine / palera1n) that spoofs
**identifierForVendor (IDFV)** per target app on a jailbroken iPhone.
Built for authorized mobile-app pentest engagements — to exercise an
app's device-binding, fraud-scoring, or reinstall-detection logic under
a controlled identity change, and to leave the device provably back
where it started once testing is done (flip `Enabled` off, or uninstall).

iOS port of the Android **NK DeviceID Changer** module
(`tools/device-id-spoofer`), same narrow-scope philosophy — see below
for why it isn't a byte-for-byte port.

## Why identifierForVendor, not IMEI / UDID / serial / IDFA

- **IMEI / real UDID / serial** — no public API has exposed these since
  iOS 5. There's nothing for a tweak to read or patch; apps that claim
  to report a "device serial" on iOS are already synthesizing it from
  something else (usually IDFV or a Keychain UUID), which is exactly
  what this tweak targets instead.
- **IDFA (advertisingIdentifier)** — device-wide, not per-app, and
  already user-resettable via Settings → Privacy → Tracking. Not the
  right lever for per-app testing. Handled by the companion Frida script
  instead if you need to observe an app's behavior with it changed.
- **Keychain-stored UUIDs** — many apps generate their own persistent
  UUID and stash it in Keychain specifically because Keychain survives
  uninstall/reinstall (their own analog to why Android SSAID is
  per-package). There's no fixed key name across apps the way
  `settings_ssaid.xml` has one schema on Android, so this can't be
  patched generically — the Frida script logs `SecItemCopyMatching`
  calls so you can identify the key name for a specific app and hand-hook it.

**IDFV is the actual analog**: it's the one OS-managed, per-app-visible
identity value that persists across reinstalls (as long as one app from
the same vendor remains installed), which is what fraud/anti-fraud SDKs
actually read.

## How it works

1. `Tweak.xm` hooks `-[UIDevice identifierForVendor]` via MobileSubstrate.
2. On every call, it reads the CFPreferences domain
   `com.nileshkale.deviceidchangerios` (resolved centrally by `cfprefsd`,
   so this works regardless of which app's sandbox the tweak is running
   inside) and checks whether the calling app's bundle ID has a
   configured fake value.
3. If configured and `Enabled = 1`, it returns the fake `NSUUID`
   (a fixed value, or `"random"` for a fresh one every launch —
   equivalent to the Android module's "re-randomize every boot" queue
   mode). Otherwise it returns the real value untouched.

**Better than the Android module in one way**: because this is a live
function hook (not a boot-time file patch), flipping `Enabled` off takes
effect on the *next launch* of a targeted app — no reboot needed, unlike
the Android SSAID rewrite which only applies at `system_server` boot.

**Worse than the Android module in one way**: MobileSubstrate decides
*which processes get this dylib injected at all* via a filter plist
(`NKDeviceIDChangerIOS.plist`), separately from the CFPreferences config
that decides *what to return*. Adding a brand-new target app means
editing **both** files and respringing — there's no single "just add a
package to a JSON list" convenience the way Zygisk's `preAppSpecialize`
gives Android (Zygisk injects into every app process generically; Substrate
needs an explicit bundle-ID allowlist). Keep the two lists in sync.

## Building it

**No Theos toolchain or jailbroken iPhone is available in the environment
this was written in**, so this ships as source only, unverified by an
actual build or install — same situation the Android module's README is
upfront about for its own missing NDK.

### Option A — GitHub Actions (recommended, no Mac/Linux needed)

Push this folder to your own GitHub repo and trigger
`.github/workflows/build.yml` manually (workflow_dispatch), or on any
push under `tools/device-id-spoofer-ios/**`. It installs Theos on an
Ubuntu runner, builds the rootless `.deb`, and uploads it as a workflow
artifact — mirrors how `NKDeviceSpoof`'s own CI build works around not
having a local Android NDK.

### Option B — local Theos (Linux/macOS/WSL with a real toolchain)

```sh
git clone https://github.com/theos/theos.git $HOME/theos
export THEOS=$HOME/theos
export THEOS_PACKAGE_SCHEME=rootless
cd tools/device-id-spoofer-ios
make clean package FINALPACKAGE=1
# .deb lands in packages/
```

## Before first install — edit two files

1. **`NKDeviceIDChangerIOS.plist`** (MobileSubstrate filter) — replace
   the placeholder bundle ID with every app you want targetable:
   ```
   Bundles = ( "com.target.app1", "com.target.app2" );
   ```
2. **`layout/com.nileshkale.deviceidchangerios.plist.example`** — copy to
   the actual prefs path on-device (`/var/jb/var/mobile/Library/Preferences/com.nileshkale.deviceidchangerios.plist`)
   and set the same bundle IDs with their fake IDFV values (or `"random"`).

Rebuild after step 1 (the filter plist is baked into the `.deb`); step 2
can be edited live on-device via SSH or Filza without rebuilding.

## Install via Sileo

Same as any tweak `.deb` (Choicy, Shadow, etc.):

1. Copy the built `.deb` onto the device (AirDrop, `scp`, or download
   link if you're hosting it in a repo).
2. Open it in **Filza** → tap the file → **Install with Sileo**, or open
   **Sileo** → the "…" menu → **Install `.deb`** and pick the file.
3. Sileo installs it and offers to respring — accept.
4. Push the real prefs plist (step 2 above) to
   `/var/jb/var/mobile/Library/Preferences/com.nileshkale.deviceidchangerios.plist`
   via SSH/Filza. No respring needed for prefs changes, only for adding
   new bundle IDs to the filter plist (requires rebuilding + reinstalling).

If you want it in your own Sileo repo instead of a one-off sideload, host
the `.deb` alongside a `Packages`/`Release` index the way any personal
repo does — out of scope for this README, same as it would be for any
other tweak.

## Verifying / restoring

- Verify: install a "device info" app (or the target app's own
  diagnostics screen if it displays IDFV) on both a targeted and a
  non-targeted bundle ID, confirm only the targeted one changes.
- Restore: set `Enabled = 0` in the prefs plist (or delete it, or
  uninstall via Sileo). No reboot required, unlike the Android module —
  next launch of the target app sees its real IDFV again.

## Authorized use only

This tool mutates what a live app process observes on the device it's
installed on. Use it only on devices you own or are explicitly
authorized to test, within an active engagement's scope.
