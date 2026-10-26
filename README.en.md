# Orange Pi Zero 3W + Waveshare 5inch HDMI LCD — Black Screen Debugging Log

> [中文版本](README.md)

A Waveshare 5inch HDMI LCD (800×480) stayed black on an Orange Pi Zero 3W (Allwinner A733). After chasing the wrong suspects for a while, two unrelated faults turned out to be stacked on top of each other: a bad mini-HDMI adapter **and** a vendor DRM driver that never handed the parsed EDID mode to userspace. This is the full trail, including the dead ends.

## TL;DR

1. The first **mini-HDMI (Type-C) adapter did not pass HPD/DDC**, so the kernel reported `drm hdmi detect: disconnect` and read zero EDID bytes. A known-good adapter gave `detect: connect` and one parsed mode.
2. The vendor `sunxi-hdmi`/sunxi-drm driver parsed the EDID mode (`drm get edid support modes: 1`) but **never exposed it through the DRM connector**, so Xorg aborted with `No remaining probed modes for output HDMI-1` and `no screens found`. Debugfs `force`, the vendor `hpd_mask` knob, and writing a standard EDID to `edid_data` all had no effect; `CONFIG_DRM_LOAD_EDID_FIRMWARE` is not set, so the `drm_kms_helper.edid_firmware` fallback was unavailable too.
3. **Fix:** add `extraargs=video=HDMI-A-1:800x480@60e` to `/boot/orangepiEnv.txt` and reboot. `extraargs` is folded into the kernel `bootargs` by `/boot/boot.cmd`. The connector then reports `modes: 800x480`, `enabled=enabled`, `fb0` exists, and Xorg starts with `using initial mode 800x480 +0+0`.

## 1. Environment

| Item | Value |
| --- | --- |
| Board | Orange Pi Zero 3W (Allwinner A733, DTB `sun60i-a733-orangepi-zero3w.dtb`) |
| OS | Orange Pi Ubuntu 22.04.5 LTS (Jammy, "Orange Pi 1.0.0"), Cinnamon, LightDM |
| Kernel | `5.15.147-sun60iw2` (vendor BSP kernel with `sunxi-hdmi` / eDP drivers) |
| Display | Waveshare **5inch HDMI LCD Rev 3.1** (SKU 10563), 800×480, XPT2046 resistive touch over SPI |
| Video port | The board has **mini-HDMI (Type-C)**, not micro-HDMI |
| Power | Separate `Power Only` micro-USB to the display; backlight switch set to ON |
| Cross-check rig | Laptop (Linux) + USB-C dock + mini-HDMI→HDMI adapter + HDMI capture card |

> The tiny HDMI port on the board is **mini-HDMI (Type-C)**. It is easy to assume micro-HDMI and buy the wrong adapter — one that either does not fit or has the wrong pinout.

## 2. Symptoms

The board booted fine (SSH worked, `lightdm` was running), but the display stayed completely dark — no backlight either. The kernel could only say:

```text
[drm] sunxi-hdmi: drm hdmi detect: disconnect
```

`/sys/class/drm/card0-HDMI-A-1/status` was `disconnected` and `edid` was 0 bytes.

Two very different states showed up during the investigation, and they deserve to be kept apart:

- **State A** — `disconnect`, empty EDID: a connectivity problem.
- **State B** — `connect`, EDID parsed, but `modes` empty and Xorg fails: a driver/userspace problem.

The screen only lit up once **both** were dealt with.

## 3. Investigation

### 3.1 What does the kernel actually see?

```bash
# Connector status / EDID / registered modes
cat /sys/class/drm/card0-HDMI-A-1/status
wc -c /sys/class/drm/card0-HDMI-A-1/edid
cat /sys/class/drm/card0-HDMI-A-1/modes

# Vendor driver probe messages
dmesg | grep -iE 'sunxi-hdmi|hdmi|edid|drm'
```

Output before anything was fixed:

```text
disconnected
0 /sys/class/drm/card0-HDMI-A-1/edid
```

and:

```text
[drm] sunxi-hdmi: drm hdmi detect: disconnect
```

So either HPD (hot-plug detect) never reached the SoC, or the DDC channel was dead — the driver never even tried to read the EDID.

First, rule out the display itself:

- The panel has its own `Power Only` micro-USB; the backlight switch must be ON. If the backlight is dark, **check this first** — it is independent of the video signal.
- Try a known-good mini-HDMI cable on the board.

### 3.2 Cross-check: plug the same panel into the laptop

Connected to the laptop through a USB-C dock (DP Alt Mode), the panel was recognised immediately. Its EDID:

```text
Manufacturer: ADA
Product: 4
Size: 15 cm x 9 cm
800x480 @ 60.727 Hz
Pixel clock: 37.0 MHz
DTD: h_active 800, h_sync 848, h_sync_end 888, h_blank_end 1088
     v_active 480, v_sync 483, v_sync_end 493, v_blanking 560
```

So **the panel and its EDID are fine**. The fault is on the Orange Pi side: cabling or driver.

For completeness, the board → mini-HDMI → HDMI capture card → PC chain also produced a picture, proving the board's HDMI output itself works. That narrowed the suspects to the adapter and the driver.

### 3.3 Problem 1: the mini-HDMI adapter does not pass HPD/DDC

With a known-good mini-HDMI→HDMI adapter, the kernel state changed immediately:

```text
[drm] sunxi-hdmi: drm hdmi detect: connect
[drm] hdmi edid only has block0 and parse finish
[drm] drm get edid support modes: 1
```

`status` became `connected` and the EDID was now 128 bytes.

**Root cause #1:** the cheap adapter did not connect (or intermittently connected) the HPD and DDC (I²C) lines. Without HPD the driver thinks nothing is plugged in; without DDC it can detect the display but cannot read its EDID. Such adapters may still "work" in setups that only need the video lanes, but they fall over whenever EDID negotiation matters.

### 3.4 Problem 2: the driver parses a mode but userspace never gets it

After `connect`, the screen was still black. The state was now:

```text
$ cat /sys/class/drm/card0-HDMI-A-1/status
connected

$ cat /sys/class/drm/card0-HDMI-A-1/modes
        # empty

$ cat /sys/class/drm/card0-HDMI-A-1/enabled
disabled
```

Xorg's log nailed it down:

```text
(II) modeset(0): Output HDMI-1 connected
(II) modeset(0): No remaining probed modes for output HDMI-1
(EE) modeset(0): Output HDMI-1 enabled but has no modes
(EE) modeset(0): No modes.
(EE) Fatal server error:
(EE) no screens found
```

The driver log says `drm get edid support modes: 1` — it parsed a mode — yet the DRM connector's `modes` list is empty and `enabled` is `disabled`. In other words, the vendor `sunxi-hdmi` driver **parsed the EDID but never registered the resulting mode(s) on the DRM connector`, so the `get_modes` path hands userspace nothing. The Xorg modesetting driver cannot build a framebuffer without a mode and bails out with `no screens found`.

Worth checking the kernel config too — if `CONFIG_DRM_LOAD_EDID_FIRMWARE` is enabled, a firmware EDID can be used as a fallback:

```bash
zcat /proc/config.gz | grep DRM_LOAD_EDID_FIRMWARE
```

Result on this board:

```text
# CONFIG_DRM_LOAD_EDID_FIRMWARE is not set
```

so `drm_kms_helper.edid_firmware=HDMI-A-1:edid/800x480.bin` was not an option either.

### 3.5 Things that did *not* work (so you don't repeat them)

| Attempt | Result |
| --- | --- |
| `echo on > /sys/kernel/debug/dri/0/HDMI-A-1/force` | Accepted, but `status` stayed `disconnected` / no modes; writing `detect` returned `I/O error` |
| Vendor node `/sys/devices/virtual/hdmi/hdmi/attr/hpd_mask` (write `1`) | Logged `set hpd mask: 0x1`, connector unchanged |
| Writing a standard 800×480 EDID into `edid_data` | Write succeeded, `modes` still empty |
| `drm_kms_helper.edid_firmware=...` | `CONFIG_DRM_LOAD_EDID_FIRMWARE` not set |
| Restarting `lightdm` repeatedly | Same `no screens found` |

On this driver version, these vendor knobs are essentially decorative: the writes are accepted and logged, but they do not participate in actual mode enumeration.

### 3.6 What actually works: force a mode on the kernel command line

Since DRM cannot obtain a mode, make the kernel **seed the connector with one** while initialising DRM. DRM's `video=` parameter accepts a connector-specific forced mode:

```text
video=HDMI-A-1:800x480@60e
```

The `e` suffix marks it as a forced/preferred mode rather than something to negotiate from EDID.

Persist it through U-Boot's environment. Orange Pi's `/boot/boot.cmd` (line 38) appends `extraargs` to `bootargs`:

```text
setenv bootargs "... ${extraargs} ${extraboardargs}"
```

So a single line in `/boot/orangepiEnv.txt` is enough:

```ini
verbosity=7
bootlogo=true
overlay_prefix=sun60i-a733
fdtfile=allwinner/sun60i-a733-orangepi-zero3w.dtb
rootdev=UUID=00e06de9-df31-4083-84f1-7894aa14f992
rootfstype=ext4
overlays=i2c0 spi3-cs0-cs1-spidev
extraargs=video=HDMI-A-1:800x480@60e
```

Back up before editing:

```bash
sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak
sudo sed -i 's/^extraargs=.*/extraargs=video=HDMI-A-1:800x480@60e/' /boot/orangepiEnv.txt
sync
sudo reboot
```

## 4. Verification

After the reboot, check all three:

```bash
# 1. The kernel command line carries the parameter
cat /proc/cmdline | grep -o 'video=[^ ]*'
# video=HDMI-A-1:800x480@60e

# 2. The connector has a mode and is enabled
cat /sys/class/drm/card0-HDMI-A-1/status     # connected
cat /sys/class/drm/card0-HDMI-A-1/modes      # 800x480
cat /sys/class/drm/card0-HDMI-A-1/enabled    # enabled

# 3. Framebuffer and X are up
ls /dev/fb0
systemctl is-active lightdm                  # active
```

The Xorg log now says:

```text
(II) modeset(0): Printing probed modes for output HDMI-1
(II) modeset(0): Output HDMI-1 using initial mode 800x480 +0+0
```

The screen lights up and the desktop comes up normally.

## 5. Caveats

- **`video=HDMI-A-1:800x480@60e` pins the HDMI-A-1 connector to 800×480.** A different monitor, TV, or capture card on that port will also be forced to 800×480. Remove the line (or target a different connector name) to get native resolution back.
- The forced `60` Hz does not exactly match the panel's EDID `60.727` Hz, but this panel accepts the CVT timing with a stable, correctly framed picture. If you see shimmer or offset, try the exact EDID value (`800x480@60.7`, i.e. ≈60.729 Hz from the DTD).
- This is a **workaround**, not a driver fix. The proper fix is to register the EDID-derived mode on the DRM connector in `sunxi-hdmi`'s `get_modes`/EDID path, then report it to Orange Pi / upstream.

## 6. Side note: USB-C DP Alt Mode is broken too

The same panel through the board's USB-C port (with a dock) **is detected, but link training fails**:

```text
card0-DP-1: connected        # sink is recognised
```

dmesg shows the eDP-over-Type-C link never comes up:

```text
[EDP_ERR]: swing voltage reach max level, training1(clock recovery training) fail!
edp's combo-phy not setting, maybe not used!
get aux_p pull external up/down pin for phy mux failed, may be useless!
edp_lane_rate not set manually, set to default: 2.7G!
edp_lane_cnt not set manually, set to default: 2!
```

The SoC's eDP controller is being reused for DP Alt Mode, but the PHY muxing is misconfigured (the AUX pull pins cannot be acquired, the combo-PHY is not set up), and link training dies during clock recovery. The 2.7 Gbps × 2 lane defaults do not help. This looks like a vendor BSP limitation; I did not pursue it — **HDMI is the way to go**.

## 7. Command cheat sheet

```bash
# List all DRM connectors with status/modes
for c in /sys/class/drm/card*-*; do
  echo "== $c"
  cat "$c/status" "$c/enabled" "$c/modes" 2>/dev/null
done

# Was EDID actually read? (128 bytes = one block)
wc -c /sys/class/drm/card0-HDMI-A-1/edid

# HDMI-related kernel messages
dmesg | grep -iE 'sunxi-hdmi|edid|hpd|drm'

# The first thing to read when X fails
grep -E 'EE|No modes|no screens' /var/log/Xorg.0.log

# Current kernel command line
cat /proc/cmdline

# Firmware-EDID fallback available?
zcat /proc/config.gz 2>/dev/null | grep CONFIG_DRM_LOAD_EDID_FIRMWARE
```

## 8. TODO

- **Touch**: the XPT2046 talks SPI and needs the 26-pin header plus an overlay (`orangepiEnv.txt` already has `spi3-cs0-cs1-spidev`, but the XPT2046 driver/calibration is not configured yet).
- **Rotation/scale**: small panels usually need `xrandr --scale` or a suitable `video=` geometry for a usable desktop.
- **Report upstream**: `sunxi-hdmi` not exposing a mode when `connect` + valid EDID is a BSP bug worth filing.

## References

- Waveshare 5inch HDMI LCD documentation: <https://docs.waveshare.net/5inch_HDMI_LCD>
- Kernel `video=` parameter (DRM connector forcing): `Documentation/framebuffer.txt`, `Documentation/gpu/drm-kms.rst`
- Photo: `waveshare-5inch-back.jpg` (display back: HDMI, `Power Only` micro-USB, touch FPC)
