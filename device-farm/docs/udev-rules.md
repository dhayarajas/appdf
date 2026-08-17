# Linux udev rules & ADB persistence

Linux hosts need udev rules so non-root users can talk to USB-attached Android
devices, and a few habits so the pool stays stable across reboots, cable
re-plugs and long test runs.

> No device is required to apply any of this. If `adb devices` is empty the
> device farm scaffold still runs and simply skips device-dependent tests.

## 1. Symptoms of missing rules

```console
$ adb devices
List of devices attached
????????????    no permissions (user in plugdev group; are your udev rules wrong?)
```

or the device appears only when `adb` is run under `sudo` — both mean the udev
rules are missing or the user is not in the right group.

## 2. Install the community rules (recommended)

```bash
sudo apt-get install -y android-sdk-platform-tools-common   # Debian/Ubuntu
# or pull the upstream list directly:
sudo curl -fsSL -o /etc/udev/rules.d/51-android.rules \
  https://raw.githubusercontent.com/M0Rf30/android-udev-rules/main/51-android.rules
sudo chmod 0644 /etc/udev/rules.d/51-android.rules
```

## 3. Or write a minimal rule

Find the vendor id with `lsusb` (the first four hex digits of `ID xxxx:yyyy`):

```console
$ lsusb
Bus 001 Device 007: ID 18d1:4ee7 Google Inc. Nexus/Pixel Device (debug)
```

Create `/etc/udev/rules.d/51-android.rules`:

```udev
# Google / Pixel
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0664", GROUP="plugdev", TAG+="uaccess"
# Samsung
SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0664", GROUP="plugdev", TAG+="uaccess"
# Xiaomi
SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0664", GROUP="plugdev", TAG+="uaccess"
# OnePlus
SUBSYSTEM=="usb", ATTR{idVendor}=="2a70", MODE="0664", GROUP="plugdev", TAG+="uaccess"
# Motorola
SUBSYSTEM=="usb", ATTR{idVendor}=="22b8", MODE="0664", GROUP="plugdev", TAG+="uaccess"
```

Common vendor ids: Google `18d1`, Samsung `04e8`, Xiaomi `2717`, OnePlus `2a70`,
Motorola `22b8`, Sony `0fce`, LG `1004`, Huawei `12d1`, Asus `0b05`,
Oppo/Realme `22d9`, Vivo `2d95`, Nothing `2d95`. The full upstream list is far
longer — prefer the community rules file above.

### Stable per-device names

Add a symlink keyed on serial so cabling changes do not shuffle identifiers:

```udev
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{serial}=="SERIAL123", SYMLINK+="android/pixel7-slot1", TAG+="uaccess"
```

## 4. Apply the rules

```bash
sudo groupadd -f plugdev
sudo usermod -aG plugdev "$USER"    # log out / back in (or: newgrp plugdev)
sudo udevadm control --reload-rules
sudo udevadm trigger
adb kill-server && adb start-server
adb devices -l
```

Verify a specific device's permissions:

```bash
udevadm info -a -n /dev/bus/usb/001/007 | head -n 30
```

## 5. ADB persistence & pool stability

**Authorize the host once, permanently.** On first connect the device shows an
RSA prompt — tick *Always allow from this computer*. The host key lives in
`~/.android/adbkey(.pub)`; back it up and reuse it across farm hosts so devices
do not need re-authorization:

```bash
export ADB_VENDOR_KEYS="$HOME/.android"   # extra keys adb should offer
```

**Keep the server alive.** A single `adb` server owns all devices. Run it as a
user-level service so it survives logout and restarts after a crash:

```ini
# ~/.config/systemd/user/adb.service
[Unit]
Description=ADB server for the mobile device farm
After=network.target

[Service]
Type=forking
Environment=ANDROID_HOME=%h/Android/Sdk
ExecStart=%h/Android/Sdk/platform-tools/adb -a start-server
ExecStop=%h/Android/Sdk/platform-tools/adb kill-server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now adb.service
loginctl enable-linger "$USER"     # keep the user service running without a session
```

**Device-side settings that prevent flakiness**

```bash
adb shell settings put global stay_on_while_plugged_in 3   # stay awake while charging
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell svc power stayon true
```

Also disable auto-updates and screen lock (no PIN/pattern) on farm devices, and
keep *Developer options → USB debugging* plus *Install via USB* enabled.

**Cabling / power**

- Use powered USB hubs; unpowered hubs cause `offline` devices under load.
- Prefer short, data-rated cables; most `device offline` churn is cable-related.
- For long-running farms, consider charge-limiting hubs (or `adb shell dumpsys
  battery set level 50`-style controls on rooted devices) to reduce battery
  swelling.

**Recover a wedged device**

```bash
adb devices                       # look for 'offline' / 'unauthorized'
adb -s <serial> reconnect         # soft reconnect
adb reconnect offline             # reconnect all offline devices
adb kill-server && adb start-server
sudo modprobe -r usb_storage 2>/dev/null; sudo udevadm trigger
# last resort, if the device answers at all:
adb -s <serial> reboot
```

**Wireless ADB (Android 11+)** avoids cable wear for stationary devices:

```bash
adb -s <serial> tcpip 5555
adb connect <device-ip>:5555
```

Wireless devices drop off when the Wi-Fi network flaps; the plugin's health
checks (see `config/appium-device-farm.config.json`) quarantine them until they
return.

## 6. Verifying without hardware

```bash
bash scripts/provision_host.sh --check    # reports "no Android devices attached" as a WARN
adb devices                               # empty list is fine
```

The scaffold treats an empty pool as a skip condition, so CI hosts need none of
the above.
