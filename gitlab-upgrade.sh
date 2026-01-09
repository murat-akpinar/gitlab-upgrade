#!/bin/bash
set -e

# GitLab Otomatik Upgrade Script
# Repo'dan otomatik versiyon tespiti ve required upgrade stops mantığı
# Kaynak: https://docs.gitlab.com/ee/update/upgrade_paths/

# Fonksiyon: Required stop kontrolü (GitLab 17.5+ için: x.2.z, x.5.z, x.8.z, x.11.z)
is_required_stop() {
  local version="$1"
  local minor=$(echo "$version" | cut -d. -f2)
  [[ "$minor" == "2" || "$minor" == "5" || "$minor" == "8" || "$minor" == "11" ]]
}

# Fonksiyon: Versiyon parse et (MAJOR.MINOR.PATCH-ce.0 formatından)
parse_version() {
  local version="$1"
  echo "$version" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)-ce\.0.*/\1/'
}

# Fonksiyon: Versiyon karşılaştır
compare_versions() {
  local v1="$1"
  local v2="$2"
  
  if command -v dpkg &>/dev/null; then
    dpkg --compare-versions "$v1" gt "$v2" && return 0 || return 1
  elif command -v rpmdev-vercmp &>/dev/null; then
    rpmdev-vercmp "$v1" "$v2" | grep -q ">" && return 0 || return 1
  else
    # Manuel karşılaştırma (basit)
    local v1_major=$(echo "$v1" | cut -d. -f1)
    local v1_minor=$(echo "$v1" | cut -d. -f2)
    local v1_patch=$(echo "$v1" | cut -d. -f3 | cut -d- -f1)
    local v2_major=$(echo "$v2" | cut -d. -f1)
    local v2_minor=$(echo "$v2" | cut -d. -f2)
    local v2_patch=$(echo "$v2" | cut -d. -f3 | cut -d- -f1)
    
    if [[ $v1_major -gt $v2_major ]]; then return 0
    elif [[ $v1_major -lt $v2_major ]]; then return 1
    elif [[ $v1_minor -gt $v2_minor ]]; then return 0
    elif [[ $v1_minor -lt $v2_minor ]]; then return 1
    elif [[ $v1_patch -gt $v2_patch ]]; then return 0
    else return 1
    fi
  fi
}

# Fonksiyon: Repo'dan versiyonları çek (apt)
get_versions_from_apt() {
  apt update &>/dev/null || true
  apt-cache madison gitlab-ce 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0' | sort -u
}

# Fonksiyon: Repo'dan versiyonları çek (dnf)
get_versions_from_dnf() {
  dnf clean all &>/dev/null || true
  dnf list available gitlab-ce 2>/dev/null | grep -E '^gitlab-ce\s' | awk '{print $2}' | sed 's/-ce\.0.*/-ce.0/' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0' | sort -u
}

# Fonksiyon: Belirli minor versiyon için en son patch'i bul
get_latest_patch_for_minor() {
  local target_minor="$1"  # Örn: "18.2"
  local available_versions=("${@:2}")
  local latest=""
  
  for version in "${available_versions[@]}"; do
    local parsed=$(parse_version "$version")
    local major_minor=$(echo "$parsed" | cut -d. -f1,2)
    
    if [[ "$major_minor" == "$target_minor" ]]; then
      if [[ -z "$latest" ]] || compare_versions "$version" "$latest"; then
        latest="$version"
      fi
    fi
  done
  
  [[ -n "$latest" ]] && echo "$latest"
}

# Fonksiyon: Sonraki versiyonu belirle
find_next_version() {
  local current_version="$1"
  local available_versions=("${@:2}")
  
  # Mevcut versiyonun major ve minor'unu çıkar
  local current_parsed=$(parse_version "$current_version")
  local current_major=$(echo "$current_parsed" | cut -d. -f1)
  local current_minor=$(echo "$current_parsed" | cut -d. -f2)
  
  # CURRENT_VERSION'dan büyük versiyonları filtrele
  local greater_versions=()
  for version in "${available_versions[@]}"; do
    if compare_versions "$version" "$current_version"; then
      greater_versions+=("$version")
    fi
  done
  
  if [[ ${#greater_versions[@]} -eq 0 ]]; then
    echo ""
    return
  fi
  
  # Senaryo 1: Aynı major versiyon içinde
  local same_major_versions=()
  for version in "${greater_versions[@]}"; do
    local parsed=$(parse_version "$version")
    local major=$(echo "$parsed" | cut -d. -f1)
    if [[ "$major" == "$current_major" ]]; then
      same_major_versions+=("$version")
    fi
  done
  
  if [[ ${#same_major_versions[@]} -gt 0 ]]; then
    # Aynı major içinde required stop var mı?
    local required_stops=()
    for version in "${same_major_versions[@]}"; do
      if is_required_stop "$version"; then
        required_stops+=("$version")
      fi
    done
    
    if [[ ${#required_stops[@]} -gt 0 ]]; then
      # En yakın required stop'u bul (CURRENT_VERSION'dan büyük en küçük)
      local closest_stop=""
      for version in "${required_stops[@]}"; do
        if [[ -z "$closest_stop" ]] || compare_versions "$closest_stop" "$version"; then
          closest_stop="$version"
        fi
      done
      
      # En son patch'i al
      local parsed_stop=$(parse_version "$closest_stop")
      local major_minor=$(echo "$parsed_stop" | cut -d. -f1,2)
      local latest_patch=$(get_latest_patch_for_minor "$major_minor" "${same_major_versions[@]}")
      
      if [[ -n "$latest_patch" ]]; then
        echo "$latest_patch"
        return
      fi
    fi
    
    # Required stop yoksa, bir sonraki minor versiyonu bul
    local next_minor=""
    for version in "${same_major_versions[@]}"; do
      local parsed=$(parse_version "$version")
      local minor=$(echo "$parsed" | cut -d. -f2)
      if [[ $minor -gt $current_minor ]]; then
        if [[ -z "$next_minor" ]] || [[ $minor -lt $(echo "$next_minor" | cut -d. -f2) ]]; then
          next_minor="$version"
        fi
      fi
    done
    
    if [[ -n "$next_minor" ]]; then
      local parsed_next=$(parse_version "$next_minor")
      local major_minor=$(echo "$parsed_next" | cut -d. -f1,2)
      local latest_patch=$(get_latest_patch_for_minor "$major_minor" "${same_major_versions[@]}")
      if [[ -n "$latest_patch" ]]; then
        echo "$latest_patch"
        return
      fi
    fi
  fi
  
  # Senaryo 2: Yeni major versiyon çıkmış
  local new_major_versions=()
  for version in "${greater_versions[@]}"; do
    local parsed=$(parse_version "$version")
    local major=$(echo "$parsed" | cut -d. -f1)
    if [[ $major -gt $current_major ]]; then
      new_major_versions+=("$version")
    fi
  done
  
  if [[ ${#new_major_versions[@]} -gt 0 ]]; then
    # Önce mevcut major'ün en son required stop'una çık
    local current_major_required_stops=()
    for version in "${greater_versions[@]}"; do
      local parsed=$(parse_version "$version")
      local major=$(echo "$parsed" | cut -d. -f1)
      if [[ "$major" == "$current_major" ]] && is_required_stop "$version"; then
        current_major_required_stops+=("$version")
      fi
    done
    
    if [[ ${#current_major_required_stops[@]} -gt 0 ]]; then
      # En son required stop'u bul
      local latest_stop=""
      for version in "${current_major_required_stops[@]}"; do
        if [[ -z "$latest_stop" ]] || compare_versions "$version" "$latest_stop"; then
          latest_stop="$version"
        fi
      done
      
      local parsed_stop=$(parse_version "$latest_stop")
      local major_minor=$(echo "$parsed_stop" | cut -d. -f1,2)
      local latest_patch=$(get_latest_patch_for_minor "$major_minor" "${greater_versions[@]}")
      
      if [[ -n "$latest_patch" ]]; then
        echo "$latest_patch"
        return
      fi
    fi
    
    # Yeni major'ün ilk required stop'unu bul
    local new_major_required_stops=()
    for version in "${new_major_versions[@]}"; do
      if is_required_stop "$version"; then
        new_major_required_stops+=("$version")
      fi
    done
    
    if [[ ${#new_major_required_stops[@]} -gt 0 ]]; then
      # En küçük required stop'u bul
      local first_stop=""
      for version in "${new_major_required_stops[@]}"; do
        if [[ -z "$first_stop" ]] || compare_versions "$first_stop" "$version"; then
          first_stop="$version"
        fi
      done
      
      local parsed_stop=$(parse_version "$first_stop")
      local major_minor=$(echo "$parsed_stop" | cut -d. -f1,2)
      local latest_patch=$(get_latest_patch_for_minor "$major_minor" "${new_major_versions[@]}")
      
      if [[ -n "$latest_patch" ]]; then
        echo "$latest_patch"
        return
      fi
    fi
  fi
  
  # Fallback: En küçük büyük versiyon
  local smallest=""
  for version in "${greater_versions[@]}"; do
    if [[ -z "$smallest" ]] || compare_versions "$smallest" "$version"; then
      smallest="$version"
    fi
  done
  
  echo "$smallest"
}

echo "🔍  Mevcut versiyon alınıyor..."
CURRENT_VERSION=$(gitlab-rake gitlab:env:info 2>/dev/null | awk '/^GitLab information/,/^GitLab Shell/ {if ($1 == "Version:") print $2}')
[[ "$CURRENT_VERSION" != *-ce.0 ]] && CURRENT_VERSION="${CURRENT_VERSION}-ce.0"
echo "✅  Mevcut versiyon: $CURRENT_VERSION"

# Repo'dan versiyonları çek
echo "📦  Repo'dan mevcut versiyonlar taranıyor..."
AVAILABLE_VERSIONS=()
if command -v apt &>/dev/null; then
  while IFS= read -r version; do
    [[ -n "$version" ]] && AVAILABLE_VERSIONS+=("$version")
  done < <(get_versions_from_apt)
elif command -v dnf &>/dev/null; then
  while IFS= read -r version; do
    [[ -n "$version" ]] && AVAILABLE_VERSIONS+=("$version")
  done < <(get_versions_from_dnf)
else
  echo "❌  Desteklenmeyen paket yöneticisi!"
  exit 1
fi

if [[ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]]; then
  echo "❌  Repo'dan versiyon bilgisi alınamadı!"
  exit 1
fi

echo "📋  Bulunan versiyon sayısı: ${#AVAILABLE_VERSIONS[@]}"

# Sonraki versiyonu belirle
NEXT_VERSION=$(find_next_version "$CURRENT_VERSION" "${AVAILABLE_VERSIONS[@]}")

if [[ -z "$NEXT_VERSION" ]]; then
  echo "🚫  Son sürümde veya uygun bir sonraki sürüm bulunamadı."
  exit 0
fi

echo "🚩  Hedef sürüm: $NEXT_VERSION"

# 📁 Major versiyonu çıkar (örn: 18.0.4-ce.0 -> 18)
MAJOR_VERSION=$(echo "$CURRENT_VERSION" | cut -d. -f1)
BACKUP_DIR="/opt/gitlab_backup_${MAJOR_VERSION}.x"

# Backup kontrolü: Aynı major versiyon için backup var mı?
BACKUP_EXISTS=false
if [[ -d "$BACKUP_DIR" ]]; then
  # Backup dizininde .tar dosyası var mı kontrol et
  if ls "$BACKUP_DIR"/*_gitlab_backup.tar 1> /dev/null 2>&1; then
    BACKUP_EXISTS=true
    echo "✅  Major versiyon $MAJOR_VERSION.x için backup zaten mevcut: $BACKUP_DIR"
    echo "⏭️  Backup atlanıyor (aynı major versiyon içinde tek backup yeterli)"
  fi
fi

# Backup yoksa al
if [[ "$BACKUP_EXISTS" == false ]]; then
  echo "📂  Backup dizini oluşturuluyor: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR" || { echo "❌ Backup dizini oluşturulamadı."; exit 1; }

  # GitLab veritabanı yedeği alınıyor
  echo "📀  GitLab yedeği alınıyor..."
  gitlab-backup create || { echo "❌ Backup alınamadı."; exit 1; }

  # .tar dosyasını bul
  BACKUP_FILE=$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar | head -n 1)
  if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "❌ Backup .tar dosyası bulunamadı!"
    exit 1
  fi

  # ✅ Boyut kontrolü (100 KB altı ise şüpheli)
  if [[ $(stat -c%s "$BACKUP_FILE") -lt 102400 ]]; then
    echo "⚠️  Yedek dosyası şüpheli derecede küçük!"
    exit 1
  fi

  # Config dosyalarını yedekle
  cp /etc/gitlab/gitlab.rb "$BACKUP_DIR/" || { echo "❌ gitlab.rb yedeklenemedi."; exit 1; }
  cp /etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/" || { echo "❌ gitlab-secrets.json yedeklenemedi."; exit 1; }
else
  # Backup varsa bile config dosyalarını güncelle (her upgrade'te değişebilir)
  echo "📝  Config dosyaları güncelleniyor..."
  cp /etc/gitlab/gitlab.rb "$BACKUP_DIR/" || { echo "❌ gitlab.rb yedeklenemedi."; exit 1; }
  cp /etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/" || { echo "❌ gitlab-secrets.json yedeklenemedi."; exit 1; }
fi

# Pre-upgrade kontroller
gitlab-rake gitlab:check || { echo "❌ Pre-upgrade kontrolü başarısız."; exit 1; }
gitlab-rake gitlab:doctor:secrets || { echo "❌ Secrets kontrolü başarısız."; exit 1; }

# Güncelleme komutu (dağıtım tipine göre)
if command -v apt &>/dev/null; then
  apt update || true
  apt install -y gitlab-ce="$NEXT_VERSION" || { echo "❌ $NEXT_VERSION kurulamadı (apt)."; exit 1; }
elif command -v dnf &>/dev/null; then
  dnf clean all
  # Önce .el9 uzantısını dener, olmazsa düz sürümle dener
  dnf install -y gitlab-ce-"$NEXT_VERSION".el9 || dnf install -y gitlab-ce-"$NEXT_VERSION" || {
    echo "❌ $NEXT_VERSION kurulamadı (dnf)."
    exit 1
  }
else
  echo "❌  Desteklenmeyen paket yöneticisi!"
  exit 1
fi

# Reconfigure ve upgrade işlemleri
gitlab-ctl reconfigure || { echo "❌ Reconfigure başarısız."; exit 1; }
gitlab-ctl upgrade || { echo "❌ DB upgrade başarısız."; exit 1; }
gitlab-ctl restart || { echo "❌ Restart başarısız."; exit 1; }

# Post-upgrade kontroller
gitlab-rake gitlab:check || { echo "❌ Post-upgrade kontrol başarısız."; exit 1; }
gitlab-rake gitlab:doctor:secrets || { echo "❌ Post-upgrade secrets kontrol başarısız."; exit 1; }

echo ""
echo "🛠  Lütfen aşağıdaki testleri manuel yapın:"
echo "- 🔐  Web UI kullanıcı girişi"
echo "- 📁  Proje ve issue erişimi"
echo "- 🔄  Git clone/push testi"
echo ""
echo "🚀  Sonuç"
echo "🎉  Yükseltme tamamlandı: $CURRENT_VERSION → $NEXT_VERSION"
echo "📁  Yedek dizini: $BACKUP_DIR"
