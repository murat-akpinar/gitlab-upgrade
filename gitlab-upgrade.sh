#!/usr/bin/env bash
set -Eeuo pipefail

# GitLab Otomatik Upgrade Script (tek node, Linux paketi)
# - Mevcut sürümü ve repodaki sürümleri okur
# - GitLab upgrade path'ine göre required stop'lardan geçerek yükseltir
# - Her adımdan önce batched background migration'ların bitmesini bekler
#
# Kaynaklar:
# https://docs.gitlab.com/update/upgrade_paths/
# https://docs.gitlab.com/update/background_migrations/
# https://docs.gitlab.com/update/package/

readonly BACKUP_ROOT="/opt"
readonly PACKAGE_NAME="gitlab-ce"
readonly VERSION_FILE="/opt/gitlab/embedded/service/gitlab-rails/VERSION"
readonly LOCK_FILE="/run/gitlab-upgrade.lock"
readonly BBM_WAIT_MINUTES="${BBM_WAIT_MINUTES:-120}"       # background migration bekleme üst sınırı
readonly READY_WAIT_MINUTES="${READY_WAIT_MINUTES:-15}"    # adım sonrası "hazır ol" bekleme üst sınırı
readonly READINESS_URL="${READINESS_URL:-http://127.0.0.1/-/readiness}"
readonly DISK_MARGIN_MB="${DISK_MARGIN_MB:-2048}"          # PG data kopyası + backup üstüne emniyet payı

log() { echo "$*"; }

# Hata anında sadece satır no değil, kurtarma bilgisini de bas.
on_error() {
  local line="$1" cur=""
  log ""
  log "❌ Hata: satır ${line} komutu başarısız oldu."
  [[ -r "$VERSION_FILE" ]] && cur="$(get_current_version 2>/dev/null || true)"
  if [[ -n "$cur" ]]; then
    log "ℹ️  Şu anki sürüm: $cur"
    log "ℹ️  Bu major'ın backup'ı: ${BACKUP_ROOT}/gitlab_backup_${cur%%.*}.x"
    log "ℹ️  Geri dönüş: aynı sürüme downgrade + 'gitlab-backup restore' (README > Rollback)."
  fi
  log "ℹ️  Sorunu giderince scripti tekrar çalıştırın; kaldığı sürümden devam eder."
}
trap 'on_error "$LINENO"' ERR

# 18.2.4-ce.0, 18.2.4-ce.0.el9, 18.2.4-ee -> 18.2.4
parse_version() { sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/' <<<"$1"; }

# $1 > $2 ?
version_gt() {
  local a b
  a="$(parse_version "$1")"; b="$(parse_version "$2")"
  [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

# Required stop minor'ları (docs.gitlab.com/update/upgrade_paths).
# Koşullu stop'lar da dahil edildi: fazladan bir adım, atlanmış bir stop'tan iyidir.
required_stops() {
  case "$1" in
    15) echo "0 1 4 11" ;;
    16) echo "0 1 2 3 7 11" ;;
    17) echo "1 3 5 8 11" ;;
    *)  echo "2 5 8 11" ;;   # 17.5+ politikası: x.2, x.5, x.8, x.11
  esac
}

# $1 = major.minor
is_required_stop() { [[ " $(required_stops "${1%%.*}") " == *" ${1#*.} "* ]]; }

get_versions_from_apt() {
  apt-get update -qq >/dev/null 2>&1 || true
  apt-cache madison "$PACKAGE_NAME" | awk '{print $3}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.0' | sort -u
}

get_versions_from_dnf() {
  dnf -q makecache >/dev/null 2>&1 || true
  # repoquery tüm sürümleri verir (dnf list sadece en yenisini gösterir); çıktı: 18.2.4-ce.0.el9
  dnf -q repoquery --qf '%{version}-%{release}' "$PACKAGE_NAME" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.0' | sort -u
}

# $1 = major.minor, kalan argümanlar = sürüm listesi -> o minor'ün en yeni patch'i
latest_patch_of() {
  local mm="$1"; shift
  printf '%s\n' "$@" | grep -E "^${mm//./\\.}\.[0-9]+-" | sort -V | tail -n1
}

# Sıradaki hedef: mevcuttan yeni en küçük major içinde, ilk required stop'a kadar (dahil) en yüksek minor.
# Örn: 17.11.2 -> 17.11.latest -> 18.2.latest -> 18.5.latest -> ... -> 18.11.latest -> 19.2.latest
find_next_version() {
  local current="$1"; shift
  local v mm mms=() target_mm=""
  for v in "$@"; do
    version_gt "$v" "$current" && mms+=("$(parse_version "$v" | cut -d. -f1,2)")
  done
  [[ ${#mms[@]} -eq 0 ]] && return 0
  mapfile -t mms < <(printf '%s\n' "${mms[@]}" | sort -t. -k1,1n -k2,2n -u)

  local target_major="${mms[0]%%.*}"
  for mm in "${mms[@]}"; do
    [[ "${mm%%.*}" == "$target_major" ]] || break
    target_mm="$mm"
    is_required_stop "$mm" && break
  done
  latest_patch_of "$target_mm" "$@"
}

pre_upgrade_checks() {
  local cur_major="${1%%.*}" target_major
  target_major="$(parse_version "$2" | cut -d. -f1)"
  if (( target_major > cur_major + 1 )); then
    log "❌ Repoda $((cur_major + 1)).x sürümleri yok; birden fazla major atlanamaz."
    exit 1
  fi
  # https://docs.gitlab.com/update/versions/gitlab_19_changes/
  if (( cur_major < 19 && target_major >= 19 )) && grep -Eq '^\s*mattermost' /etc/gitlab/gitlab.rb; then
    log "❌ GitLab 19 bundled Mattermost'u kaldırdı; önce gitlab.rb'deki mattermost ayarlarını temizleyin."
    exit 1
  fi
}

pending_background_migrations() {
  gitlab-psql -tAc "SELECT job_class_name || ' ' || table_name || '.' || column_name || ' [' ||
      CASE status WHEN 0 THEN 'paused' WHEN 1 THEN 'active' WHEN 4 THEN 'failed' WHEN 5 THEN 'finalizing' ELSE status::text END || ']'
    FROM batched_background_migrations WHERE status NOT IN (3, 6);"
}

# Docs: "All migrations must finish running before each upgrade."
wait_for_background_migrations() {
  local waited=0 pending
  while :; do
    pending="$(pending_background_migrations)" || { log "❌ batched_background_migrations sorgusu başarısız (PostgreSQL çalışıyor mu?)"; exit 1; }
    [[ -z "$pending" ]] && break
    log "⏳ Bitmemiş batched background migration var (${waited} sn beklendi):"
    log "$pending"
    if grep -q '\[failed\]' <<<"$pending"; then
      log "❌ Başarısız migration var. Admin > Monitoring > Background migrations ekranından retry edin."
      exit 1
    fi
    if (( waited >= BBM_WAIT_MINUTES * 60 )); then
      log "❌ ${BBM_WAIT_MINUTES} dk içinde bitmedi. Bitince scripti tekrar çalıştırın (BBM_WAIT_MINUTES ile süre artırılabilir)."
      exit 1
    fi
    sleep 60; waited=$((waited + 60))
  done
  log "✅ Bekleyen background migration yok."
}

backup_if_needed_for_major() {
  local major="${1%%.*}"
  local backup_dir="${BACKUP_ROOT}/gitlab_backup_${major}.x"
  local backup_marker="${backup_dir}/backup.done"
  mkdir -p "$backup_dir"

  if [[ -f "$backup_marker" ]]; then
    log "⏭️  Major ${major}.x için backup daha önce alınmış, yeniden alınmıyor."
  else
    log "📀  Major ${major}.x için backup alınıyor..."
    STRATEGY=copy gitlab-backup create   # canlı sistemde "file changed as we read it" hatasını önler

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
  cp /etc/gitlab/gitlab.rb /etc/gitlab/gitlab-secrets.json "$backup_dir/"
  log "📁  Backup dizini: $backup_dir"
}

# gitlab:check bir teşhis aracı; LDAP kapalı, geçici shell sürüm uyumsuzluğu gibi
# zararsız durumlarda non-zero döner. O yüzden bilgi amaçlı, upgrade'i DURDURMAZ.
# Sert kapı verify_running (servisler ayakta + uygulama hazır).
run_health_checks() {
  log "🔎 GitLab sağlık kontrolleri (bilgi amaçlı)..."
  gitlab-rake gitlab:check SANITIZE=true || log "⚠️  gitlab:check uyarı/hata döndürdü, log'u inceleyin."
  gitlab-rake gitlab:doctor:secrets || log "⚠️  doctor:secrets uyarı/hata döndürdü."
}

# Adım sonrası GERÇEK sağlık kapısı: hiçbir servis down değil ve uygulama isteğe cevap veriyor.
verify_running() {
  local waited=0 status http_ok
  while :; do
    status="$(gitlab-ctl status 2>&1 || true)"
    http_ok=1
    if command -v curl >/dev/null 2>&1; then
      curl -fsSk -o /dev/null --max-time 10 "$READINESS_URL" || http_ok=0
    fi
    if ! grep -qE '^(down|fail):' <<<"$status" && [[ "$http_ok" -eq 1 ]]; then
      log "✅ Servisler ayakta ve uygulama hazır."
      return 0
    fi
    if (( waited >= READY_WAIT_MINUTES * 60 )); then
      log "❌ ${READY_WAIT_MINUTES} dk içinde hazır olmadı. Servis durumu:"
      log "$status"
      exit 1
    fi
    log "⏳ Uygulamanın hazır olması bekleniyor (${waited} sn)..."
    sleep 15; waited=$((waited + 15))
  done
}

# Diski dolu bırakıp yarıda kırılmaktan iyidir: baştan, temiz halde dur.
# ponytail: en sıkı kısıt PG data dizininin kopyası (pg-upgrade). Tam backup boyutu
#           projekte edilmez; gitlab-backup zaten ENOSPC'de temiz hata verir.
ensure_disk_space() {
  local dir="/var/opt/gitlab" pg_mb free_mb need_mb
  pg_mb="$(du -sm /var/opt/gitlab/postgresql 2>/dev/null | cut -f1)"; pg_mb="${pg_mb:-0}"
  free_mb="$(df -Pm "$dir" | awk 'NR==2 {print $4}')"
  need_mb=$(( pg_mb + DISK_MARGIN_MB ))
  if (( free_mb < need_mb )); then
    log "❌ Yetersiz disk: $dir üzerinde ${free_mb}MB boş, ~${need_mb}MB gerekiyor (PG data ${pg_mb}MB + pay)."
    exit 1
  fi
}

upgrade_once() {
  local target="$1"
  log "🚩 Hedef sürüm: $target"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y "${PACKAGE_NAME}=${target}"
  else
    dnf install -y "${PACKAGE_NAME}-${target}"
  fi
  # Paket kurulumu gitlab-ctl upgrade'i (reconfigure + db:migrate + restart) kendisi çalıştırır.
  verify_running        # sert kapı
  run_health_checks     # bilgi amaçlı
}

get_current_version() { parse_version "$(<"$VERSION_FILE")"; }

main() {
  [[ $EUID -eq 0 ]] || { log "❌ Root olarak çalıştırın."; exit 1; }
  [[ -r "$VERSION_FILE" ]] || { log "❌ GitLab kurulu görünmüyor: $VERSION_FILE yok."; exit 1; }
  if [[ -e /etc/gitlab/skip-auto-reconfigure ]]; then
    log "❌ /etc/gitlab/skip-auto-reconfigure var; bu script paketin otomatik reconfigure'üne dayanır. Dosyayı kaldırın."
    exit 1
  fi

  # Aynı anda ikinci kopya = iki apt/reconfigure = bozulma. Kilitle.
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "❌ Script zaten çalışıyor (lock: $LOCK_FILE). İkinci kopya reddedildi."
    exit 1
  fi

  log "🔍 Mevcut versiyon okunuyor..."
  local current_version start_version
  current_version="$(get_current_version)"
  start_version="$current_version"
  log "✅ Mevcut versiyon: $current_version"
  (( ${current_version%%.*} >= 15 )) || { log "❌ 15.0 öncesi sürümler desteklenmiyor."; exit 1; }

  log "📦 Repo'daki uygun sürümler listeleniyor..."
  local available_versions=()
  if command -v apt-get >/dev/null 2>&1; then
    mapfile -t available_versions < <(get_versions_from_apt)
  elif command -v dnf >/dev/null 2>&1; then
    mapfile -t available_versions < <(get_versions_from_dnf)
  else
    log "❌ Desteklenmeyen paket yöneticisi!"
    exit 1
  fi
  (( ${#available_versions[@]} > 0 )) || { log "❌ Repo'dan versiyon bilgisi alınamadı."; exit 1; }
  log "📋 Bulunan versiyon sayısı: ${#available_versions[@]}"

  run_health_checks

  local step=0 next_version
  while next_version="$(find_next_version "$current_version" "${available_versions[@]}")"; [[ -n "$next_version" ]]; do
    ((++step))
    log ""
    log "=============================="
    log "🔄 Upgrade adımı #$step"
    log "   $current_version -> $next_version"
    log "=============================="

    pre_upgrade_checks "$current_version" "$next_version"
    ensure_disk_space
    backup_if_needed_for_major "$current_version"
    wait_for_background_migrations
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
