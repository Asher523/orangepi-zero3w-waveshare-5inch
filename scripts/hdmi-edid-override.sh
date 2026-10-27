#!/bin/sh
# Orange Pi Zero 3W + 微雪 5 寸 HDMI 屏（800x480）
#
# 背景：这块屏的 HDMI 侧 DDC（EDID，i2c 0x50）和 HPD 都不通。
# 内核每次探测都会真去 DDC 读 EDID，一次等超时约 620ms，每秒 1.5 次，
# 把 Xorg 主线程 100% 堵在 _dw_i2cm_read 里，整机 GUI 掉到 ~3fps。
#
# 做法：把真 EDID 写进 edid_override（内核不再碰 DDC），
#       再把 connector 强制设成 on（内核不再等 HPD）。
#
# 顺序很重要！必须在 Xorg 已经用 disconnected 状态建好屏幕之后再强制。
# 反过来做的话，connector 是 connected 但内核没有任何模式，
# Xorg 会直接 "no screens found" 然后无限重启。
#
# 关闭：systemctl disable --now hdmi-edid-override
#       再删掉 ~/.xsessionrc

set -e

# 1) 等真正的桌面会话起来（xfce4-session 出现即说明 X 的屏幕已经建好）
n=0
while [ $n -lt 120 ]; do
    pgrep -x xfce4-session >/dev/null 2>&1 && break
    n=$((n + 1))
    sleep 0.5
done
if [ $n -ge 120 ]; then
    echo "等了 60 秒也没看到桌面会话，放弃" >&2
    exit 0
fi

# 2) 找到 HDMI-A-1 的 debugfs 目录
D=""
for _ in $(seq 1 50); do
    mountpoint -q /sys/kernel/debug 2>/dev/null ||
        mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    D=$(ls -d /sys/kernel/debug/dri/[0-9]*/HDMI-A-1 2>/dev/null | head -1)
    [ -n "$D" ] && break
    sleep 0.2
done

if [ -z "$D" ]; then
    echo "找不到 HDMI-A-1 的 debugfs 目录，放弃" >&2
    exit 0
fi

# 3) 灌 EDID + 强制连接
cat /etc/hdmi-edid/800x480.bin >"$D/edid_override"
echo on >"$D/force"

echo "EDID override 与 force=on 已写入 $D"
