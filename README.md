# hg680p-wifi

A script that gets the **onboard WiFi working on the HG680P** Android TV box (Amlogic S905X) when it runs **Armbian with ophub kernels**.

## Quick start

Run this on the box (needs internet over Ethernet):

```bash
# Install the driver only
curl -fsSL https://raw.githubusercontent.com/duskoide/hg680p-wifi/master/setup-wifi-hg680p.sh | sudo bash

# Install the driver and connect to a network
curl -fsSL https://raw.githubusercontent.com/duskoide/hg680p-wifi/master/setup-wifi-hg680p.sh | sudo bash -s -- "MySSID" "password"

# With environment overrides (put them after sudo, or sudo drops them)
curl -fsSL https://raw.githubusercontent.com/duskoide/hg680p-wifi/master/setup-wifi-hg680p.sh | sudo FORCE=1 bash
```

If you'd rather read the script before running it:

```bash
curl -fsSLO https://raw.githubusercontent.com/duskoide/hg680p-wifi/master/setup-wifi-hg680p.sh
less setup-wifi-hg680p.sh
sudo bash setup-wifi-hg680p.sh
```

## What is it?

The HG680P's onboard WiFi chip is a **Realtek RTL8189FTV** (SDIO ID `024c:f179`). ophub Armbian kernels don't include a driver for this chip. Some of them also load the unrelated `aic8800_sdio` driver, which doesn't work with this chip. As a result, the box has no `wlan0`.

`setup-wifi-hg680p.sh` fixes this. It:

1. Checks that the RTL8189FTV is present on the SDIO bus.
2. Builds the out-of-tree **`8189fs`** driver ([jwrdegoede/rtl8189ES_linux](https://github.com/jwrdegoede/rtl8189ES_linux), branch `rtl8189fs`) against the **running kernel's headers**.
3. Patches the driver source for changes to the cfg80211 API. ophub kernels backport newer cfg80211 APIs, so the driver's `LINUX_VERSION_CODE` checks pick the wrong code. The script reads the real function signatures from `cfg80211.h` and switches to the code paths that match.
4. Installs the module, runs `depmod`, and loads it.
5. Writes boot config so WiFi keeps working after a reboot:
   - `/etc/modules-load.d/8189fs.conf`: loads `8189fs` at boot
   - `/etc/modprobe.d/blacklist-aic8800-sdio.conf`: blacklists `aic8800_sdio_bsp` and `aic8800_sdio_wlan`
   - `/etc/modprobe.d/8189fs.conf`: `rtw_power_mgnt=0 rtw_enusbss=0` (turns off power saving for stability). This file is only written if no `options 8189fs` line exists yet.
   - `/etc/NetworkManager/conf.d/99-unmanage-wlan1.conf`: tells NetworkManager to ignore `wlan1`, the driver's virtual second interface
6. Optionally connects to a WiFi network with NetworkManager (`nmcli`).

## Requirements

- An HG680P (or another box with an RTL8189FTV on SDIO) running **aarch64** Armbian
- **Kernel headers that match the running kernel** at `/lib/modules/$(uname -r)/build`. ophub images normally ship them in `/usr/src/linux-headers-<version>`.
- **Internet access** through Ethernet (or USB tethering, etc.). The script clones the driver from GitHub and may install build tools with `apt-get` (`build-essential git bc flex bison perl`).
- Root privileges
- NetworkManager (optional). The connect step needs it. Without it, the driver is still installed.

## Usage

```bash
chmod +x setup-wifi-hg680p.sh

# Install the driver only
sudo ./setup-wifi-hg680p.sh

# Install the driver and connect to a network
sudo ./setup-wifi-hg680p.sh "MySSID" "password"

# Open network (no password)
sudo ./setup-wifi-hg680p.sh "MySSID"
```

The build takes about **10–15 minutes** on the S905X. When it finishes, `wlan0` should be up. If you passed an SSID, the box should also be connected.

To connect later or switch networks:

```bash
sudo nmcli dev wifi connect "SSID" password "PASS" ifname wlan0
```

### Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `DRIVER_REPO` | `https://github.com/jwrdegoede/rtl8189ES_linux.git` | Driver source repo |
| `DRIVER_BRANCH` | `rtl8189fs` | Branch to build |
| `BUILD_DIR` | `/usr/local/src/rtl8189fs` | Build directory (**deleted and re-cloned** on every build) |
| `FORCE` | `0` | `1` skips the chip-ID check and rebuilds even if the module is already installed |

Example:

```bash
sudo FORCE=1 ./setup-wifi-hg680p.sh
```

### After a kernel update

The module only works with the kernel it was built against. After `armbian-update` or any other kernel change, **run the script again**. It detects that no module exists for the new kernel and rebuilds it.

## What it can do

- Detect the RTL8189FTV and refuse to run on other hardware unless you set `FORCE=1`
- Install missing build tools automatically on apt-based systems
- Adapt the driver to cfg80211 API changes that ophub kernels backport (wireless_dev-based key/station ops, `rx_addr` in `remain_on_channel`, cookies passed by value)
- Keep WiFi working across reboots
- Run again safely: if the module for the current kernel is already installed, it skips the build and only rewrites the config and reloads the driver
- Retry the scan and connect steps a few times, since the chip can be slow to see networks right after the driver loads

## What it can't do / limitations

- **No DKMS.** The module is not rebuilt automatically when the kernel changes. You have to run the script again by hand.
- **No uninstall option.** See [Uninstalling](#uninstalling) below.
- **It doesn't install kernel headers.** If they're missing, the script stops and tells you to install the matching headers package.
- **aarch64 only.** It targets the HG680P / S905X and refuses to run on other architectures.
- **Only fixes cfg80211 changes it knows about.** The patching edits specific `KERNEL_VERSION(...)` guards in the upstream driver. Future kernel API changes, or changes to the upstream driver, can still break the build. If that happens, check `$BUILD_DIR/build.log`.
- **It doesn't detect an outdated module.** If `8189fs.ko` already exists for the running kernel, it isn't rebuilt, even if the upstream driver has fixes. Use `FORCE=1` to rebuild.
- **Only connects through NetworkManager.** With wpa_supplicant/ifupdown, systemd-networkd, etc., the script installs the driver but you have to configure `wlan0` yourself (or use `armbian-config`).
- **Simple WPA-PSK or open networks only.** There's no support for WPA-Enterprise, hidden SSIDs, static IPs, or choosing a specific band or BSSID. Use `nmcli` directly for those.
- **The WiFi password is passed as a command-line argument**, so it ends up in your shell history and is briefly visible in the process list. If that matters, run the script without arguments and connect with `nmcli --ask dev wifi connect "SSID" ifname wlan0`.
- **Power saving is turned off** (`rtw_power_mgnt=0`). This is more stable but uses slightly more power.
- **Performance is limited by the hardware.** The RTL8189FTV is a 2.4 GHz-only, 1x1 802.11n chip. Don't expect high throughput, and don't expect AP or monitor mode to work well with this driver.
- **It overwrites its own config files** in `/etc/modprobe.d`, `/etc/modules-load.d` and `/etc/NetworkManager/conf.d` on every run, except `8189fs.conf` if it already has options.

## Troubleshooting

- **`RTL8189FTV (SDIO 024c:f179) not found`**: Check `cat /sys/bus/sdio/devices/*/{vendor,device}`. The SDIO controller may be disabled in your device tree (DTB), or this may not be an HG680P.
- **`Kernel headers ... not found`**: Install the headers that match `uname -r`.
- **Build failed**: The script prints the first errors. The full log is in `/usr/local/src/rtl8189fs/build.log`.
- **`wlan0 did not appear`**: Run `dmesg | grep -i rtw` and `lsmod | grep -E '8189fs|aic8800'`.
- **Can't connect**: Run `nmcli dev wifi list ifname wlan0` to check that the SSID is visible, and double-check the password.

## Uninstalling

```bash
sudo modprobe -r 8189fs
sudo rm -f /lib/modules/*/kernel/drivers/net/wireless/realtek/8189fs.ko
sudo rm -f /etc/modules-load.d/8189fs.conf \
           /etc/modprobe.d/8189fs.conf \
           /etc/modprobe.d/blacklist-aic8800-sdio.conf \
           /etc/NetworkManager/conf.d/99-unmanage-wlan1.conf
sudo rm -rf /usr/local/src/rtl8189fs
sudo depmod -a
```
