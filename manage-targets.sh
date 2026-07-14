#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# manage-targets.sh — add/remove target apps for NK DeviceID Changer (iOS)
# at runtime, no rebuild/reinstall needed (only a respring for add/remove).
#
# Run THIS ON THE DEVICE (SSH, NewTerm, or Filza's built-in terminal), as the
# `mobile` user. Requires the tweak already installed via Sileo.
#
# Usage:
#   ./manage-targets.sh list
#   ./manage-targets.sh add <bundle.id> [idfv-uuid|random]   (default: random)
#   ./manage-targets.sh remove <bundle.id>
#   ./manage-targets.sh enable            # global kill switch on  (no respring)
#   ./manage-targets.sh disable           # global kill switch off (no respring)
#
# What it touches:
#   1. Filter plist (WHICH processes get the dylib injected at all):
#        /var/jb/Library/MobileSubstrate/DynamicLibraries/NKDeviceIDChangerIOS.plist
#      Substrate reads this fresh at each app launch -- add/remove needs a
#      respring (done automatically below) so it re-scans, but never a
#      rebuild/reinstall of the .deb.
#   2. Prefs plist (WHAT fake IDFV each targeted app gets):
#        /var/jb/var/mobile/Library/Preferences/com.nileshkale.deviceidchangerios.plist
#      Read live on every call -- no respring needed for this one alone.
# ─────────────────────────────────────────────────────────────────────────────
set -e

PB=/usr/libexec/PlistBuddy
FILTER_PLIST=/var/jb/Library/MobileSubstrate/DynamicLibraries/NKDeviceIDChangerIOS.plist
PREFS_PLIST=/var/jb/var/mobile/Library/Preferences/com.nileshkale.deviceidchangerios.plist

die() { echo "error: $1" >&2; exit 1; }

[ -x "$PB" ] || die "PlistBuddy not found at $PB (are you running this ON the jailbroken device?)"

ensure_filter_plist() {
  [ -f "$FILTER_PLIST" ] || die "filter plist missing at $FILTER_PLIST -- is the tweak installed via Sileo?"
}

ensure_prefs_plist() {
  if [ ! -f "$PREFS_PLIST" ]; then
    mkdir -p "$(dirname "$PREFS_PLIST")"
    cat > "$PREFS_PLIST" <<'EOF'
{
  "Enabled" = 0;
  "Bundles" = { };
}
EOF
  fi
}

respring() {
  echo "==> Respringing..."
  if command -v sbreload >/dev/null 2>&1; then
    sbreload
  else
    killall -9 SpringBoard
  fi
}

read_filter_bundles() {
  # Print the Filter:Bundles string array, one bundle ID per line, trimmed.
  "$PB" -c "Print :Filter:Bundles" "$FILTER_PLIST" 2>/dev/null \
    | sed -n '2,$p' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^}$'
}

rewrite_filter_bundles() {
  # $@ = full desired list of bundle IDs (deduped by caller)
  "$PB" -c "Delete :Filter:Bundles" "$FILTER_PLIST" >/dev/null 2>&1 || true
  "$PB" -c "Add :Filter:Bundles array" "$FILTER_PLIST"
  for b in "$@"; do
    "$PB" -c "Add :Filter:Bundles: string $b" "$FILTER_PLIST"
  done
}

cmd_list() {
  ensure_filter_plist
  ensure_prefs_plist
  echo "Filter plist targets (dylib injected into these processes):"
  read_filter_bundles | sed 's/^/  - /'
  echo
  echo "Prefs (fake IDFV per bundle):"
  "$PB" -c "Print :Bundles" "$PREFS_PLIST" 2>/dev/null | sed -n '2,$p' | sed 's/^}$//' | sed '/^$/d' | sed 's/^/  /'
  echo
  ENABLED=$("$PB" -c "Print :Enabled" "$PREFS_PLIST" 2>/dev/null || echo "?")
  echo "Enabled (global kill switch): $ENABLED"
}

cmd_add() {
  BUNDLE_ID="$1"
  IDFV="${2:-random}"
  [ -n "$BUNDLE_ID" ] || die "usage: add <bundle.id> [idfv-uuid|random]"
  ensure_filter_plist
  ensure_prefs_plist

  # 1) filter plist: add bundle id if not already present, then respring
  EXISTING=$(read_filter_bundles)
  if echo "$EXISTING" | grep -qx "$BUNDLE_ID"; then
    echo "==> $BUNDLE_ID already in filter plist"
  else
    NEW_LIST=$(printf '%s\n%s\n' "$EXISTING" "$BUNDLE_ID" | sed '/^$/d')
    rewrite_filter_bundles $NEW_LIST
    echo "==> Added $BUNDLE_ID to filter plist"
  fi

  # 2) prefs plist: set/replace this bundle's fake IDFV, ensure Enabled=1
  "$PB" -c "Delete :Bundles:$BUNDLE_ID" "$PREFS_PLIST" >/dev/null 2>&1 || true
  "$PB" -c "Add :Bundles:$BUNDLE_ID dict" "$PREFS_PLIST"
  "$PB" -c "Add :Bundles:$BUNDLE_ID:IDFV string $IDFV" "$PREFS_PLIST"
  "$PB" -c "Set :Enabled true" "$PREFS_PLIST" >/dev/null 2>&1 || "$PB" -c "Add :Enabled bool true" "$PREFS_PLIST"
  echo "==> $BUNDLE_ID -> IDFV=$IDFV in prefs plist, Enabled=true"

  respring
  echo "==> Done. Launch $BUNDLE_ID fresh to see the spoofed IDFV."
}

cmd_remove() {
  BUNDLE_ID="$1"
  [ -n "$BUNDLE_ID" ] || die "usage: remove <bundle.id>"
  ensure_filter_plist
  ensure_prefs_plist

  EXISTING=$(read_filter_bundles)
  if echo "$EXISTING" | grep -qx "$BUNDLE_ID"; then
    NEW_LIST=$(echo "$EXISTING" | grep -vx "$BUNDLE_ID")
    rewrite_filter_bundles $NEW_LIST
    echo "==> Removed $BUNDLE_ID from filter plist"
  else
    echo "==> $BUNDLE_ID was not in filter plist"
  fi

  "$PB" -c "Delete :Bundles:$BUNDLE_ID" "$PREFS_PLIST" >/dev/null 2>&1 || true
  echo "==> Removed $BUNDLE_ID from prefs plist"

  respring
  echo "==> Done. $BUNDLE_ID now sees its real IDFV again."
}

cmd_enable()  { ensure_prefs_plist; "$PB" -c "Set :Enabled true"  "$PREFS_PLIST" >/dev/null 2>&1 || "$PB" -c "Add :Enabled bool true"  "$PREFS_PLIST"; echo "==> Enabled=true (no respring needed)"; }
cmd_disable() { ensure_prefs_plist; "$PB" -c "Set :Enabled false" "$PREFS_PLIST" >/dev/null 2>&1 || "$PB" -c "Add :Enabled bool false" "$PREFS_PLIST"; echo "==> Enabled=false (no respring needed)"; }

case "$1" in
  list)    cmd_list ;;
  add)     shift; cmd_add "$@" ;;
  remove)  shift; cmd_remove "$@" ;;
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  *) echo "usage: $0 {list|add <bundle.id> [idfv|random]|remove <bundle.id>|enable|disable}" >&2; exit 1 ;;
esac
