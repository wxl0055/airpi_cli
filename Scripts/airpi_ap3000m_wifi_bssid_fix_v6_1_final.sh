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

echo "Apply Airpi AP3000M WiFi BSSID fix v6.1-final"
echo "WRT=$WRT"

python3 - <<'PY'
from pathlib import Path
import re

def find_node_end(text, pos):
    brace = text.find("{", pos)
    if brace < 0:
        return None
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                j = i + 1
                while j < len(text) and text[j].isspace():
                    j += 1
                if j < len(text) and text[j] == ";":
                    return j + 1
    return None

def patch_wifi_node(path):
    s = path.read_text()
    if "eeprom_factory_0:" not in s or "&wifi" not in s:
        return False

    pos = s.find("&wifi")
    end = find_node_end(s, pos)
    if end is None:
        raise SystemExit(f"ERROR: cannot locate &wifi end in {path}")

    block = '''&wifi {
    /* Airpi AP3000M: use EEPROM from eMMC factory NVMEM. */
    nvmem-cells = <&eeprom_factory_0>;
    nvmem-cell-names = "eeprom";
    status = "okay";
};
'''

    s = s[:pos] + block + s[end:]
    m = re.search(r'&wifi\s*\{.*?\n\};', s, re.S)
    clean = re.sub(r'/\*.*?\*/', '', m.group(0), flags=re.S) if m else ""
    clean = re.sub(r'//.*', '', clean)

    if "mediatek,eeprom-data" in clean:
        raise SystemExit(f"ERROR: active mediatek,eeprom-data remains in {path}")

    path.write_text(s)
    return True

patched = []
for p in sorted(Path("target/linux/mediatek/dts").glob("mt7981*Airpi*.dts")) + sorted(Path("target/linux/mediatek/dts").glob("mt7981*airpi*.dts")):
    if patch_wifi_node(p):
        patched.append(str(p))

print("DTS_PATCHED=" + ",".join(patched))
if not patched:
    raise SystemExit("ERROR: no Airpi DTS patched")
PY

WIFIMAC="target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac"

if [ -f "$WIFIMAC" ]; then
python3 - "$WIFIMAC" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

block = '''    airpi,ap3000m)
        addr0="$(mmc_get_mac_binary factory 0x04 2>/dev/null)"
        addr1="$(mmc_get_mac_binary factory 0x0a 2>/dev/null)"
        case "$addr0" in ""|00:00:00:*|02:00:00:10:00:*|ff:ff:ff:ff:ff:ff) addr0= ;; esac
        case "$addr1" in ""|00:00:00:*|02:00:00:10:00:*|ff:ff:ff:ff:ff:ff) addr1= ;; esac
        [ "$PHYNBR" = "0" ] && [ -n "$addr0" ] && echo "$addr0" > /sys${DEVPATH}/macaddress
        [ "$PHYNBR" = "1" ] && [ -n "$addr1" ] && echo "$addr1" > /sys${DEVPATH}/macaddress
        ;;'''

pat = re.compile(r'\n[ \t]*airpi,ap3000m\)\n.*?\n[ \t]*;;', re.S)

if pat.search(s):
    s = pat.sub("\n" + block, s, count=1)
else:
    m = re.search(r'\n[ \t]*[a-z0-9_-]+,[a-z0-9_.-]+\)\n', s)
    if not m:
        raise SystemExit("ERROR: cannot find insert point in 11_fix_wifi_mac")
    s = s[:m.start()] + "\n" + block + "\n" + s[m.start():]

p.write_text(s)
PY
fi

mkdir -p files/usr/sbin files/etc/uci-defaults

cat > files/usr/sbin/ap3000m-mtwifi-mac-sanitize <<'EOS'
#!/bin/sh

export IPKG_INSTROOT="${IPKG_INSTROOT:-}"
. /lib/functions/system.sh 2>/dev/null

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "airpi,ap3000m" ] || exit 0

LOCK="/tmp/ap3000m-mtwifi-mac-sanitize.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

M2="$(mmc_get_mac_binary factory 0x04 2>/dev/null)"
M5="$(mmc_get_mac_binary factory 0x0a 2>/dev/null)"
[ -n "$M2" ] && [ -n "$M5" ] || exit 0

M2N="$(macaddr_add "$M2" 1 2>/dev/null || echo "$M2")"
M5N="$(macaddr_add "$M5" 1 2>/dev/null || echo "$M5")"

set_unique() {
    f="$1"
    k="$2"
    v="$3"
    [ -f "$f" ] || return 0

    awk -F= -v k="$k" -v v="$v" '
        $1 == k {
            if (!seen) {
                print k "=" v
                seen = 1
            }
            next
        }
        { print }
        END {
            if (!seen) print k "=" v
        }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

B0="/etc/wireless/mediatek/mt7981.dbdc.b0.dat"
B1="/etc/wireless/mediatek/mt7981.dbdc.b1.dat"
DB="/etc/wireless/mediatek/DBDC_card0.dat"

set_unique "$B0" BssidNum 1
set_unique "$B0" MacAddress "$M2"
set_unique "$B0" MacAddress1 "$M2N"
set_unique "$B0" MacAddress2 "$M2N"

set_unique "$B1" BssidNum 1
set_unique "$B1" MacAddress "$M5"
set_unique "$B1" MacAddress1 "$M5N"
set_unique "$B1" MacAddress2 "$M5N"

set_unique "$DB" BssidNum 2
set_unique "$DB" MacAddress "$M2"
set_unique "$DB" MacAddress1 "$M5"
set_unique "$DB" MacAddress2 "$M5N"

# APCLI local MAC fix: avoid RT_CfgSetMacAddress invalid length(0).
set_unique "$B0" ApcliMacAddress "$M2N"
set_unique "$B1" ApcliMacAddress "$M5N"
set_unique "$DB" ApcliMacAddress "$M2N"
set_unique "$DB" ApcliMacAddress1 "$M5N"

logger -t ap3000m-mtwifi-mac-sanitize "v61-final 2G=$M2 5G=$M5"
sync
exit 0
EOS

chmod +x files/usr/sbin/ap3000m-mtwifi-mac-sanitize

cat > files/etc/uci-defaults/99-ap3000m-mtwifi-macaddr <<'EOS'
#!/bin/sh

export IPKG_INSTROOT="${IPKG_INSTROOT:-}"
. /lib/functions/system.sh 2>/dev/null

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "airpi,ap3000m" ] || exit 0

M2="$(mmc_get_mac_binary factory 0x04 2>/dev/null)"
M5="$(mmc_get_mac_binary factory 0x0a 2>/dev/null)"

[ -n "$M2" ] && [ -n "$M5" ] || exit 0

uci -q set wireless.default_MT7981_1_1.macaddr="$M2"
uci -q set wireless.default_MT7981_1_2.macaddr="$M5"
uci -q commit wireless

/usr/sbin/ap3000m-mtwifi-mac-sanitize 2>/dev/null || true

exit 0
EOS

chmod +x files/etc/uci-defaults/99-ap3000m-mtwifi-macaddr

cat > files/usr/sbin/ap3000m-bssid-check <<'EOS'
#!/bin/sh

export IPKG_INSTROOT="${IPKG_INSTROOT:-}"
. /lib/functions/system.sh 2>/dev/null

WIFI_NODE="/sys/firmware/devicetree/base/soc/wifi@18000000"

echo "board=$(cat /tmp/sysinfo/board_name 2>/dev/null)"

if [ -e "$WIFI_NODE/mediatek,eeprom-data" ]; then
    echo "BAD: runtime DTB has mediatek,eeprom-data"
else
    echo "OK: runtime DTB has no mediatek,eeprom-data"
fi

echo "factory_2g=$(mmc_get_mac_binary factory 0x04 2>/dev/null)"
echo "factory_5g=$(mmc_get_mac_binary factory 0x0a 2>/dev/null)"
echo "ra0=$(cat /sys/class/net/ra0/address 2>/dev/null)"
echo "rax0=$(cat /sys/class/net/rax0/address 2>/dev/null)"

echo "--- DBDC MAC ---"
grep -nE '^BssidNum=|^MacAddress=|^MacAddress1=|^MacAddress2=|^ApcliMacAddress=|^ApcliMacAddress1=' \
    /etc/wireless/mediatek/DBDC_card0.dat 2>/dev/null || true

echo "--- hook ---"
grep -n 'ap3000m-mtwifi-mac-sanitize\|save_profile(dats, profile)\|mtwifi_cfg_iwpriv_hook(cfg)' \
    /sbin/mtwifi_cfg 2>/dev/null || true
EOS

chmod +x files/usr/sbin/ap3000m-bssid-check

echo "== Patch mtwifi_cfg source =="

mapfile -t CFGS < <(
    grep -RIl 'function mtwifi_cfg_setup' package feeds target 2>/dev/null |
    while read -r f; do
        grep -q 'save_profile(dats, profile)' "$f" && echo "$f"
    done | sort -u
)

[ "${#CFGS[@]}" -gt 0 ] || {
    echo "ERROR: mtwifi_cfg source not found"
    exit 1
}

python3 - "${CFGS[@]}" <<'PY'
from pathlib import Path
import sys

hook1 = '    os.execute("/usr/sbin/ap3000m-mtwifi-mac-sanitize >/dev/null 2>&1")'
hook2 = '    os.execute("(sleep 5; /usr/sbin/ap3000m-mtwifi-mac-sanitize) >/dev/null 2>&1 &")'

for name in sys.argv[1:]:
    p = Path(name)
    lines = p.read_text().splitlines()

    out = []
    for line in lines:
        if "ap3000m-mtwifi-mac-sanitize" in line:
            continue

        out.append(line)

        if line.strip() == "save_profile(dats, profile)":
            out.append("")
            out.append(hook1)

        if line.strip() == "mtwifi_cfg_iwpriv_hook(cfg)":
            out.append("")
            out.append(hook2)

    p.write_text("\n".join(out) + "\n")
    print("MTWIFI_CFG_PATCHED=" + str(p))
PY

echo "== Verification =="

grep -RniE 'ap3000m-mtwifi-mac-sanitize|save_profile\(dats, profile\)|mtwifi_cfg_iwpriv_hook\(cfg\)' "${CFGS[@]}" || true

grep -RniE 'nvmem-cells = <&eeprom_factory_0>|mediatek,eeprom-data|&wifi' \
    target/linux/mediatek/dts/mt7981*airpi* \
    target/linux/mediatek/dts/mt7981*Airpi* 2>/dev/null || true

find files/usr/sbin files/etc/uci-defaults -maxdepth 3 -type f -print

echo "Airpi AP3000M WiFi BSSID fix v6.1-final applied."
