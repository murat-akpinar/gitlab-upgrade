#!/usr/bin/env bash
set -Eeuo pipefail

# GitLab Otomatik Upgrade Script
# - Repo'dan otomatik versiyon tespiti
# - Required stop (x.2, x.5, x.8, x.11) mantığı
# - Tek adım yerine tüm gerekli adımları döngüde uygular
#
# Kaynak:
# https://docs.gitlab.com/ee/update/upgrade_paths/

trap 'echo "❌ Hata: satır $LINENO komutu başarısız oldu." >&2' ERR

readonly REQUIRED_STOP_MINORS=(2 5 8 11)
readonly BACKUP_ROOT="/opt"
readonly PACKAGE_NAME="gitlab-ce"

log() { echo "$*"; }

parse_version() {
  local version="$1"
  # 18.2.4-ce.0, 18.2.4-ee.0, 18.2.4-ce.0.el9 vb. formatlardan 18.2.4 çıkar
  echo "$version" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

normalize_current_version() {
  local raw="$1"
  if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${raw}-ce.0"
  elif [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.0.*$ ]]; then
    echo "$raw"
  else
    # Beklenmeyen formatı da yine parse edilebilir hale getir.
    echo "$(parse_version "$raw")-ce.0"
  fi
}

compare_versions() {
  local v1 v2
  v1="$(parse_version "$1")"
  v2="$(parse_version "$2")"

  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$v1" gt "$v2"
  elif command -v rpmdev-vercmp >/dev/null 2>&1; then
    rpmdev-vercmp "$v1" "$v2" | awk '/^>/ {found=1} END {exit(found?0:1)}'
  else
    # sort -V fallback
    [[ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -n1)" == "$v1" && "$v1" != "$v2" ]]
  fi
}

is_required_stop() {
  local version="$1"
  local parsed minor
  parsed="$(parse_version "$version")"
  minor="$(echo "$parsed" | cut -d. -f2)"

  for stop_minor in "${REQUIRED_STOP_MINORS[@]}"; do
    if [[ "$minor" == "$stop_minor" ]]; then
      return 0
    fi
  done
  return 1
}

get_versions_from_apt() {
  apt update >/dev/null 2>&1 || true
  apt-cache madison "$PACKAGE_NAME" 2>/dev/null \
    | awk '{print $3}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.0' \
    | sort -u
}

get_versions_from_dnf() {
  dnf clean all >/dev/null 2>&1 || true
  dnf list available "$PACKAGE_NAME" 2>/dev/null \
    | awk -v pkg="$PACKAGE_NAME" '$1 ~ "^"pkg {print $2}' \
    | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.0).*/\1/' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.0$' \
    | sort -u
}

get_latest_patch_for_minor() {
  local target_minor="$1"
  shift

  local latest=""
  local version parsed major_minor
  for version in "$@"; do
    parsed="$(parse_version "$version")"
    major_minor="$(echo "$parsed" | cut -d. -f1,2)"
    if [[ "$major_minor" == "$target_minor" ]]; then
      if [[ -z "$latest" ]] || compare_versions "$version" "$latest"; then
        latest="$version"
      fi
    fi
  done

  [[ -n "$latest" ]] && echo "$latest"
}

find_next_version() {
  local current_version="$1"
  shift
  local available_versions=("$@")

  local current_parsed current_major current_minor
  current_parsed="$(parse_version "$current_version")"
  current_major="$(echo "$current_parsed" | cut -d. -f1)"
  current_minor="$(echo "$current_parsed" | cut -d. -f2)"

  local greater_versions=()
  local version parsed major minor
  for version in "${available_versions[@]}"; do
    if compare_versions "$version" "$current_version"; then
      greater_versions+=("$version")
    fi
  done

  [[ ${#greater_versions[@]} -eq 0 ]] && return 0

  local same_major_versions=()
  for version in "${greater_versions[@]}"; do
    parsed="$(parse_version "$version")"
    major="$(echo "$parsed" | cut -d. -f1)"
    [[ "$major" == "$current_major" ]] && same_major_versions+=("$version")
  done

  if [[ ${#same_major_versions[@]} -gt 0 ]]; then
    # Aynı major içinde bir required stop varsa en yakın stop'un en son patch'i
    local closest_required_stop=""
    for version in "${same_major_versions[@]}"; do
      if is_required_stop "$version"; then
        if [[ -z "$closest_required_stop" ]] || compare_versions "$closest_required_stop" "$version"; then
          closest_required_stop="$version"
        fi
      fi
    done

    if [[ -n "$closest_required_stop" ]]; then
      local required_mm required_latest
      required_mm="$(parse_version "$closest_required_stop" | cut -d. -f1,2)"
      required_latest="$(get_latest_patch_for_minor "$required_mm" "${same_major_versions[@]}")"
      [[ -n "$required_latest" ]] && { echo "$required_latest"; return 0; }
    fi

    # Required stop yoksa bir sonraki minore çık
    local next_minor_version=""
    local next_minor=999
    for version in "${same_major_versions[@]}"; do
      parsed="$(parse_version "$version")"
      minor="$(echo "$parsed" | cut -d. -f2)"
      if [[ "$minor" -gt "$current_minor" && "$minor" -lt "$next_minor" ]]; then
        next_minor="$minor"
        next_minor_version="$version"
      fi
    done

    if [[ -n "$next_minor_version" ]]; then
      local next_mm next_latest
      next_mm="$(parse_version "$next_minor_version" | cut -d. -f1,2)"
      next_latest="$(get_latest_patch_for_minor "$next_mm" "${same_major_versions[@]}")"
      [[ -n "$next_latest" ]] && { echo "$next_latest"; return 0; }
    fi
  fi

  # Yeni major varsa önce bu major'ün required stop'una ulaşmayı dene
  local current_major_required_latest=""
  for version in "${greater_versions[@]}"; do
    parsed="$(parse_version "$version")"
    major="$(echo "$parsed" | cut -d. -f1)"
    if [[ "$major" == "$current_major" ]] && is_required_stop "$version"; then
      if [[ -z "$current_major_required_latest" ]] || compare_versions "$version" "$current_major_required_latest"; then
        current_major_required_latest="$version"
      fi
    fi
  done

  if [[ -n "$current_major_required_latest" ]]; then
    local cur_req_mm cur_req_latest
    cur_req_mm="$(parse_version "$current_major_required_latest" | cut -d. -f1,2)"
    cur_req_latest="$(get_latest_patch_for_minor "$cur_req_mm" "${greater_versions[@]}")"
    [[ -n "$cur_req_latest" ]] && { echo "$cur_req_latest"; return 0; }
  fi

  # En küçük büyük versiyon fallback
  local smallest=""
  for version in "${greater_versions[@]}"; do
    if [[ -z "$smallest" ]] || compare_versions "$smallest" "$version"; then
      smallest="$version"
    fi
  done
  [[ -n "$smallest" ]] && echo "$smallest"
}

backup_if_needed_for_major() {
  local current_version="$1"
  local major backup_dir backup_marker
  major="$(parse_version "$current_version" | cut -d. -f1)"
  backup_dir="${BACKUP_ROOT}/gitlab_backup_${major}.x"
  backup_marker="${backup_dir}/backup.done"

  mkdir -p "$backup_dir"

  if [[ -f "$backup_marker" ]]; then
    log "⏭️  Major ${major}.x için backup daha önce alınmış, yeniden alınmıyor."
  else
    log "📀  Major ${major}.x için backup alınıyor..."
    gitlab-backup create

    local backup_file
    backup_file="$(ls -1 /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | sort | tail -n1 || true)"
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
      log "❌ Backup dosyası bulunamadı."
      exit 1
    fi

    if [[ "$(stat -c%s "$backup_file")" -lt 102400 ]]; then
      log "❌ Backup dosyası şüpheli derecede küçük: $backup_file"
      exit 1
    fi

    cp "$backup_file" "$backup_dir/"
    touch "$backup_marker"
  fi

  # Config dosyalarını her adımda güncelle
  cp /etc/gitlab/gitlab.rb "$backup_dir/"
  cp /etc/gitlab/gitlab-secrets.json "$backup_dir/"
  log "📁  Backup dizini: $backup_dir"
}

run_health_checks() {
  log "🔎 GitLab sağlık kontrolleri çalıştırılıyor..."
  gitlab-rake gitlab:check
  gitlab-rake gitlab:doctor:secrets
}

install_target_version() {
  local target="$1"
  if command -v apt >/dev/null 2>&1; then
    apt update >/dev/null 2>&1 || true
    apt install -y "${PACKAGE_NAME}=${target}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf clean all >/dev/null 2>&1 || true
    dnf install -y "${PACKAGE_NAME}-${target}.el9" || dnf install -y "${PACKAGE_NAME}-${target}"
  else
    log "❌ Desteklenmeyen paket yöneticisi!"
    exit 1
  fi
}

upgrade_once() {
  local target="$1"
  log "🚩 Hedef sürüm: $target"
  install_target_version "$target"
  gitlab-ctl reconfigure
  gitlab-ctl upgrade
  gitlab-ctl restart
  run_health_checks
}

get_current_version() {
  local raw
  raw="$(gitlab-rake gitlab:env:info 2>/dev/null | awk '/^GitLab information/,/^GitLab Shell/ {if ($1 == "Version:") print $2}')"
  if [[ -z "${raw:-}" ]]; then
    log "❌ Mevcut GitLab versiyonu okunamadı."
    exit 1
  fi
  normalize_current_version "$raw"
}

main() {
  log "🔍 Mevcut versiyon okunuyor..."
  local current_version start_version
  current_version="$(get_current_version)"
  start_version="$current_version"
  log "✅ Mevcut versiyon: $current_version"

  log "📦 Repo'daki uygun sürümler listeleniyor..."
  local available_versions=()
  local version
  if command -v apt >/dev/null 2>&1; then
    while IFS= read -r version; do
      [[ -n "$version" ]] && available_versions+=("$version")
    done < <(get_versions_from_apt)
  elif command -v dnf >/dev/null 2>&1; then
    while IFS= read -r version; do
      [[ -n "$version" ]] && available_versions+=("$version")
    done < <(get_versions_from_dnf)
  else
    log "❌ Desteklenmeyen paket yöneticisi!"
    exit 1
  fi

  if [[ ${#available_versions[@]} -eq 0 ]]; then
    log "❌ Repo'dan versiyon bilgisi alınamadı."
    exit 1
  fi
  log "📋 Bulunan versiyon sayısı: ${#available_versions[@]}"

  local step=0 next_version
  while true; do
    next_version="$(find_next_version "$current_version" "${available_versions[@]}")"
    if [[ -z "${next_version:-}" ]]; then
      break
    fi

    ((step += 1))
    log ""
    log "=============================="
    log "🔄 Upgrade adımı #$step"
    log "   $current_version -> $next_version"
    log "=============================="

    backup_if_needed_for_major "$current_version"
    run_health_checks
    upgrade_once "$next_version"

    current_version="$(get_current_version)"
    log "✅ Adım tamamlandı. Yeni sürüm: $current_version"
  done

  log ""
  log "🛠  Lütfen aşağıdaki testleri manuel yapın:"
  log "- 🔐 Web UI kullanıcı girişi"
  log "- 📁 Proje ve issue erişimi"
  log "- 🔄 Git clone/push testi"
  log ""
  log "🚀 Sonuç"
  if [[ "$start_version" == "$current_version" ]]; then
    log "ℹ️  Uygun yeni sürüm bulunamadı: $current_version"
  else
    log "🎉 Yükseltme tamamlandı: $start_version -> $current_version"
  fi
}

main "$@"
