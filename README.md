# 香橙派 Zero 3W（A733）：HDMI 已连接却"没有可用模式"——厂商 `sunxi-hdmi` 驱动问题

> [English version](README.en.md)

## TL;DR

屏幕接上后，DRM 连接器状态是 `connected`、EDID 也读得到（128 字节，800×480@60.7），厂商驱动的 dmesg 甚至明确说解析出了 1 个模式（`drm get edid support modes: 1`），但连接器的 `modes` 列表为空、`enabled=disabled`，Xorg 直接报 `Output HDMI-1 enabled but has no modes` / `no screens found`。

**根因**：厂商 `sunxi-hdmi` 驱动把 EDID 解析出来了，却没有把得到的模式注册到 DRM 连接器上，用户空间（Xorg 的 modesetting 驱动）拿不到任何候选分辨率，于是无法建立屏幕。

**绕过**：在内核命令行里强制给这个连接器一个模式——`extraargs=video=HDMI-A-1:800x480@60e`（写在 `/boot/orangepiEnv.txt`），重启后即可出图。

**⚠️ 后续（2026-10-27）**：`@60e` 里的 `e` 是 `DRM_FORCE_ON`，在 DDC/HPD 不通的屏上会让每次探测都卡满 620 ms 的 I²C 超时，**整个桌面掉到 3 fps**。如果你那块屏的 DDC 也读不出来，请直接看 [第 10 节](#10-后续2026-10-27-60e-的代价--整个桌面掉到-3-fps)，用 **EDID override + 延迟 force** 的方案代替第 5 节。

---

## 1. 环境

| 项目 | 值 |
| --- | --- |
| 单板 | Orange Pi Zero 3W（Allwinner A733，DTB `sun60i-a733-orangepi-zero3w.dtb`） |
| 系统 | Orange Pi 官方 Ubuntu 22.04.5 LTS（Jammy），XFCE + LightDM |
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

## 10. 后续（2026-10-27）：`@60e` 的代价 —— 整个桌面掉到 3 fps

第 5 节的绕过后画面确实出来了，但**整个 GUI 只有 ~3 fps**：鼠标发飘、视频卡成幻灯片。继续查下来，问题不在屏、不在刷新率、不在过热，而是 `e` 这个强制标志本身。

### 10.1 先排除掉的

| 怀疑点 | 实测 | 结论 |
| --- | --- | --- |
| 刷新率 | DRM vblank 采样 10 秒 = **60.037 Hz**，0 个停滞窗口 | 排除 |
| 过热降频 | 8 核满载 90 秒最高 **71 °C**，cpufreq 限频档位始终 0（触发点是 90 °C） | 排除 |
| 分辨率/填充率 | mpv `--vo=null` **307 fps**；`--vo=x11` 在 800×480 和 160×120 下都是 **3.2 fps** | 排除（与像素数无关） |
| 供电 | 独立供电与共用供电现象一致 | 排除 |

最说明问题的一行：**160×120 和 800×480 一样慢**。这说明瓶颈是每帧前面一次固定阻塞，而不是画得多。

### 10.2 现场：Xorg 主线程堵在 I²C 里

```bash
$ sudo cat /proc/$(pgrep -x Xorg)/wchan
_dw_i2cm_read          # 空闲时 10/10 次采样都在这里；放视频时同样 10/10

$ sudo cat /proc/$(pgrep -x Xorg)/stack
_dw_i2cm_read
dw_i2cm_xfer
sunxi_hdmi_i2cm_xfer
__i2c_transfer
drm_do_probe_ddc_edid      ← 在读 EDID
drm_do_get_edid
drm_get_edid
_sunxi_drv_hdmi_read_edid
_sunxi_drv_hdmi_hpd_plugin
_sunxi_drm_hdmi_force
drm_helper_probe_single_connector_modes
drm_mode_getconnector       ← 来自 DRM_IOCTL_MODE_GETCONNECTOR
```

也就是说：Xorg 每问一次"显示器什么情况"，驱动都会**真的去 DDC 总线读一遍 EDID**。

### 10.3 根因：`e` 就是 `DRM_FORCE_ON`

```bash
$ sudo cat /sys/kernel/debug/dri/0/HDMI-A-1/force
on
```

`video=HDMI-A-1:800x480@60e` 里的 `e` 把连接器设成了 `DRM_FORCE_ON`。force 一生效，`drm_helper_probe_single_connector_modes()` 每次都会调用驱动的 `->force()` 回调。如果此时 DDC 读得到（本文最初的状态），代价只是慢一点；而一旦 DDC 读不到（`i2cget -y 20 0x50 0x00` 直接 `Read failed`），每次读都要等满超时：

```text
单次强制探测：620.2 ms   （紧接着读缓存：0.0 ms）
10 秒内：detect hpd 15 次 / edid failed 28 次 / force hpd 15 次
```

15 ÷ 10 = 1.5 次/秒，而 1 ÷ 0.62 ≈ 1.6 —— Xorg 是**排满地在做这一件事**，每帧前面都堵着几百毫秒。

### 10.4 现在的做法：EDID override + 强制连接 + Xorg 自带 Modeline

三层各自解决一件事：

1. `edid_override`（debugfs）直接塞一份真 EDID，内核不再碰 DDC —— 解决 620 ms 卡顿
2. `force=on` 保证 connector 永远是 connected —— 解决 HPD 时有时无
3. `/etc/X11/xorg.conf.d/20-hdmi-800x480.conf` 里写一条 Modeline —— 解决驱动不给模式

第 3 条是 2026-10-29 补的，见 [10.8](#108-2026-10-29-翻车忘了第-3-条)。

真 EDID 是从一台能正常识别这块屏的笔记本上读出来的：

```text
厂商 ADA   800×480 @ 37.000 MHz   htotal 1088 / vtotal 560 ≈ 60.73 Hz
```

**`scripts/800x480.edid` 只对这块屏有效。** 换一块屏（哪怕是同型号的另一批）务必重新导一份，否则用的是别人屏的时序。在任意一台能正常识别它的机器（笔记本/台式机，Linux 下）导出：

```bash
# 先确认是哪个连接器
for c in /sys/class/drm/card*-*; do
    [ "$(cat $c/status)" = connected ] && echo "$c  $(wc -c < $c/edid) 字节"
done

# 128 字节 = 一个 EDID block，抄出来
sudo cat /sys/class/drm/card0-DP-1/edid > mypanel.bin
```

Windows 下可以用 Monitor Asset Manager，或者 `Get-WmiObject WmiMonitorDescriptorMethods`。拿到 `.bin` 后替换 `scripts/800x480.edid`（或 `install.sh` 里的文件名），并同步改 `~/.xsessionrc` 里 `xrandr --newmode` 的时序参数（从 EDID 的 DTD 换算）。

**⚠️ 早期版本里「必须等桌面会话起来再 force」这条规则已经作废**，原因见 10.8。现在服务是 `Before=lightdm.service`，在 X 启动前就把两样都写好。

```bash
sudo ./scripts/install.sh
```

### 10.5 效果

| 项目 | 修前 | 修后 |
| --- | --- | --- |
| 渲染（mpv `--vo=x11`，800×480） | 3.1 fps | 56–80 fps |
| `edid failed`（10 秒内） | 28 次 | 0 |
| `force hpd`（10 秒内） | 15 次 | 0 |
| 单次强制探测 | 620 ms | 不再触发 |

### 10.6 回滚

```bash
sudo systemctl disable --now hdmi-edid-override
sudo rm /etc/X11/xorg.conf.d/20-hdmi-800x480.conf
rm ~/.xsessionrc
sudo reboot
```

### 10.7 给厂商的补充建议

- `->force()` 路径下不应无条件读 DDC；EDID 读失败应当缓存失败结果并退避，而不是每次探测都重试 620 ms
- 同步 I²C 传输放在 `GETCONNECTOR` 的调用路径上，会直接阻塞用户空间的主循环，建议改为异步或带缓存
- 内核没有启用 `CONFIG_DRM_LOAD_EDID_FIRMWARE`，建议开启，至少让用户能用固件 EDID 兜底（否则只能走 debugfs 的 `edid_override`）

### 10.8 2026-10-29 翻车：漏了"驱动不给模式"这半句

**症状**：开机黑屏。`lightdm` 状态 `failed`、`NRestarts=32`，override 服务日志只有一句：

```text
等了 60 秒也没看到桌面会话，放弃
```

**现场**：

```text
HDMI-A-1: connected          ← DDC 这次是通的
edid: 128 字节               ← EDID 读得出来
modes: []                    ← 但驱动依旧不注册（第 5 节的原始 bug）
Xorg: (EE) Output HDMI-1 enabled but has no modes → no screens found
```

**死锁**：旧脚本的前提是"Xorg 先起来，再补 EDID/force"。可这次连接器报 `connected`，Xorg 一启动就撞上"连着但零个模式"直接退出 → 没有桌面会话 → 脚本等到超时放弃 → 什么都不写 → 永远黑屏。**整个方案依赖一个环形前提，一旦连接器状态变了就断。**

（10-27 那次为什么能过，当时没留下足够日志，已经说不清了。能确定的是：这不是可靠设计。）

**修法**——把"驱动不给模式"这半句正面解决，而不是绕：

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

有了这条 Modeline，Xorg 不再看驱动那张永远为空的模式列表，`force=on` 也就可以放心地**提前**写（服务改成 `Before=lightdm.service`），环形依赖消失。

**不用重启的应急恢复**（黑屏但能 SSH 时）：

```bash
S=/sys/kernel/debug/dri/0/HDMI-A-1
sudo sh -c "cat /etc/hdmi-edid/800x480.bin > $S/edid_override; echo on > $S/force"
sudo systemctl reset-failed lightdm && sudo systemctl start lightdm
# 只启动一次；起不来就立刻 systemctl stop lightdm，别让它进重启循环
```

注意：写 `edid_override` 本身不会刷新 sysfs 里的 `modes`（那是上次探测的缓存，而这驱动反正也不会填它）。别拿 `cat modes` 是否为空来判断成功，要看 Xorg 起没起来。

## 参考

- 内核 `video=` 参数（DRM connector forcing）：`Documentation/framebuffer.txt`、`Documentation/gpu/drm-kms.rst`
- DRM 连接器模式报告路径：`drm_connector->get_modes`
