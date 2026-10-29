# Orange Pi Zero 3W (A733): HDMI connected but "no modes" — a `sunxi-hdmi` driver issue

> [中文版本](README.md)

## TL;DR

After the display is plugged in, the DRM connector reports `connected` and a valid 128-byte EDID (800×480@60.7), and the vendor driver's dmesg even says it parsed one supported mode (`drm get edid support modes: 1`). Yet the connector's `modes` list is empty and `enabled` is `disabled`, so Xorg aborts with `Output HDMI-1 enabled but has no modes` and `no screens found`.

**Root cause:** the vendor `sunxi-hdmi` driver parses the EDID but never registers the resulting mode(s) on the DRM connector. Userspace (Xorg's modesetting driver) therefore sees zero candidate modes and cannot bring up a screen.

**Workaround:** force a mode on the connector from the kernel command line — `extraargs=video=HDMI-A-1:800x480@60e` in `/boot/orangepiEnv.txt`, then reboot.

**⚠️ Update (2026-10-27):** the `e` in `@60e` means `DRM_FORCE_ON`. On a panel whose DDC/HPD is dead, every connector probe then burns the full 620 ms I²C timeout and **the whole desktop drops to 3 fps**. If your panel's DDC reads nothing either, skip section 5 and read [section 10](#10-update-2026-10-27-the-hidden-cost-of-60e--the-whole-desktop-drops-to-3-fps), which uses an EDID override plus a delayed `force`.

---

## 1. Environment

| Item | Value |
| --- | --- |
| Board | Orange Pi Zero 3W (Allwinner A733, DTB `sun60i-a733-orangepi-zero3w.dtb`) |
| OS | Orange Pi Ubuntu 22.04.5 LTS (Jammy), XFCE + LightDM |
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

## 10. Update (2026-10-27): the hidden cost of `@60e` — the whole desktop drops to 3 fps

The workaround in section 5 does bring the picture up, but the **entire GUI runs at ~3 fps**: the pointer lags and video is a slideshow. The display, the refresh rate and thermals are all innocent — the `e` flag itself is the problem.

### 10.1 Ruled out first

| Suspect | Measurement | Verdict |
| --- | --- | --- |
| Refresh rate | DRM vblank sampled over 10 s = **60.037 Hz**, zero stalled windows | ruled out |
| Thermal throttling | 8 cores at 100% for 90 s peaked at **71 °C**; cpufreq cooling state stayed at 0 (trip point is 90 °C) | ruled out |
| Resolution / fill rate | mpv `--vo=null` **307 fps**; `--vo=x11` gives **3.2 fps** at both 800×480 and 160×120 | ruled out — independent of pixel count |
| Power | Same behaviour with independent and shared screen power | ruled out |

The giveaway: **160×120 is exactly as slow as 800×480**, so the bottleneck is a fixed stall in front of every frame, not the amount being drawn.

### 10.2 Xorg's main thread is stuck in I²C

```bash
$ sudo cat /proc/$(pgrep -x Xorg)/wchan
_dw_i2cm_read          # 10/10 samples idle, 10/10 while playing video

$ sudo cat /proc/$(pgrep -x Xorg)/stack
_dw_i2cm_read
dw_i2cm_xfer
sunxi_hdmi_i2cm_xfer
__i2c_transfer
drm_do_probe_ddc_edid      ← reading EDID
drm_do_get_edid
drm_get_edid
_sunxi_drv_hdmi_read_edid
_sunxi_drv_hdmi_hpd_plugin
_sunxi_drm_hdmi_force
drm_helper_probe_single_connector_modes
drm_mode_getconnector       ← from DRM_IOCTL_MODE_GETCONNECTOR
```

Every time Xorg asks "what's on this connector?", the driver performs a real EDID read over DDC.

### 10.3 Root cause: `e` means `DRM_FORCE_ON`

```bash
$ sudo cat /sys/kernel/debug/dri/0/HDMI-A-1/force
on
```

The `e` in `video=HDMI-A-1:800x480@60e` sets the connector to `DRM_FORCE_ON`. With force active, `drm_helper_probe_single_connector_modes()` invokes the driver's `->force()` callback on every probe. When DDC answers, that is merely slow; when DDC is dead (`i2cget -y 20 0x50 0x00` returns `Read failed`), every read burns the full timeout:

```text
single forced probe: 620.2 ms   (cached probe right after: 0.0 ms)
per 10 s: 15 × "detect hpd", 28 × "edid failed", 15 × "force hpd"
```

15/10 = 1.5 probes per second and 1/0.62 ≈ 1.6 — Xorg is doing nothing else, and every frame waits behind hundreds of milliseconds.

### 10.4 Current approach: three layers, one problem each

1. `edid_override` (debugfs) is fed a real EDID, so the kernel never touches DDC — kills the 620 ms stall
2. `force=on` keeps the connector `connected` — covers flaky HPD
3. `/etc/X11/xorg.conf.d/20-hdmi-800x480.conf` carries a Modeline — covers the driver never registering a mode

Layer 3 was added on 2026-10-29; see [10.8](#108-2026-10-29-the-boot-that-came-back-dark).

The EDID was captured from a laptop that recognises this panel fine:

```text
vendor ADA   800×480 @ 37.000 MHz   htotal 1088 / vtotal 560 ≈ 60.73 Hz
```

**`scripts/800x480.edid` is only valid for this exact panel.** A different panel — even another unit of the same model — needs its own dump, otherwise you are feeding the kernel someone else's timing. Dump it on any machine that recognises the panel (a Linux laptop/desktop works):

```bash
# find the connector that is actually connected
for c in /sys/class/drm/card*-*; do
    [ "$(cat $c/status)" = connected ] && echo "$c  $(wc -c < $c/edid) bytes"
done

# 128 bytes = one EDID block
sudo cat /sys/class/drm/card0-DP-1/edid > mypanel.bin
```

On Windows, Monitor Asset Manager or `Get-WmiObject WmiMonitorDescriptorMethods` will do. Replace `scripts/800x480.edid` with your dump and update the `xrandr --newmode` timings in `~/.xsessionrc` to match its DTD.

**⚠️ The older rule "write `force=on` only after the desktop session is up" no longer applies** — see 10.8. The unit is now `Before=lightdm.service` and writes both knobs before X starts.

```bash
sudo ./scripts/install.sh
```

### 10.5 Result

| | Before | After |
| --- | --- | --- |
| Rendering (mpv `--vo=x11`, 800×480) | 3.1 fps | 56–80 fps |
| `edid failed` per 10 s | 28 | 0 |
| `force hpd` per 10 s | 15 | 0 |
| Single forced probe | 620 ms | never triggered |

### 10.6 Rollback

```bash
sudo systemctl disable --now hdmi-edid-override
sudo rm /etc/X11/xorg.conf.d/20-hdmi-800x480.conf
rm ~/.xsessionrc
sudo reboot
```

### 10.7 Additional suggestions for the vendor

- The `->force()` path should not read DDC unconditionally; a failed EDID read should be cached and backed off instead of retried for 620 ms on every probe
- A synchronous I²C transfer inside the `GETCONNECTOR` path blocks userspace's main loop; make it asynchronous or cached
- `CONFIG_DRM_LOAD_EDID_FIRMWARE` is not enabled — enabling it would at least give users a firmware-EDID fallback (today only debugfs `edid_override` works)

### 10.8 2026-10-29: the boot that came back dark

**Symptom**: black screen at boot. `lightdm` is `failed` with `NRestarts=32`; the override service logged exactly one line:

```text
waited 60 seconds, no desktop session, giving up
```

**What the box actually looked like**:

```text
HDMI-A-1: connected          ← this time DDC worked
edid: 128 bytes              ← EDID readable
modes: []                    ← yet still no mode registered (the section 5 bug)
Xorg: (EE) Output HDMI-1 enabled but has no modes → no screens found
```

**Deadlock**: the old script assumed Xorg comes up first, then EDID/force is applied. But with the connector reporting `connected`, Xorg aborts immediately on "connected but zero modes" → no session → the script times out and writes nothing → permanently black. **The design depended on a circular precondition that breaks whenever the connector state changes.**

(Why it survived on 10-27 is no longer recoverable — not enough logs were kept. What is certain is that it was never a sound design.)

**Fix — solve the missing-mode half head-on instead of routing around it**:

```ini
# /etc/X11/xorg.conf.d/20-hdmi-800x480.conf
Section "Monitor"
    Identifier  "HDMI-1"
    Option      "Enable" "true"
    Option      "PreferredMode" "800x480_60r"
    Modeline    "800x480_60r" 37.000 800 848 888 1088 480 483 493 560 -HSync -VSync
EndSection

Section "Device"
    Identifier  "modesetting"
    Driver      "modesetting"
EndSection
```

With that Modeline, Xorg no longer consults the driver's permanently empty mode list, so `force=on` can safely be written **before** X starts (`Before=lightdm.service`) and the circular dependency is gone.

**Recovery without rebooting** (screen dark but SSH alive):

```bash
S=/sys/kernel/debug/dri/0/HDMI-A-1
sudo sh -c "cat /etc/hdmi-edid/800x480.bin > $S/edid_override; echo on > $S/force"
sudo systemctl reset-failed lightdm && sudo systemctl start lightdm
# start it once only; if it does not come up, systemctl stop lightdm before it loops
```

Note: writing `edid_override` does not refresh the `modes` in sysfs (that is the last probe's cache, and this driver never fills it anyway). Don't judge success by `cat modes` — judge it by whether Xorg starts.

### 10.9 What is verified, and what is not

**Verified** by an actual reboot on 2026-10-29:

- the service ran before lightdm and wrote `edid_override` + `force=on` ahead of X
- lightdm `NRestarts=0`; output `800x480_60r 60.73*`
- `edid failed` count in `dmesg`: 0 (no regression to 3 fps)

**Not covered**: on that boot the connector reported `connected` (DDC working). **The case where HPD is fully dead and the connector comes up `disconnected` has not been exercised** — it relies on the same service writing `force=on` before X, which is sound in principle but untested here. This panel's hardware state drifts between the two (10-27 it was `disconnected`, 10-29 it was `connected`), so it cannot be assumed stable.

**A dark screen is not a dead box**: SSH is independent of display, so the three lines in 10.8 recover it without touching the hardware.

## References

- Kernel `video=` parameter (DRM connector forcing): `Documentation/framebuffer.txt`, `Documentation/gpu/drm-kms.rst`
- DRM connector mode reporting: `drm_connector->get_modes`
