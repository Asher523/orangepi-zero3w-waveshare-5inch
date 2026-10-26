# Orange Pi Zero 3W (A733): HDMI connected but "no modes" — a `sunxi-hdmi` driver issue

> [中文版本](README.md)

## TL;DR

After the display is plugged in, the DRM connector reports `connected` and a valid 128-byte EDID (800×480@60.7), and the vendor driver's dmesg even says it parsed one supported mode (`drm get edid support modes: 1`). Yet the connector's `modes` list is empty and `enabled` is `disabled`, so Xorg aborts with `Output HDMI-1 enabled but has no modes` and `no screens found`.

**Root cause:** the vendor `sunxi-hdmi` driver parses the EDID but never registers the resulting mode(s) on the DRM connector. Userspace (Xorg's modesetting driver) therefore sees zero candidate modes and cannot bring up a screen.

**Workaround:** force a mode on the connector from the kernel command line — `extraargs=video=HDMI-A-1:800x480@60e` in `/boot/orangepiEnv.txt`, then reboot.

---

## 1. Environment

| Item | Value |
| --- | --- |
| Board | Orange Pi Zero 3W (Allwinner A733, DTB `sun60i-a733-orangepi-zero3w.dtb`) |
| OS | Orange Pi Ubuntu 22.04.5 LTS (Jammy), Cinnamon + LightDM |
| Kernel | `5.15.147-sun60iw2` (vendor BSP kernel, uses `sunxi-hdmi` / sunxi-drm) |
| Display | Waveshare 5inch HDMI LCD Rev 3.1, 800×480, 60.727 Hz, 37.0 MHz pixel clock |
| Connector | `card0-HDMI-A-1` (mini-HDMI Type-C on the board) |

## 2. Symptoms

Cabling and power were fine and the system booted normally, but the HDMI output had no usable mode and the desktop never came up.

```text
$ cat /sys/class/drm/card0-HDMI-A-1/status
connected

$ wc -c /sys/class/drm/card0-HDMI-A-1/edid
128 /sys/class/drm/card0-HDMI-A-1/edid

$ cat /sys/class/drm/card0-HDMI-A-1/modes
        # empty

$ cat /sys/class/drm/card0-HDMI-A-1/enabled
disabled
```

This already rules out cabling and the panel: **the full 128-byte EDID is readable**, so HPD/DDC work and the display correctly reports its capabilities. The problem lies between the kernel display driver and userspace.

Xorg's log agrees:

```text
(II) modeset(0): Output HDMI-1 connected
(II) modeset(0): No remaining probed modes for output HDMI-1
(EE) modeset(0): Output HDMI-1 enabled but has no modes
(EE) modeset(0): No modes.
(EE) Fatal server error:
(EE) no screens found
```

Xorg's modesetting driver does exactly what it should: connector present, no modes → no framebuffer → give up.

## 3. The key evidence: the driver knows a mode, userspace does not

The kernel log shows the vendor side looking healthy:

```text
[drm] sunxi-hdmi: drm hdmi detect: connect
[drm] hdmi edid only has block0 and parse finish
[drm] drm get edid support modes: 1
```

Note the last line — **the driver itself parsed one supported mode**. Yet the same connector's `modes` in sysfs is empty. The contradiction means the mode never travels the standard DRM `get_modes` path and is not registered on the connector.

The EDID mode itself is fine (DTD read from the same panel):

```text
800×480 @ 60.727 Hz
Pixel clock: 37.0 MHz
h: active 800, sync 848, sync_end 888, blank_end 1088
v: active 480, sync 483, sync_end 493, blank 560
```

So the display *does* report its mode — the driver just fails to pass it on to the system.

## 4. Things that did not work

| Attempt | Result |
| --- | --- |
| `echo on > /sys/kernel/debug/dri/0/HDMI-A-1/force` | Accepted, but `status` unchanged; writing `detect` returns `I/O error` |
| Vendor node `/sys/devices/virtual/hdmi/hdmi/attr/hpd_mask` (write `1`) | Logs `set hpd mask: 0x1`; status and mode list unchanged |
| Writing a standard 800×480 EDID into `edid_data` | Write succeeds, `modes` still empty |
| `drm_kms_helper.edid_firmware=...` | `CONFIG_DRM_LOAD_EDID_FIRMWARE` is not set (`# CONFIG_DRM_LOAD_EDID_FIRMWARE is not set`) |
| Restarting `lightdm` | Same `no screens found` |

These vendor debug knobs accept writes and log them, but they do not participate in actual mode enumeration.

## 5. Workaround: force a mode on the kernel command line

Since DRM cannot obtain a mode, make the kernel hand one to the connector during DRM initialisation. DRM's `video=` parameter supports connector-specific forced modes:

```text
video=HDMI-A-1:800x480@60e
```

The `e` suffix marks the mode as forced/enabled instead of negotiated from EDID.

Persist it through the U-Boot environment. `/boot/boot.cmd` (line 38) appends `extraargs` to the kernel `bootargs`:

```text
setenv bootargs "... ${extraargs} ${extraboardargs}"
```

So one line at the end of `/boot/orangepiEnv.txt` is enough:

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

Apply:

```bash
sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak
sudo sed -i 's/^extraargs=.*/extraargs=video=HDMI-A-1:800x480@60e/' /boot/orangepiEnv.txt
sync
sudo reboot
```

## 6. Verification

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

The Xorg log now shows:

```text
(II) modeset(0): Printing probed modes for output HDMI-1
(II) modeset(0): Output HDMI-1 using initial mode 800x480 +0+0
```

## 7. Caveats

- `video=` is **global for the connector**: HDMI-A-1 is pinned to 800×480, so any other monitor or capture card on that port is forced to 800×480 as well. Remove the line and reboot to get native resolution back.
- The forced `60` Hz does not exactly match the panel's EDID `60.727` Hz, but this panel accepts the CVT timing with a stable picture. If you see shimmer or offset, use the exact EDID value (`800x480@60.7`).
- This is a **workaround**, not a fix. The real fix belongs in `sunxi-hdmi`: after parsing EDID, register the mode(s) on the DRM connector (`get_modes` / `connector->modes`), otherwise no userspace can use the output.

## 8. Command cheat sheet

```bash
# Status/modes of all connectors
for c in /sys/class/drm/card*-*; do
  echo "== $c"
  cat "$c/status" "$c/enabled" "$c/modes" 2>/dev/null
done

# Was EDID actually read? (128 bytes = one block)
wc -c /sys/class/drm/card0-HDMI-A-1/edid

# HDMI/DRM kernel messages
dmesg | grep -iE 'sunxi-hdmi|edid|hpd|drm'

# First thing to read when X fails
grep -E 'EE|No modes|no screens' /var/log/Xorg.0.log

# Current kernel command line
cat /proc/cmdline

# Firmware-EDID fallback available?
zcat /proc/config.gz 2>/dev/null | grep CONFIG_DRM_LOAD_EDID_FIRMWARE
```

## 9. Suggestion for the vendor

The issue can be stated in one sentence: **when the HDMI connector is `connected` with a valid EDID, `sunxi-hdmi` must register the parsed mode(s) on the DRM connector so that `modes` is non-empty and userspace can enable the output.** Right now the driver log confirms successful parsing (`support modes: 1`) while the connector's mode list stays empty, leaving both Xorg and Wayland unable to use the output.

## References

- Kernel `video=` parameter (DRM connector forcing): `Documentation/framebuffer.txt`, `Documentation/gpu/drm-kms.rst`
- DRM connector mode reporting: `drm_connector->get_modes`
