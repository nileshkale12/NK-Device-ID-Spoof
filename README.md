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

**Slightly different from the Android module, not actually worse**:
MobileSubstrate decides *which processes get this dylib injected at all*
via a filter plist (`NKDeviceIDChangerIOS.plist`), separately from the
CFPreferences config that decides *what to return*. Adding a brand-new
target app means updating **both** files — but neither requires a
rebuild: Theos installs the filter plist as a plain file at
`/var/jb/Library/MobileSubstrate/DynamicLibraries/NKDeviceIDChangerIOS.plist`,
which Substrate re-reads at every app launch, so editing it live +
respringing is enough (no reinstall). **`manage-targets.sh`** (run
on-device over SSH/NewTerm/Filza) wraps both edits + the respring into
one command — see below.

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

## Before first install

The `.deb` ships with a placeholder bundle ID (`com.example.REPLACE_ME`)
in `NKDeviceIDChangerIOS.plist`, so it targets nothing useful until you
add real apps. You can either:

- Edit `NKDeviceIDChangerIOS.plist` before building (put your real target
  bundle IDs in the `Bundles` array), or
- Build once with the placeholder, install it, then use
  **`manage-targets.sh`** on-device to add/remove targets afterward —
  no rebuild needed either way (see below).

## Adding / removing target apps at any time (no rebuild)

Copy `manage-targets.sh` onto the device (or `cat` it in over SSH) and
run it there — it edits both the filter plist and the prefs plist and
handles the respring for you:

```sh
chmod +x manage-targets.sh

./manage-targets.sh add com.target.app1                  # random IDFV
./manage-targets.sh add com.target.app2 5A9C1F3E-2B4D-4E1A-9C3F-1D2E3F4A5B6C
./manage-targets.sh list                                  # see current targets
./manage-targets.sh remove com.target.app1                # stop targeting it

./manage-targets.sh disable   # global kill switch off — no respring needed
./manage-targets.sh enable    # global kill switch on  — no respring needed
```

`add`/`remove` trigger a respring (Substrate re-scans the filter plist at
each app launch, not continuously); `enable`/`disable` don't need one,
since the prefs plist is read live on every call.

## Install via Sileo

Same as any tweak `.deb` (Choicy, Shadow, etc.):

1. Copy the built `.deb` onto the device (AirDrop, `scp`, or download
   link if you're hosting it in a repo).
2. Open it in **Filza** → tap the file → **Install with Sileo**, or open
   **Sileo** → the "…" menu → **Install `.deb`** and pick the file.
3. Sileo installs it and offers to respring — accept.
4. Use `manage-targets.sh add <bundle.id>` (see above) to target your
   first app(s) — it writes the prefs plist and filter plist for you and
   resprings automatically.

If you want it in your own Sileo repo instead of a one-off sideload, host
the `.deb` alongside a `Packages`/`Release` index the way any personal
repo does — out of scope for this README, same as it would be for any
other tweak.

## Verifying / restoring

- **Verify via console log** (easiest — shows real vs. spoofed side by
  side): the hook logs every time it fires. Over SSH:
  ```sh
  deviceconsole | grep NKDeviceIDChangerIOS
  ```
  Launch the target app — you should see
  `identifierForVendor real=<uuid> spoofed=<uuid>` with two different values.
- **Verify via Frida** (no target-app UI needed):
  ```sh
  frida -U -f com.target.app -e --no-pause -e "
  console.log(ObjC.classes.UIDevice.currentDevice().identifierForVendor().UUIDString().toString());
  "
  ```
  Run once with `./manage-targets.sh disable` (real value), then
  `./manage-targets.sh enable` (should print the fake UUID instead) —
  just relaunch the app between the two, no rebuild/respring needed for
  the enable/disable toggle itself.
- Restore: `./manage-targets.sh remove <bundle.id>` (stop targeting that
  app) or `./manage-targets.sh disable` (global off, keeps the target
  list intact for later). No reboot required, unlike the Android module —
  next launch of the target app sees its real IDFV again.

## Authorized use only

This tool mutates what a live app process observes on the device it's
installed on. Use it only on devices you own or are explicitly
authorized to test, within an active engagement's scope.
