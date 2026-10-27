#!/bin/sh
# 安装 EDID override 方案（针对 HDMI 的 DDC/HPD 都不通的屏幕）
#
#   sudo ./install.sh
#
# 回滚：
#   sudo systemctl disable --now hdmi-edid-override
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

systemctl daemon-reload
systemctl enable hdmi-edid-override.service

if [ -e "$USER_HOME/.xsessionrc" ]; then
    cp "$USER_HOME/.xsessionrc" "$USER_HOME/.xsessionrc.bak"
    echo "已备份原有 .xsessionrc 到 .xsessionrc.bak"
fi
install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$HERE/xsessionrc" "$USER_HOME/.xsessionrc"

echo
echo "已安装。重启后生效。"
echo
echo "如果 /boot/orangepiEnv.txt 里还有 extraargs=video=...@60e，请一并删掉："
echo "  sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak"
echo "  sudo sed -i '/^extraargs=.*video=/d' /boot/orangepiEnv.txt && sync"
