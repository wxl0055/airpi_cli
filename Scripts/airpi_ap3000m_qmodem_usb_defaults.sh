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

mkdir -p files/usr/bin files/etc/init.d files/etc/uci-defaults

cat > files/usr/bin/ap3000m-qmodem-usb-enable <<'INNER'
#!/bin/sh

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "airpi,ap3000m" ] || exit 0

apply_once() {
    uci -q set qmodem.main.enable_dial='1'
    uci -q set qmodem.main.try_preset_usb='1'
    uci -q set qmodem.main.try_preset_pcie='0'
    uci -q set qmodem.main.enable_pcie_scan='0'

    uci -q show qmodem | sed -n 's/^\(qmodem\.[^.]*\)=modem-device$/\1/p' | while read -r sec; do
        data="$(uci -q get "$sec.data_interface" 2>/dev/null || true)"
        path="$(uci -q get "$sec.path" 2>/dev/null || true)"

        [ "$data" = "usb" ] || continue
        [ -z "$path" ] || [ -d "$path" ] || continue

        uci -q set "$sec.state=enabled"
        uci -q set "$sec.enable_dial=1"
    done

    uci commit qmodem 2>/dev/null || true

    pkill -f 'modem_scan.sh.*pcie' 2>/dev/null || true
    pkill -f 'scan_pcie' 2>/dev/null || true
}

i=0
while [ "$i" -lt 12 ]; do
    apply_once

    if ! ps w 2>/dev/null | grep -q '[q]uectel-CM'; then
        ubus call qmodem modem_dial '{"config_section":"2_1"}' >/dev/null 2>&1 || true
    fi

    sleep 5
    i=$((i + 1))
done

exit 0
INNER

chmod 0755 files/usr/bin/ap3000m-qmodem-usb-enable

cat > files/etc/init.d/ap3000m_qmodem_usb_enable <<'INNER'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=0

start() {
    /usr/bin/ap3000m-qmodem-usb-enable >/dev/null 2>&1 &
}
INNER

chmod 0755 files/etc/init.d/ap3000m_qmodem_usb_enable

cat > files/etc/uci-defaults/99-ap3000m-qmodem-usb-enable <<'INNER'
#!/bin/sh

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "airpi,ap3000m" ] || exit 0

/etc/init.d/ap3000m_qmodem_usb_enable enable 2>/dev/null || true
/usr/bin/ap3000m-qmodem-usb-enable >/dev/null 2>&1 &

exit 0
INNER

chmod 0755 files/etc/uci-defaults/99-ap3000m-qmodem-usb-enable

echo "Airpi AP3000M QModem USB state guard overlay applied."
