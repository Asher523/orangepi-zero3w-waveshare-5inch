# 香橙派 Zero 3W（A733）：HDMI 已连接却"没有可用模式"——厂商 `sunxi-hdmi` 驱动问题

> [English version](README.en.md)

## TL;DR

屏幕接上后，DRM 连接器状态是 `connected`、EDID 也读得到（128 字节，800×480@60.7），厂商驱动的 dmesg 甚至明确说解析出了 1 个模式（`drm get edid support modes: 1`），但连接器的 `modes` 列表为空、`enabled=disabled`，Xorg 直接报 `Output HDMI-1 enabled but has no modes` / `no screens found`。

**根因**：厂商 `sunxi-hdmi` 驱动把 EDID 解析出来了，却没有把得到的模式注册到 DRM 连接器上，用户空间（Xorg 的 modesetting 驱动）拿不到任何候选分辨率，于是无法建立屏幕。

**绕过**：在内核命令行里强制给这个连接器一个模式——`extraargs=video=HDMI-A-1:800x480@60e`（写在 `/boot/orangepiEnv.txt`），重启后即可出图。

---

## 1. 环境

| 项目 | 值 |
| --- | --- |
| 单板 | Orange Pi Zero 3W（Allwinner A733，DTB `sun60i-a733-orangepi-zero3w.dtb`） |
| 系统 | Orange Pi 官方 Ubuntu 22.04.5 LTS（Jammy），Cinnamon + LightDM |
| 内核 | `5.15.147-sun60iw2`（厂商 BSP 内核，使用 `sunxi-hdmi` / sunxi-drm） |
| 屏幕 | Waveshare 5inch HDMI LCD Rev 3.1，800×480，60.727 Hz，像素时钟 37.0 MHz |
| 连接器 | `card0-HDMI-A-1`（板上为 mini-HDMI Type-C 口） |

## 2. 现象

接线正常、屏幕供电正常、系统正常启动，但 HDMI 输出没有任何可用模式，桌面起不来。

```text
$ cat /sys/class/drm/card0-HDMI-A-1/status
connected

$ wc -c /sys/class/drm/card0-HDMI-A-1/edid
128 /sys/class/drm/card0-HDMI-A-1/edid

$ cat /sys/class/drm/card0-HDMI-A-1/modes
        # 空

$ cat /sys/class/drm/card0-HDMI-A-1/enabled
disabled
```

这一步已经可以排除线材和屏幕本身：**EDID 能完整读出 128 字节**，说明 HPD/DDC 通路是好的，屏也正常上报了自己的能力。问题出在内核显示驱动到用户空间这一段。

Xorg 日志与之对应：

```text
(II) modeset(0): Output HDMI-1 connected
(II) modeset(0): No remaining probed modes for output HDMI-1
(EE) modeset(0): Output HDMI-1 enabled but has no modes
(EE) modeset(0): No modes.
(EE) Fatal server error:
(EE) no screens found
```

Xorg 的 modesetting 驱动做得很标准：连接器连上了、但没有模式 → 无法创建 framebuffer → 放弃启动。

## 3. 关键证据：驱动知道模式，用户空间不知道

内核日志显示厂商驱动这一侧一切正常：

```text
[drm] sunxi-hdmi: drm hdmi detect: connect
[drm] hdmi edid only has block0 and parse finish
[drm] drm get edid support modes: 1
```

注意最后一行——**驱动自己解析出了 1 个支持的模式**。但同一个连接器在 sysfs 里的 `modes` 是空的。两边矛盾，说明模式在驱动内部解析完之后没有走到 DRM 的标准 `get_modes` 路径上，没有被注册进连接器的模式列表。

EDID 里的模式本身也没有问题（从同一块屏读到的 DTD）：

```text
800×480 @ 60.727 Hz
Pixel clock: 37.0 MHz
h: active 800, sync 848, sync_end 888, blank_end 1088
v: active 480, sync 483, sync_end 493, blank 560
```

所以这不是「显示器不报告」，而是「驱动报告给了自己，没报告给系统」。

## 4. 试过但无效的办法

| 方法 | 结果 |
| --- | --- |
| `echo on > /sys/kernel/debug/dri/0/HDMI-A-1/force` | 写入被接受，但 `status` 不变；写 `detect` 直接返回 `I/O error` |
| 厂商节点 `/sys/devices/virtual/hdmi/hdmi/attr/hpd_mask`（写 `1`） | 日志 `set hpd mask: 0x1`，连接器状态、模式列表均无变化 |
| 往 `edid_data` 写一份标准 800×480 EDID | 写入成功，`modes` 仍为空 |
| `drm_kms_helper.edid_firmware=...` | 内核未启用 `CONFIG_DRM_LOAD_EDID_FIRMWARE`（`# CONFIG_DRM_LOAD_EDID_FIRMWARE is not set`），此路不通 |
| 重启 `lightdm` | 一样 `no screens found` |

这些厂商私有的调试开关能写、能打日志，但不参与实际的模式枚举，对这个问题没有作用。

## 5. 绕过办法：内核命令行强制模式

既然 DRM 层拿不到模式，就让内核在初始化 DRM 时直接给连接器指定一个。DRM 的 `video=` 参数支持按连接器名强制模式：

```text
video=HDMI-A-1:800x480@60e
```

`e` 后缀表示强制（启用）该模式，不依赖 EDID 协商。

持久化到 U-Boot 环境。`/boot/boot.cmd` 第 38 行会把 `extraargs` 拼进内核 `bootargs`：

```text
setenv bootargs "... ${extraargs} ${extraboardargs}"
```

因此在 `/boot/orangepiEnv.txt` 末尾加一行即可：

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

操作：

```bash
sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak
sudo sed -i 's/^extraargs=.*/extraargs=video=HDMI-A-1:800x480@60e/' /boot/orangepiEnv.txt
sync
sudo reboot
```

## 6. 验证

```bash
# 1. 内核命令行吃到了参数
cat /proc/cmdline | grep -o 'video=[^ ]*'
# video=HDMI-A-1:800x480@60e

# 2. 连接器有模式、已启用
cat /sys/class/drm/card0-HDMI-A-1/status     # connected
cat /sys/class/drm/card0-HDMI-A-1/modes      # 800x480
cat /sys/class/drm/card0-HDMI-A-1/enabled    # enabled

# 3. framebuffer 和 X 都起来了
ls /dev/fb0
systemctl is-active lightdm                  # active
```

Xorg 日志变为：

```text
(II) modeset(0): Printing probed modes for output HDMI-1
(II) modeset(0): Output HDMI-1 using initial mode 800x480 +0+0
```

## 7. 注意事项

- `video=` 对这个连接器是**全局**的：HDMI-A-1 被固定在 800×480，接其它显示器/采集卡也会被强制成 800×480。要恢复原生分辨率就删掉这一行重启。
- 强制的 `60` Hz 与面板 EDID 的 `60.727` Hz 不完全一致，但这块屏实测接受该 CVT 时序，画面稳定。若出现偏移/闪烁，可改用 EDID 里的精确值（`800x480@60.7`）。
- 这是**绕过**，不是修复。真正应修的地方在 `sunxi-hdmi`：EDID 解析出模式后要把它注册到 DRM 连接器（`get_modes` / `connector->modes`），否则任何用户空间都拿不到。

## 8. 诊断命令速查

```bash
# 所有连接器的状态/模式
for c in /sys/class/drm/card*-*; do
  echo "== $c"
  cat "$c/status" "$c/enabled" "$c/modes" 2>/dev/null
done

# EDID 是否真的读到（128 字节 = 一个 block）
wc -c /sys/class/drm/card0-HDMI-A-1/edid

# HDMI/DRM 关键日志
dmesg | grep -iE 'sunxi-hdmi|edid|hpd|drm'

# X 起不来时的第一现场
grep -E 'EE|No modes|no screens' /var/log/Xorg.0.log

# 当前内核命令行
cat /proc/cmdline

# 是否具备固件 EDID 兜底
zcat /proc/config.gz 2>/dev/null | grep CONFIG_DRM_LOAD_EDID_FIRMWARE
```

## 9. 给厂商的建议

问题可以归纳为一句话：**当 HDMI 连接器状态为 `connected` 且 EDID 有效时，`sunxi-hdmi` 必须把解析出的模式注册到 DRM 连接器，使 `modes` 非空、`enabled` 可被用户空间打开。** 目前驱动日志显示解析成功（`support modes: 1`），但连接器模式列表为空，导致 Xorg/Wayland 都无法使用该输出。

## 参考

- 内核 `video=` 参数（DRM connector forcing）：`Documentation/framebuffer.txt`、`Documentation/gpu/drm-kms.rst`
- DRM 连接器模式报告路径：`drm_connector->get_modes`
