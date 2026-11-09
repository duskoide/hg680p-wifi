#!/usr/bin/env bash
# setup-wifi-hg680p.sh — enable onboard WiFi on HG680P (Amlogic S905X) STBs running Armbian (ophub kernels).
#
# The HG680P's onboard WiFi is a Realtek RTL8189FTV (SDIO id 024c:f179). ophub kernels don't ship
# a driver for it (and may load the unrelated aic8800 driver instead), so this script:
#   1. builds the out-of-tree 8189fs driver against the running kernel's headers,
#      auto-patching it for cfg80211 API changes detected in those headers,
#   2. installs + loads it, blacklists aic8800_sdio, makes it load at boot,
#   3. tells NetworkManager to ignore the driver's virtual 2nd interface (wlan1),
#   4. optionally connects to a WiFi network.
#
# Usage:
#   sudo ./setup-wifi-hg680p.sh                      # install driver only
#   sudo ./setup-wifi-hg680p.sh "MySSID" "password"  # install driver + connect
#
# Env overrides:
#   DRIVER_REPO / DRIVER_BRANCH  driver source (default: jwrdegoede/rtl8189ES_linux, branch rtl8189fs)
#   BUILD_DIR                    where to build (default: /usr/local/src/rtl8189fs)
#   FORCE=1                      skip the chip-id check / rebuild even if already installed
#
# NOTE: the module is built for the *current* kernel. After a kernel update (armbian-update etc.),
#       just run this script again.

set -euo pipefail

DRIVER_REPO="${DRIVER_REPO:-https://github.com/jwrdegoede/rtl8189ES_linux.git}"
DRIVER_BRANCH="${DRIVER_BRANCH:-rtl8189fs}"
BUILD_DIR="${BUILD_DIR:-/usr/local/src/rtl8189fs}"
FORCE="${FORCE:-0}"
SSID="${1:-}"
PSK="${2:-}"

KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
MOD_DEST="/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/8189fs.ko"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"
[[ "$(uname -m)" == "aarch64" ]] || die "Expected aarch64, got $(uname -m)."

# --- 1. sanity: is this the RTL8189FTV? -------------------------------------------------------
chip_found=0
for d in /sys/bus/sdio/devices/*; do
  [[ -e "$d/vendor" ]] || continue
  if [[ "$(cat "$d/vendor")" == "0x024c" && "$(cat "$d/device")" == "0xf179" ]]; then
    chip_found=1; SDIO_DEV="$d"
  fi
done
if [[ $chip_found -eq 0 ]]; then
  [[ "$FORCE" == 1 ]] || die "RTL8189FTV (SDIO 024c:f179) not found. Not an HG680P? Re-run with FORCE=1 to build anyway."
  warn "RTL8189FTV not detected, continuing because FORCE=1."
else
  log "Found RTL8189FTV at ${SDIO_DEV##*/}"
fi

# --- 2. already installed? ---------------------------------------------------------------------
if [[ "$FORCE" != 1 && -f "$MOD_DEST" ]]; then
  log "8189fs already built for $KVER, skipping build (FORCE=1 to rebuild)."
  SKIP_BUILD=1
else
  SKIP_BUILD=0
fi

if [[ $SKIP_BUILD -eq 0 ]]; then
  # --- 3. build deps ---------------------------------------------------------------------------
  [[ -e "$KDIR/Makefile" ]] || die "Kernel headers for $KVER not found at $KDIR.
    ophub Armbian images normally ship them in /usr/src/linux-headers-$KVER.
    Install the headers package matching your kernel, then re-run."

  missing=()
  for b in gcc make git bc flex bison perl; do command -v "$b" >/dev/null || missing+=("$b"); done
  if (( ${#missing[@]} )); then
    log "Installing build tools: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential git bc flex bison perl
  fi

  # --- 4. fetch source -------------------------------------------------------------------------
  log "Fetching driver source into $BUILD_DIR"
  rm -rf "$BUILD_DIR"
  git clone -q --depth 1 -b "$DRIVER_BRANCH" "$DRIVER_REPO" "$BUILD_DIR"
  log "Driver commit: $(git -C "$BUILD_DIR" log -1 --format='%h %s')"

  # --- 5. patch for cfg80211 API detected in the headers ---------------------------------------
  # ophub kernels backport newer cfg80211 APIs, so the driver's LINUX_VERSION_CODE guards are
  # wrong. Detect the real API from cfg80211.h and force the matching code paths.
  CFG_H="$KDIR/include/net/cfg80211.h"
  SRC="$BUILD_DIR/os_dep/linux/ioctl_cfg80211.c"
  [[ -f "$CFG_H" ]] || die "$CFG_H missing (incomplete headers?)"
  ops_sig() { # print the prototype of a cfg80211_ops member, flattened to one line
    perl -0777 -ne 'if (/\(\*'"$1"'\)\s*\(([^;]*)\);/s) { $x=$1; $x=~s/\s+/ /g; print $x }' "$CFG_H"
  }
  ADDKEY_SIG="$(ops_sig add_key)"
  ROC_SIG="$(ops_sig remain_on_channel)"

  if [[ "$ADDKEY_SIG" == *"struct wireless_dev"* ]]; then
    log "Patch: cfg80211 station/key ops take wireless_dev"
    sed -i 's/KERNEL_VERSION(7, 1, 0)/KERNEL_VERSION(0, 0, 0)/g' "$SRC"
  fi
  if [[ "$ROC_SIG" == *"rx_addr"* ]]; then
    log "Patch: remain_on_channel has rx_addr"
    perl -0pi -e 's/(#if \(LINUX_VERSION_CODE >= )KERNEL_VERSION\(7, 2, 0\)(\)\s*\n\s*, const u8 \*rx_addr)/${1}KERNEL_VERSION(0, 0, 0)$2/' "$SRC"
  fi
  if [[ -n "$ROC_SIG" && "$ROC_SIG" != *"u64 *cookie"* && "$ROC_SIG" == *"u64 cookie"* ]]; then
    log "Patch: cfg80211 cookies passed by value"
    sed -i 's/KERNEL_VERSION(7, 3, 0)/KERNEL_VERSION(0, 0, 0)/g' "$SRC"
  fi

  # --- 6. build ---------------------------------------------------------------------------------
  log "Building 8189fs for $KVER (takes ~10-15 min on S905X)..."
  if ! make -C "$BUILD_DIR" -j"$(nproc)" ARCH=arm64 KSRC="$KDIR" \
        CONFIG_PLATFORM_I386_PC=n CONFIG_PLATFORM_ARM_AARCH64=y >"$BUILD_DIR/build.log" 2>&1; then
    grep -E 'error' "$BUILD_DIR/build.log" | grep -v '^make' | head -20 >&2 || true
    die "Build failed. Full log: $BUILD_DIR/build.log"
  fi
  [[ -f "$BUILD_DIR/8189fs.ko" ]] || die "Build produced no 8189fs.ko"

  # --- 7. install --------------------------------------------------------------------------------
  install -D -m644 "$BUILD_DIR/8189fs.ko" "$MOD_DEST"
  depmod -a "$KVER"
  log "Installed $MOD_DEST"
fi

# --- 8. boot config ------------------------------------------------------------------------------
printf 'blacklist aic8800_sdio_bsp\nblacklist aic8800_sdio_wlan\n' > /etc/modprobe.d/blacklist-aic8800-sdio.conf
echo 8189fs > /etc/modules-load.d/8189fs.conf
grep -rqs 'options 8189fs' /etc/modprobe.d/ || echo 'options 8189fs rtw_power_mgnt=0 rtw_enusbss=0' > /etc/modprobe.d/8189fs.conf
if [[ -d /etc/NetworkManager/conf.d ]]; then
  printf '[keyfile]\nunmanaged-devices=interface-name:wlan1\n' > /etc/NetworkManager/conf.d/99-unmanage-wlan1.conf
fi
log "Boot config written (aic8800_sdio blacklisted, 8189fs autoloaded)."

# --- 9. load now ----------------------------------------------------------------------------------
modprobe -r aic8800_sdio_wlan aic8800_sdio_bsp 2>/dev/null || true
lsmod | grep -q '^8189fs ' || modprobe 8189fs
for _ in $(seq 1 15); do ip link show wlan0 >/dev/null 2>&1 && break; sleep 1; done
ip link show wlan0 >/dev/null 2>&1 || die "Module loaded but wlan0 did not appear. Check: dmesg | grep RTW"
log "wlan0 is up ($(cat /sys/class/net/wlan0/address))"

# --- 10. connect (optional) -----------------------------------------------------------------------
if command -v nmcli >/dev/null && systemctl is-active -q NetworkManager; then
  systemctl reload NetworkManager 2>/dev/null || true
  nmcli dev set wlan1 managed no 2>/dev/null || true
  if [[ -n "$SSID" ]]; then
    log "Scanning and connecting to '$SSID'..."
    for _ in $(seq 1 10); do  # wait (max ~40s) until the SSID shows up in scan results
      nmcli dev wifi rescan ifname wlan0 2>/dev/null || true
      sleep 4
      nmcli -t -f SSID dev wifi list ifname wlan0 2>/dev/null | grep -Fxq "$SSID" && break
    done
    ok=0
    for attempt in 1 2 3; do
      if nmcli dev wifi connect "$SSID" ${PSK:+password "$PSK"} ifname wlan0; then ok=1; break; fi
      warn "Connect attempt $attempt failed, retrying..."; sleep 5
      nmcli dev wifi rescan ifname wlan0 2>/dev/null || true; sleep 5
    done
    [[ $ok -eq 1 ]] || die "Could not connect to '$SSID'. Check SSID/password: nmcli dev wifi list"
    sleep 3
    log "Connected: $(ip -4 -o addr show wlan0 | awk '{print $4}')"
  else
    log "Driver ready. Connect with:  sudo nmcli dev wifi connect \"SSID\" password \"PASS\" ifname wlan0"
  fi
else
  warn "NetworkManager not active; configure wlan0 manually (e.g. armbian-config or wpa_supplicant)."
fi

log "Done. WiFi will come back automatically after reboot."
log "Remember: after a kernel update, run this script again."
