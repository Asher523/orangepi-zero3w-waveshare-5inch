# Orange Pi Zero 3W + 微雪 5inch HDMI LCD 黑屏排查记录

> [English version](README.en.md)

> **TL;DR (English)** — A Waveshare 5inch HDMI LCD (800×480) stayed black on an Orange Pi Zero 3W (Allwinner A733, vendor kernel 5.15.147-sun60iw2, Ubuntu 22.04). Two unrelated faults stacked:
> 1. The first **mini-HDMI (Type-C) adapter did not pass HPD/DDC**, so the driver reported `drm hdmi detect: disconnect` and read zero EDID bytes. Replacing the adapter with a known-good one gave `detect: connect` and one parsed mode.
> 2. The vendor `sunxi-hdmi`/sunxi-drm driver parsed the EDID mode but **never exposed it to userspace**, so Xorg died with `No remaining probed modes for output HDMI-1` / `no screens found`. Debugfs `force`, `hpd_mask` and `edid_data` injection all had no effect, and `CONFIG_DRM_LOAD_EDID_FIRMWARE` is off, so `drm_kms_helper.edid_firmware` was unavailable.
>
> **Fix:** add `extraargs=video=HDMI-A-1:800x480@60e` to `/boot/orangepiEnv.txt` (`extraargs` is folded into the kernel `bootargs` by `/boot/boot.cmd`), reboot. The connector then reports `modes: 800x480`, `fb0` appears, and Xorg brings up an 800×480 framebuffer. Side effect: that port is pinned to 800×480 until the line is removed.

---

## 1. 环境

| 项目 | 值 |
| --- | --- |
| 单板 | Orange Pi Zero 3W（Allwinner A733，DTB `sun60i-a733-orangepi-zero3w.dtb`） |
| 系统 | Orange Pi 官方 Ubuntu 22.04.5 LTS（Jammy，"Orange Pi 1.0.0"），Cinnamon 桌面，LightDM |
| 内核 | `5.15.147-sun60iw2`（厂商内核，带 `sunxi-hdmi` / eDP 驱动） |
| 屏幕 | Waveshare **5inch HDMI LCD Rev 3.1**（SKU 10563），800×480，XPT2046 电阻触摸（SPI） |
| 视频口 | 板上是 **mini-HDMI（Type-C）**，不是 micro-HDMI |
| 供电 | 屏幕侧 `Power Only` micro-USB 独立供电，背光拨到 ON |
| 交叉验证设备 | 笔记本（Linux）+ USB-C 扩展坞 + mini-HDMI→HDMI 转接头 + HDMI 采集卡 |

> 板上那个小 HDMI 口是 **mini-HDMI（Type-C）**。很多人（包括我一开始）会下意识按 micro-HDMI 去买线，结果买到的是物理上插不进去、或者针脚定义不对的转接件。

## 2. 现象

板子上电、系统正常启动（SSH 能进、`lightdm` 在跑），但屏幕全黑，背光也没亮。内核里只能看到：

```text
[drm] sunxi-hdmi: drm hdmi detect: disconnect
```

`/sys/class/drm/card0-HDMI-A-1/status` 为 `disconnected`，`edid` 为 0 字节。

排查过程中出现过两个完全不同的状态，值得分开记：

- **状态 A**：`disconnect`、EDID 空 —— 连接层问题。
- **状态 B**：`connect`、EDID 能解析、但 `modes` 为空，Xorg 起不来 —— 驱动/用户空间问题。

最后亮屏是**两个问题都解决**之后才发生的。

---

## 3. 排查过程

### 3.1 先看内核到底认没认出屏幕

```bash
# 连接器状态 / EDID / 已注册模式
cat /sys/class/drm/card0-HDMI-A-1/status
wc -c /sys/class/drm/card0-HDMI-A-1/edid
cat /sys/class/drm/card0-HDMI-A-1/modes

# 厂商驱动的探测日志
dmesg | grep -iE 'sunxi-hdmi|hdmi|edid|drm'
```

当时输出（问题未解时）：

```text
disconnected
0 /sys/class/drm/card0-HDMI-A-1/edid
```

对应 dmesg：

```text
[drm] sunxi-hdmi: drm hdmi detect: disconnect
```

结论：屏的 HPD（热插拔检测）没有到达 SoC，或者 DDC 通道不通，驱动根本没去读 EDID。
先排除屏幕和电源：

- 屏幕 `Power Only` micro-USB 单独供电，背光开关拨到 ON（背光不亮时**先确认这个**，它和信号是两回事）。
- 板子换用官方的、已知能出图的 mini-HDMI 线。

### 3.2 交叉验证：把同一块屏接到笔记本上

把屏接到笔记本的 USB-C 扩展坞（走 DP Alt Mode）上，`xrandr` / DRM 立刻认出：

```text
ADA / Model 4
15 cm x 9 cm
800x480 @ 60.727 Hz
Pixel clock: 37.0 MHz
DTD: h_active 800, h_sync 848, h_sync_end 888, h_blank_end 1088
     v_active 480, v_sync 483, v_sync_end 493, v_blanking 560
```

**这块屏和它的 EDID 都没有问题**，问题在香橙派这一侧的连接或驱动。

顺便：板子 → mini-HDMI → HDMI 采集卡 → 电脑这条链路也能出图，说明板子的 HDMI 口本身是工作的。问题被压缩到「转接头 + 驱动」两个嫌疑点。

### 3.3 问题一：mini-HDMI 转接头没把 HPD/DDC 传过去

换上一根确认可用的 mini-HDMI→HDMI 后，内核立刻变了：

```text
[drm] sunxi-hdmi: drm hdmi detect: connect
[drm] hdmi edid only has block0 and parse finish
[drm] drm get edid support modes: 1
```

`status` 变成 `connected`，`edid` 也读到了 128 字节。

**第一个根因**：便宜转接头里 HPD / DDC（I²C）线没接全或接触不良。HPD 不通时，驱动认为「没插屏」；DDC 不通时，能 detect 但读不到 EDID。这类线材在「只出图像」的场景下可能碰巧能用，但在需要 EDID 协商的场景下必然翻车。

### 3.4 问题二：驱动解析出了模式，用户空间却拿不到

`connect` 之后，屏幕依然是黑的。这时状态是：

```text
$ cat /sys/class/drm/card0-HDMI-A-1/status
connected

$ cat /sys/class/drm/card0-HDMI-A-1/modes
        # 空

$ cat /sys/class/drm/card0-HDMI-A-1/enabled
disabled
```

Xorg 的日志把问题钉死了：

```text
(II) modeset(0): Output HDMI-1 connected
(II) modeset(0): No remaining probed modes for output HDMI-1
(EE) modeset(0): Output HDMI-1 enabled but has no modes
(EE) modeset(0): No modes.
(EE) Fatal server error:
(EE) no screens found
```

一边是驱动日志说 `drm get edid support modes: 1`（解析出了一个模式），另一边是 DRM 连接器的 `modes` 空、`enabled=disabled`。也就是说，**厂商 `sunxi-hdmi` 驱动把 EDID 解析出来了，但没有通过 DRM 的 `get_modes` 把模式列表交给用户空间**。Xorg（modesetting 驱动）拿不到任何 mode，连 framebuffer 都建不起来，于是 `no screens found`。

这一步可以顺带确认一下内核编译选项——如果 `CONFIG_DRM_LOAD_EDID_FIRMWARE` 开着，还能用固件 EDID 兜底：

```bash
zcat /proc/config.gz | grep DRM_LOAD_EDID_FIRMWARE
```

本机结果：

```text
# CONFIG_DRM_LOAD_EDID_FIRMWARE is not set
```

所以 `drm_kms_helper.edid_firmware=HDMI-A-1:edid/800x480.bin` 这条路也没得走。

### 3.5 试过但无效的办法（供别人少走弯路）

| 方法 | 结果 |
| --- | --- |
| `echo on > /sys/kernel/debug/dri/0/HDMI-A-1/force` | 接受了写入，但 `status` 仍为 `disconnected`/无模式；写 `detect` 直接返回 `I/O error` |
| 厂商节点 `/sys/devices/virtual/hdmi/hdmi/attr/hpd_mask`（写 `1`） | 日志 `set hpd mask: 0x1`，连接器状态不变 |
| 往 `edid_data` 写入一份标准 800×480 EDID | 写入成功，`modes` 依旧为空 |
| `drm_kms_helper.edid_firmware=...` | 内核没编 `CONFIG_DRM_LOAD_EDID_FIRMWARE`，无效 |
| 反复重启 `lightdm` | 一样 `no screens found` |

这些「厂商私有旋钮」在这个驱动版本上基本是**摆设**：能写进去、日志也打印，但不参与实际的模式枚举。

### 3.6 生效的方案：在内核命令行里强制模式

既然 DRM 层面拿不到模式，就让内核在初始化 DRM 时**直接把模式塞给连接器**。DRM 的 `video=` 参数支持按连接器名指定模式：

```text
video=HDMI-A-1:800x480@60e
```

`e` 后缀表示「这是强制（preferred/driver）模式，不要跟 EDID 协商」。

写进 U-Boot 的环境文件即可持久化。Orange Pi 的 `/boot/boot.cmd` 第 38 行会把 `extraargs` 拼进 `bootargs`：

```text
setenv bootargs "... ${extraargs} ${extraboardargs}"
```

所以只需要在 `/boot/orangepiEnv.txt` 末尾加一行：

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

改之前先备份：

```bash
sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak
sudo sed -i 's/^extraargs=.*/extraargs=video=HDMI-A-1:800x480@60e/' /boot/orangepiEnv.txt
sync
sudo reboot
```

## 4. 验证

重启后三项都要对：

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

Xorg 日志对应变成：

```text
(II) modeset(0): Printing probed modes for output HDMI-1
(II) modeset(0): Output HDMI-1 using initial mode 800x480 +0+0
```

屏幕点亮，桌面正常显示。

## 5. 副作用与注意事项

- **`video=HDMI-A-1:800x480@60e` 会把 HDMI-A-1 这个连接器钉死在 800×480**。以后接别的显示器、采集卡或电视，也会被强制成 800×480；要用原生分辨率就把这行删掉重启（或将 `HDMI-A-1` 换成实际连接器名，只对这一个口生效）。
- `@60e` 里的 60 Hz 与面板 EDID 的 60.727 Hz 不完全一致，但实测这块屏能吃下这个 CVT 时序，画面稳定、无欠扫描。如果出现偏移或闪烁，可以改成 EDID 里的精确值：`800x480@60.7`（或按 DTD 算出来的 60.729）。
- 这个方案是**绕过**，不是修好厂商驱动。真正的修复应该是在 `sunxi-hdmi` 的 `get_modes` / EDID 解析路径里把模式注册进 DRM 连接器，然后向上游或香橙派反馈。

## 6. 顺带发现：USB-C 的 DP Alt Mode 也不通

同一块屏走板子的 USB-C（扩展坞）时，**连接器能认到屏，但链路训练失败**：

```text
card0-DP-1: connected        # 能读出 sink
```

dmesg 里是 eDP-over-Type-C 的链路问题：

```text
[EDP_ERR]: swing voltage reach max level, training1(clock recovery training) fail!
edp's combo-phy not setting, maybe not used!
get aux_p pull external up/down pin for phy mux failed, may be useless!
edp_lane_rate not set manually, set to default: 2.7G!
edp_lane_cnt not set manually, set to default: 2!
```

即：SoC 的 eDP 控制器被用来做 DP Alt Mode，但 PHY 复用没配好（AUX 上下拉引脚拿不到、combo-PHY 没设置），链路训练在 clock recovery 阶段就挂了，默认 2.7 Gbps × 2 lane 也救不回来。这属于厂商 BSP 的限制，本次没有继续折腾，**走 HDMI 才是正路**。

## 7. 诊断命令速查

```bash
# 列出所有 DRM 连接器及状态/模式
for c in /sys/class/drm/card*-*; do
  echo "== $c"
  cat "$c/status" "$c/enabled" "$c/modes" 2>/dev/null
done

# EDID 是否真的读到了（128 字节 = 一个 block）
wc -c /sys/class/drm/card0-HDMI-A-1/edid

# HDMI 相关内核日志
dmesg | grep -iE 'sunxi-hdmi|edid|hpd|drm'

# X 起不来的第一现场
grep -E 'EE|No modes|no screens' /var/log/Xorg.0.log

# 当前内核命令行
cat /proc/cmdline

# 是否有 EB-EDID 固件兜底能力
zcat /proc/config.gz 2>/dev/null | grep CONFIG_DRM_LOAD_EDID_FIRMWARE
```

## 8. 未完成

- **触摸**：这块屏的 XPT2046 走 SPI，需要接 26-pin 排针并启用对应 overlay（`orangepiEnv.txt` 里已有 `spi3-cs0-cs1-spidev`，但还没配 XPT2046 的驱动/校准）。
- **旋转/缩放**：小屏做桌面时通常要配合 `xrandr --scale` 或改 `video=` 的宽高比。
- **给厂商反馈**：`sunxi-hdmi` 在 `connect` + EDID 有效时不向用户空间暴露模式，是个值得上报的 BSP 问题。

## 参考

- Waveshare 5inch HDMI LCD 文档：<https://docs.waveshare.net/5inch_HDMI_LCD>
- 内核 `video=` 参数（DRM connector forcing）：`Documentation/framebuffer.txt` / `Documentation/gpu/drm-kms.rst`
- 图片：`waveshare-5inch-back.jpg`（屏幕背面接口：HDMI、Power Only micro-USB、触摸排线）
