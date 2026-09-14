#!/usr/bin/env bash
# find_next_version için tek kontrol: sentetik repo listesiyle beklenen upgrade path'i üretiyor mu?
# Çalıştır: bash test_upgrade_path.sh
set -euo pipefail
source "$(dirname "$0")/gitlab-upgrade.sh"

# apt-cache madison benzeri, karışık sıralı sentetik liste
repo=(
  16.11.10-ce.0 17.0.8-ce.0 17.1.8-ce.0 17.2.9-ce.0 17.3.7-ce.0 17.4.6-ce.0 17.5.5-ce.0
  17.8.7-ce.0 17.10.8-ce.0 17.11.2-ce.0 17.11.7-ce.0 17.11.10-ce.0
  18.0.0-ce.0 18.0.6-ce.0 18.1.5-ce.0 18.2.4-ce.0 18.2.10-ce.0 18.3.5-ce.0 18.4.3-ce.0
  18.5.6-ce.0 18.6.4-ce.0 18.8.5-ce.0 18.9.3-ce.0 18.11.4-ce.0
  19.0.3-ce.0 19.1.2-ce.0 19.2.5-ce.0 19.3.1-ce.0 19.4.0-ce.0
)

path_from() {
  local cur="$1" next out=()
  while next="$(find_next_version "$cur" "${repo[@]}")"; [[ -n "$next" ]]; do
    out+=("$next"); cur="$next"
  done
  echo "${out[*]}"
}

check() {
  local got; got="$(path_from "$1")"
  [[ "$got" == "$2" ]] || { echo "FAIL from $1"; echo "  beklenen: $2"; echo "  gelen:    $got"; exit 1; }
  echo "ok  $1 -> $got"
}

# 17.x: 17.1 (koşullu), 17.3, 17.5, 17.8, 17.11 stop; 17.2 stop değil
check 17.0.8 "17.1.8-ce.0 17.3.7-ce.0 17.5.5-ce.0 17.8.7-ce.0 17.11.10-ce.0 18.2.10-ce.0 18.5.6-ce.0 18.8.5-ce.0 18.11.4-ce.0 19.2.5-ce.0 19.4.0-ce.0"
# Stop minor'undaysa önce o minor'ün en yeni patch'i, majör geçişte 18.0 değil doğrudan 18.2.latest
check 17.11.2 "17.11.10-ce.0 18.2.10-ce.0 18.5.6-ce.0 18.8.5-ce.0 18.11.4-ce.0 19.2.5-ce.0 19.4.0-ce.0"
# Stop olmayan minor'dan sıradaki stop'a; 18.3.5 patch'i atlanır
check 18.3.1 "18.5.6-ce.0 18.8.5-ce.0 18.11.4-ce.0 19.2.5-ce.0 19.4.0-ce.0"
# Henüz sonraki stop çıkmamışsa mevcut en yüksek minor
check 19.2.5 "19.4.0-ce.0"
check 19.4.0 ""
# dnf formatı (.el9) da aynı çalışmalı
repo=(18.11.4-ce.0.el9 19.0.3-ce.0.el9 19.2.1-ce.0.el9 19.2.5-ce.0.el9)
check 18.11.4 "19.2.5-ce.0.el9"
echo "ALL OK (path)"

# Repoda eksik required stop sessizce atlanmamalı: hata ver (exit != 0, boş çıktı)
expect_fail() {
  local out; out="$(find_next_version "$1" "${repo[@]}" 2>/dev/null)" && { echo "FAIL from $1: hata beklenirdi, gelen: $out"; exit 1; }
  echo "ok  $1 -> hata (eksik stop)"
}
# 18.5 repoda yok ama 18.8 var -> 18.2'den 18.8'e atlanmamalı
repo=(18.2.8-ce.0 18.3.5-ce.0 18.8.11-ce.0 18.11.11-ce.0)
expect_fail 18.2.8
# 17.11 repoda yok ama 18.2 var -> 17.10'dan major geçilmemeli
repo=(17.10.8-ce.0 18.2.8-ce.0)
expect_fail 17.10.8
# Stop henüz yayınlanmamışsa (repoda ondan yenisi de yok) en yüksek minor'a gitmek serbest
repo=(19.2.5-ce.0 19.3.1-ce.0 19.4.0-ce.0)
check 19.2.5 "19.4.0-ce.0"
# Bir sonraki major yoksa (Ubuntu 20.04'te 19.x yok) x.11'de dur
repo=(18.11.4-ce.0)
check 18.11.4 ""
echo "ALL OK (stop kontrolleri)"
