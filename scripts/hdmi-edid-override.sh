#!/bin/sh
# Orange Pi Zero 3W + 微雪 5 寸 HDMI 屏（800x480）
#
# 背景：这块屏的 HDMI 侧 DDC（EDID，i2c 0x50）和 HPD 时好时坏。
# 更根本的问题是厂商驱动把 EDID 解析出来了（dmesg 说 "support modes: 1"），
# 却不把模式注册到 DRM connector，所以 connector->modes 永远是空的，
# Xorg 直接 "Output HDMI-1 enabled but has no modes" -> no screens found。
#
# 本脚本负责内核侧的两件事（必须在 Xorg 起来之前完成）：
#   1. 把真 EDID 写进 edid_override —— 内核不再去 DDC 读，DDC 不通也不会卡 620ms
#   2. 把 connector 强制设成 on —— HPD 不通时状态也是 connected
#
# 用户空间侧由 /etc/X11/xorg.conf.d/20-hdmi-800x480.conf 提供 Modeline，
# 因为驱动不给模式，Xorg 必须自己有一条。有了它，force=on 提前写也安全
# （早期版本没有它，force 早写会变成"connected 但零个模式"，导致 lightdm 无限重启）。
#
# 关闭：systemctl disable --now hdmi-edid-override
#       并删掉 /etc/X11/xorg.conf.d/20-hdmi-800x480.conf、~/.xsessionrc

set -e

# 等 debugfs 和 HDMI-A-1 节点就绪（开机早期 DRM 可能还没初始化完）
D=""
for _ in $(seq 1 120); do
    mountpoint -q /sys/kernel/debug 2>/dev/null ||
        mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    D=$(ls -d /sys/kernel/debug/dri/[0-9]*/HDMI-A-1 2>/dev/null | head -1)
    [ -n "$D" ] && break
    sleep 0.5
done

if [ -z "$D" ]; then
    echo "等了 60 秒也没找到 HDMI-A-1 的 debugfs 目录，放弃" >&2
    exit 0
fi

cat /etc/hdmi-edid/800x480.bin >"$D/edid_override"
echo on >"$D/force"

echo "EDID override 与 force=on 已写入 $D"
