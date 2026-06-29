#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WRT="${REPO_ROOT}/wrt"
[ -d "$WRT" ] || WRT="/mnt/build_wrt"
[ -d "$WRT" ] || WRT="$(pwd)"
[ -d "$WRT/target/linux/mediatek" ] || {
    echo "ERROR: OpenWrt source root not found: $WRT"
    exit 1
}

cd "$WRT"
mkdir -p files/etc/uci-defaults

cat > files/etc/uci-defaults/98-ap3000m-qmodem-usb-defaults <<'EOS'
#!/bin/sh

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "airpi,ap3000m" ] || exit 0

if uci -q get qmodem.main >/dev/null 2>&1; then
    uci -q set qmodem.main.try_preset_usb='1'
    uci -q set qmodem.main.try_preset_pcie='0'
    uci -q set qmodem.main.enable_pcie_scan='0'

    uci -q show qmodem | sed -n "s/^\(qmodem\.[^.]*\)=modem-device$/\1/p" | while read -r sec; do
        if [ "$(uci -q get "$sec.data_interface")" = "usb" ]; then
            path="$(uci -q get "$sec.path")"
            [ -z "$path" ] || [ -d "$path" ] || continue
            uci -q set "$sec.state=enabled"
        fi
    done

    uci -q commit qmodem
    logger -t ap3000m-qmodem-usb-defaults "USB modem defaults applied, PCIe scan disabled"
fi

exit 0
EOS

chmod +x files/etc/uci-defaults/98-ap3000m-qmodem-usb-defaults

echo "Airpi AP3000M QModem USB defaults applied."
