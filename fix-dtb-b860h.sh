#!/usr/bin/env bash
# fix-dtb-b860h.sh — make the ZTE B860H's onboard WiFi show up on the SDIO bus under Armbian.
#
# Armbian boots the B860H with the generic meson-gxl-s905x-p212.dtb. That DTB powers the WiFi chip
# through GPIOX_6 (sdio-pwrseq reset-gpios), but the B860H wires WiFi power to GPIODV_27 (read from
# the stock Android DTB). With the wrong pin the chip stays off and dmesg shows:
#     mmc2: Failed to initialize a non-removable card
#
# This script copies the P212 DTB, patches the WiFi power pin, and points extlinux.conf at the copy.
# The original DTB is not modified; extlinux.conf is backed up first.
#
# Usage:
#   sudo ./fix-dtb-b860h.sh              # use GPIODV_27 (default)
#   sudo ./fix-dtb-b860h.sh GPIOX_17     # try another pin (stock firmware also lists GPIOX_17, GPIOX_15)
#   sudo reboot
#
# After a kernel update, run it again so the patched copy is rebuilt from the new kernel's P212 DTB.
#
# Revert:
#   sudo cp /boot/extlinux/extlinux.conf.bak-b860h /boot/extlinux/extlinux.conf && sudo reboot

set -euo pipefail

PIN="${1:-GPIODV_27}"
BOOT=/boot
EXTLINUX="$BOOT/extlinux/extlinux.conf"
SRC_DTB="${SRC_DTB:-$BOOT/dtb/amlogic/meson-gxl-s905x-p212.dtb}"
OUT_REL="/dtb-b860h/meson-gxl-s905x-b860h-wifi.dtb"   # outside /boot/dtb so kernel upgrades don't delete it
OUT="$BOOT$OUT_REL"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"
[[ -f "$EXTLINUX" ]] || die "$EXTLINUX not found (this script only handles extlinux boot)."
[[ -f "$SRC_DTB" ]] || die "Source DTB $SRC_DTB not found."

# --- pin name -> GXL periphs GPIO number (include/dt-bindings/gpio/meson-gxl-gpio.h) ---------------
pin_num() {
  local p="${1^^}" bank idx base
  [[ "$p" =~ ^[0-9]+$ ]] && { echo "$p"; return; }
  [[ "$p" =~ ^(GPIOZ|GPIOH|BOOT|CARD|GPIODV|GPIOX)_([0-9]+)$ ]] || return 1
  bank="${BASH_REMATCH[1]}"; idx="${BASH_REMATCH[2]}"
  case "$bank" in
    GPIOZ) base=0;  ((idx<=15)) ;;  GPIOH)  base=16; ((idx<=9))  ;;
    BOOT)  base=26; ((idx<=15)) ;;  CARD)   base=42; ((idx<=6))  ;;
    GPIODV) base=49; ((idx<=29)) ;; GPIOX)  base=79; ((idx<=18)) ;;
  esac || return 1
  echo $((base + idx))
}
NUM="$(pin_num "$PIN")" || die "Unknown pin '$PIN' (use e.g. GPIODV_27, GPIOX_17 or a raw number)."

# --- tools ---------------------------------------------------------------------------------------
if ! command -v fdtget >/dev/null || ! command -v fdtput >/dev/null; then
  log "Installing device-tree-compiler (fdtget/fdtput)"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq device-tree-compiler
fi

# --- find the WiFi pwrseq node -------------------------------------------------------------------
NODE=""
for n in $(fdtget -l "$SRC_DTB" /); do
  if [[ "$(fdtget "$SRC_DTB" "/$n" compatible 2>/dev/null)" == "mmc-pwrseq-simple" ]]; then NODE="/$n"; break; fi
done
[[ -n "$NODE" ]] || die "No mmc-pwrseq-simple node in $SRC_DTB."

read -r -a CUR <<<"$(fdtget -t u "$SRC_DTB" "$NODE" reset-gpios)"
(( ${#CUR[@]} == 3 )) || die "Unexpected reset-gpios in $NODE: ${CUR[*]}"
PHANDLE="${CUR[0]}"; OLDNUM="${CUR[1]}"; FLAGS="${CUR[2]}"
log "Source: $SRC_DTB"
log "$NODE reset-gpios: GPIO $OLDNUM -> $NUM ($PIN), flags $FLAGS kept"

# --- build the patched copy ----------------------------------------------------------------------
install -d "$(dirname "$OUT")"
cp "$SRC_DTB" "$OUT"
fdtput -t u "$OUT" "$NODE" reset-gpios "$PHANDLE" "$NUM" "$FLAGS"
fdtput -t s "$OUT" / model "ZTE B860H (P212 DTB, WiFi power on $PIN)"
[[ "$(fdtget -t u "$OUT" "$NODE" reset-gpios)" == "$PHANDLE $NUM $FLAGS" ]] || die "Patch verification failed."
dtc -q -I dtb -O dts -o /dev/null "$OUT" || die "Patched DTB does not decompile cleanly."
log "Wrote $OUT"

# --- point extlinux at it ------------------------------------------------------------------------
grep -qE '^\s*fdt\s' "$EXTLINUX" || die "No 'fdt' line in $EXTLINUX."
[[ -f "$EXTLINUX.bak-b860h" ]] || cp "$EXTLINUX" "$EXTLINUX.bak-b860h"
sed -i -E "s#^(\s*fdt\s+).*#\1$OUT_REL#" "$EXTLINUX"
log "extlinux.conf now uses: $(grep -E '^\s*fdt\s' "$EXTLINUX" | xargs)"
log "Backup: $EXTLINUX.bak-b860h"

log "Reboot, then check:  cat /proc/device-tree/model; ls /sys/bus/sdio/devices/"
log "If the SDIO bus is still empty, try:  sudo $0 GPIOX_17   (then GPIOX_15)"
