#!/bin/sh
# 安装 EDID override 方案（针对 HDMI 的 DDC/HPD 都不通的屏幕）
#
#   sudo ./install.sh
#
# 回滚：
#   sudo systemctl disable --now hdmi-edid-override
#   sudo rm /etc/X11/xorg.conf.d/20-hdmi-800x480.conf
#   rm ~/.xsessionrc && sudo reboot

set -e

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo $0" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

mkdir -p /etc/hdmi-edid
install -m 644 "$HERE/800x480.edid" /etc/hdmi-edid/800x480.bin
install -m 755 "$HERE/hdmi-edid-override.sh" /usr/local/sbin/hdmi-edid-override.sh
install -m 644 "$HERE/hdmi-edid-override.service" /etc/systemd/system/hdmi-edid-override.service

# 驱动不给模式，Xorg 必须自己有一条，否则 "Output HDMI-1 enabled but has no modes"
mkdir -p /etc/X11/xorg.conf.d
if [ -e /etc/X11/xorg.conf.d/20-hdmi-800x480.conf ]; then
    cp /etc/X11/xorg.conf.d/20-hdmi-800x480.conf /etc/X11/xorg.conf.d/20-hdmi-800x480.conf.bak
fi
install -m 644 "$HERE/20-hdmi-800x480.conf" /etc/X11/xorg.conf.d/20-hdmi-800x480.conf

systemctl daemon-reload
systemctl enable hdmi-edid-override.service

if [ -e "$USER_HOME/.xsessionrc" ]; then
    cp "$USER_HOME/.xsessionrc" "$USER_HOME/.xsessionrc.bak"
    echo "已备份原有 .xsessionrc 到 .xsessionrc.bak"
fi
install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$HERE/xsessionrc" "$USER_HOME/.xsessionrc"

echo
echo "已安装。重启后生效。"

# 上一版（@60e）的残留会让 connector 在开机时就 force=on，
# 登录前的几十秒仍会 620ms 一次空转，检查一下
if grep -q '^extraargs=.*video=' /boot/orangepiEnv.txt 2>/dev/null; then
    echo
    echo "⚠️  /boot/orangepiEnv.txt 里还留着上一版的强制模式："
    grep -n '^extraargs=.*video=' /boot/orangepiEnv.txt | sed 's/^/      /'
    echo "   建议删掉（本方案不需要它）："
    echo "     sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak"
    echo "     sudo sed -i '/^extraargs=.*video=/d' /boot/orangepiEnv.txt && sync"
fi

command -v xrandr >/dev/null 2>&1 ||
    echo "⚠️  没找到 xrandr，~/.xsessionrc 不会生效：sudo apt install x11-xserver-utils"
