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
readonly SKIP_BACKUP="${SKIP_BACKUP:-0}"                   # 1: gitlab-backup alma (VM snapshot aldıysanız)
readonly LOG_DIR="${LOG_DIR:-/var/log/gitlab-upgrade}"     # script kendi log dosyasını buraya yazar
export DEBIAN_FRONTEND=noninteractive
LOG_FILE=""

log() { echo "$(date '+%F %T') $*"; }

# Her çıkışta (hata, exit 1, Ctrl-C) kurtarma bilgisini bas; başarıda sessiz.
on_exit() {
  local rc="$1" cur=""
  (( rc == 0 )) && return 0
  log ""
  log "❌ Script hata ile bitti (exit $rc)."
  [[ -r "$VERSION_FILE" ]] && cur="$(get_current_version 2>/dev/null || true)"
  if [[ -n "$cur" ]]; then
    log "ℹ️  Şu anki sürüm: $cur"
    log "ℹ️  Bu major'ın backup'ı: ${BACKUP_ROOT}/gitlab_backup_${cur%%.*}.x"
    log "ℹ️  Geri dönüş: aynı sürüme downgrade + 'gitlab-backup restore' (README > Rollback)."
  fi
  log "ℹ️  Sorunu giderince scripti tekrar çalıştırın; kaldığı sürümden devam eder."
  [[ -n "$LOG_FILE" ]] && log "ℹ️  Log dosyası: $LOG_FILE"
}
trap 'log "❌ Hata: satır $LINENO komutu başarısız oldu."' ERR

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
    # 18.3: resmi stop değil; 18.2.x'teki BackfillSentNotificationsAfterPartition hatasını 18.3.6+ düzeltir.
    # https://support.gitlab.com/hc/en-us/articles/27692688410140
    18) echo "2 3 5 8 11" ;;
    *)  echo "2 5 8 11" ;;   # 17.5+ politikası: x.2, x.5, x.8, x.11
  esac
}

# $1 = major.minor
is_required_stop() { [[ " $(required_stops "${1%%.*}") " == *" ${1#*.} "* ]]; }

# GitLab paket deposu ekli mi? Değilse apt/dnf sadece eski/cache'li sürümleri gösterir.
ensure_gitlab_repo() {
  if command -v apt-get >/dev/null 2>&1; then
    grep -rqs 'packages.gitlab.com' /etc/apt/sources.list /etc/apt/sources.list.d/ && return 0
  else
    grep -rqs 'packages.gitlab.com' /etc/yum.repos.d/ && return 0
  fi
  log "❌ GitLab paket deposu ekli değil (packages.gitlab.com bulunamadı). README > Kullanım'daki repo kurulum komutunu çalıştırın."
  exit 1
}

# Yarım kalmış kurulum: paket açılmış ama postinst (gitlab-ctl upgrade) bitmemişse VERSION dosyası
# yeni sürümü gösterir ve script bir sonraki adıma geçmeye kalkar. Önce onu tamamlatalım.
ensure_package_consistent() {
  local st down
  if command -v dpkg >/dev/null 2>&1; then
    st="$(dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null || true)"
    if [[ "$st" != "install ok installed" ]]; then
      log "❌ ${PACKAGE_NAME} paketi tutarsız durumda (dpkg: '${st:-yok}'). Önce 'dpkg --configure -a' çalıştırıp sonucu inceleyin."
      exit 1
    fi
  elif ! rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    log "❌ ${PACKAGE_NAME} paketi rpm veritabanında yok."
    exit 1
  fi
  down="$(gitlab-rake db:migrate:status 2>/dev/null | grep -cE '^\s*down' || true)"
  if (( down > 0 )); then
    log "❌ ${down} adet uygulanmamış DB migration var (db:migrate:status). Önce 'gitlab-ctl upgrade' ile tamamlayın."
    exit 1
  fi
}

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
  assert_no_skipped_stop "$current" "$target_mm" "${mms[@]}" || return 1
  latest_patch_of "$target_mm" "$@"
}

# Repoda eksik bir required stop'un üstünden atlanmasın (örn. depoda 18.5 yok ama 18.8 var).
# $1 = mevcut sürüm, $2 = hedef major.minor, kalan = repodaki major.minor listesi
assert_no_skipped_stop() {
  local current="$1" target_mm="$2"; shift 2
  local cur_major="${current%%.*}" cur_minor; cur_minor="$(cut -d. -f2 <<<"$current")"
  local target_major="${target_mm%%.*}" target_minor="${target_mm#*.}" s lower

  if (( target_major > cur_major )); then
    # Major geçişi: mevcut major'ın kalan stop'ları da geçilmiş olmalı
    for s in $(required_stops "$cur_major"); do
      (( s > cur_minor )) || continue
      log "❌ Required stop ${cur_major}.${s} repoda yok; ${current} -> ${target_mm} geçişi upgrade path'i ihlal eder." >&2
      return 1
    done
    lower=-1
  else
    lower="$cur_minor"
  fi
  for s in $(required_stops "$target_major"); do
    (( s > lower && s < target_minor )) || continue
    [[ " $* " == *" ${target_major}.${s} "* ]] && continue
    log "❌ Required stop ${target_major}.${s} repoda yok; ${current} -> ${target_mm} geçişi upgrade path'i ihlal eder." >&2
    return 1
  done
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
    log "❌ GitLab 19 bundled Mattermost'u kaldırdı; gitlab.rb'deki tüm mattermost satırlarını (enable=false olsa bile) silin."
    exit 1
  fi
}

pending_background_migrations() {
  gitlab-psql -tAc "SELECT job_class_name || ' ' || table_name || '.' || column_name || ' [' ||
      CASE status WHEN 0 THEN 'paused' WHEN 1 THEN 'active' WHEN 4 THEN 'failed' WHEN 5 THEN 'finalizing' ELSE status::text END || ']'
    FROM batched_background_migrations WHERE status NOT IN (3, 6);"
}

# Docs: "All migrations must finish running before each upgrade."
# $1 = mevcut sürüm
wait_for_background_migrations() {
  local waited=0 pending
  while :; do
    pending="$(pending_background_migrations)" || { log "❌ batched_background_migrations sorgusu başarısız (PostgreSQL çalışıyor mu?)"; exit 1; }
    # Bilinen 18.2.x hatası (partition eksik): retry ile geçmez, 18.3.6+ temizleyip yeniden planlar. GitLab: yok sayılabilir.
    if [[ "$1" == 18.2.* ]] && grep -q '^BackfillSentNotificationsAfterPartition .*\[failed\]$' <<<"$pending"; then
      log "⚠️  BackfillSentNotificationsAfterPartition [failed] bilinen 18.2 hatası; 18.3 düzeltecek, yok sayılıyor."
      pending="$(grep -v '^BackfillSentNotificationsAfterPartition .*\[failed\]$' <<<"$pending" || true)"
    fi
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
  chmod 700 "$backup_dir"   # gitlab-secrets.json buraya kopyalanıyor; başkası okumasın

  if [[ -f "$backup_marker" ]]; then
    log "⏭️  Major ${major}.x için backup daha önce alınmış, yeniden alınmıyor."
  elif [[ "$SKIP_BACKUP" == "1" ]]; then
    log "⏭️  SKIP_BACKUP=1: gitlab-backup atlanıyor (snapshot'ınız olduğundan emin olun)."
  else
    log "📀  Major ${major}.x için backup alınıyor..."
    STRATEGY=copy gitlab-backup create   # canlı sistemde "file changed as we read it" hatasını önler

    local backup_path backup_file
    backup_path="$(gitlab-rails runner 'puts Gitlab.config.backup.path' 2>/dev/null | tail -n1)"
    backup_path="${backup_path:-/var/opt/gitlab/backups}"
    backup_file="$(ls -1 "$backup_path"/*_gitlab_backup.tar 2>/dev/null | sort | tail -n1 || true)"
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
      log "❌ Backup dosyası bulunamadı."
      exit 1
    fi
    if [[ "$(stat -c%s "$backup_file")" -lt 102400 ]]; then
      log "❌ Backup dosyası şüpheli derecede küçük: $backup_file"
      exit 1
    fi
    cp -p "$backup_file" "$backup_dir/"
    touch "$backup_marker"
  fi

  # Config dosyalarını her adımda güncelle (-p: secrets 600 kalsın)
  cp -p /etc/gitlab/gitlab.rb /etc/gitlab/gitlab-secrets.json "$backup_dir/"
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
      [[ "$(curl -sSkL -o /dev/null -w '%{http_code}' --max-time 10 "$READINESS_URL" 2>/dev/null)" == "200" ]] || http_ok=0
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
# /var/opt/gitlab: PG data kopyası (pg-upgrade) + backup tar'ı (≈ repo + uploads + DB dump).
# BACKUP_ROOT: backup tar'ının kopyası. İkisi aynı diskteyse ihtiyaçlar toplanır.
# $1 = 1 ise bu adımda backup alınacak, backup payı hesaba katılır.
ensure_disk_space() {
  local with_backup="${1:-0}" pg_mb data_mb=0 free_var free_opt need_var need_opt
  pg_mb="$(du -sm /var/opt/gitlab/postgresql 2>/dev/null | cut -f1)"; pg_mb="${pg_mb:-0}"
  if [[ "$with_backup" == "1" ]]; then
    data_mb="$(du -smc /var/opt/gitlab/git-data /var/opt/gitlab/gitlab-rails/uploads 2>/dev/null | tail -n1 | cut -f1)"
    data_mb="${data_mb:-0}"
  fi
  free_var="$(df -Pm /var/opt/gitlab | awk 'NR==2 {print $4}')"
  free_opt="$(df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
  need_var=$(( pg_mb + data_mb + DISK_MARGIN_MB ))
  need_opt=$(( data_mb + DISK_MARGIN_MB ))
  if [[ "$(df -P /var/opt/gitlab | awk 'NR==2 {print $1}')" == "$(df -P "$BACKUP_ROOT" | awk 'NR==2 {print $1}')" ]]; then
    need_var=$(( need_var + data_mb ))   # aynı disk: BACKUP_ROOT kopyası da buradan çıkacak
    need_opt=0
  fi
  if (( free_var < need_var )); then
    log "❌ Yetersiz disk: /var/opt/gitlab üzerinde ${free_var}MB boş, ~${need_var}MB gerekiyor (PG ${pg_mb}MB + backup ${data_mb}MB + pay)."
    exit 1
  fi
  if (( free_opt < need_opt )); then
    log "❌ Yetersiz disk: ${BACKUP_ROOT} üzerinde ${free_opt}MB boş, backup kopyası için ~${need_opt}MB gerekiyor."
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

  # Tüm çıktı hem ekrana hem log dosyasına
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/upgrade_$(date +%F_%H-%M-%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'on_exit "$?"' EXIT
  log "📝 Log dosyası: $LOG_FILE"

  ensure_gitlab_repo
  ensure_package_consistent

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
  while :; do
    next_version="$(find_next_version "$current_version" "${available_versions[@]}")" || exit 1
    [[ -n "$next_version" ]] || break
    ((++step))
    log ""
    log "=============================="
    log "🔄 Upgrade adımı #$step"
    log "   $current_version -> $next_version"
    log "=============================="

    pre_upgrade_checks "$current_version" "$next_version"
    if [[ "$SKIP_BACKUP" != "1" && ! -f "${BACKUP_ROOT}/gitlab_backup_${current_version%%.*}.x/backup.done" ]]; then
      ensure_disk_space 1
    else
      ensure_disk_space 0
    fi
    backup_if_needed_for_major "$current_version"
    wait_for_background_migrations "$current_version"
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
