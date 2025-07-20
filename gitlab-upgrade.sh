#!/bin/bash
set -e

# 🌝 Zorunlu upgrade yolları
UPGRADE_PATHS=(
  "15.0.5-ce.0"
  "15.1.6-ce.0"
  "15.4.6-ce.0"
  "15.11.13-ce.0"
  "16.0.10-ce.0"
  "16.1.8-ce.0"
  "16.2.11-ce.0"
  "16.3.9-ce.0"
  "16.7.10-ce.0"
  "16.11.10-ce.0"
  "17.1.8-ce.0"
  "17.3.7-ce.0"
  "17.5.5-ce.0"
  "17.8.7-ce.0"
  "17.11.6-ce.0"
  "18.0.4-ce.0"
  "18.1.2-ce.0"
  "18.2.0-ce.0"
)

echo "🔍 Mevcut versiyon alınıyor..."
CURRENT_VERSION=$(gitlab-rake gitlab:env:info 2>/dev/null | awk '/^GitLab information/,/^GitLab Shell/ {if ($1 == "Version:") print $2}')
[[ "$CURRENT_VERSION" != *-ce.0 ]] && CURRENT_VERSION="${CURRENT_VERSION}-ce.0"
echo "✅ Mevcut versiyon: $CURRENT_VERSION"

# ➔ Sonraki sürümü belirle
NEXT_VERSION=""
for version in "${UPGRADE_PATHS[@]}"; do
  if command -v dpkg &>/dev/null; then
    # Debian/Ubuntu sistemlerde
    if dpkg --compare-versions "$version" gt "$CURRENT_VERSION"; then
      NEXT_VERSION="$version"
      break
    fi
  elif command -v rpmdev-vercmp &>/dev/null; then
    # RHEL/Rocky sistemlerde
    if rpmdev-vercmp "$version" "$CURRENT_VERSION" | grep -q ">"; then
      NEXT_VERSION="$version"
      break
    fi
  fi
done

if [[ -z "$NEXT_VERSION" ]]; then
  echo "🚫 Son sürümde veya listede yok. Güncellenecek bir sonraki sürüm bulunamadı."
  exit 0
fi

echo "🚩 Hedef sürüm: $NEXT_VERSION"

# 📁 Backup dizini
BACKUP_DIR="/opt/gitlab_backup_${CURRENT_VERSION}"
echo "📂 Backup dizini oluşturuluyor: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" || { echo "❌ Backup dizini oluşturulamadı."; exit 1; }

# 📀 GitLab veritabanı yedeği alınıyor
echo "📀 GitLab yedeği alınıyor..."
gitlab-backup create || { echo "❌ Backup alınamadı."; exit 1; }

# 📦 .tar dosyasını bul
BACKUP_FILE=$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar | head -n 1)
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "❌ Backup .tar dosyası bulunamadı!"
  exit 1
fi

# ✅ Boyut kontrolü (100 KB altı ise şüpheli)
if [[ $(stat -c%s "$BACKUP_FILE") -lt 102400 ]]; then
  echo "⚠️ Yedek dosyası şüpheli derecede küçük!"
  exit 1
fi

# 🗂 .tar dosyasını yedek dizinine kopyala
cp "$BACKUP_FILE" "$BACKUP_DIR/" || { echo "❌ .tar dosyası yedek dizinine kopyalanamadı."; exit 1; }

# 🔐 SHA256 karşılaştırması
COPIED_FILE="$BACKUP_DIR/$(basename "$BACKUP_FILE")"
SOURCE_HASH=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
DEST_HASH=$(sha256sum "$COPIED_FILE" | awk '{print $1}')

if [[ "$SOURCE_HASH" != "$DEST_HASH" ]]; then
  echo "❌ SHA256 kontrolü başarısız!"
  echo "Kaynak: $SOURCE_HASH"
  echo "Hedef : $DEST_HASH"
  exit 1
else
  echo "✅ SHA256 kontrolü başarılı. Dosya bütünlüğü sağlandı."
fi

# 🛡️ Config dosyalarını yedekle
cp /etc/gitlab/gitlab.rb "$BACKUP_DIR/" || { echo "❌ gitlab.rb yedeklenemedi."; exit 1; }
cp /etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/" || { echo "❌ gitlab-secrets.json yedeklenemedi."; exit 1; }

# 🔎 Pre-upgrade kontroller
gitlab-rake gitlab:check || { echo "❌ Pre-upgrade kontrolü başarısız."; exit 1; }
gitlab-rake gitlab:doctor:secrets || { echo "❌ Secrets kontrolü başarısız."; exit 1; }

# 📦 Güncelleme komutu (dağıtım tipine göre)
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
  echo "❌ Desteklenmeyen paket yöneticisi!"
  exit 1
fi

# ⚙️ Reconfigure ve upgrade işlemleri
gitlab-ctl reconfigure || { echo "❌ Reconfigure başarısız."; exit 1; }
gitlab-ctl upgrade || { echo "❌ DB upgrade başarısız."; exit 1; }
gitlab-ctl restart || { echo "❌ Restart başarısız."; exit 1; }

# ✅ Post-upgrade kontroller
gitlab-rake gitlab:check || { echo "❌ Post-upgrade kontrol başarısız."; exit 1; }
gitlab-rake gitlab:doctor:secrets || { echo "❌ Post-upgrade secrets kontrol başarısız."; exit 1; }

echo ""
echo "🛠 Lütfen aşağıdaki testleri manuel yapın:"
echo "- 🔐 Web UI kullanıcı girişi"
echo "- 📁 Proje ve issue erişimi"
echo "- 🔄 Git clone/push testi"
echo ""
echo "🚀 Sonuç"
echo "🎉 Yükseltme tamamlandı: $CURRENT_VERSION → $NEXT_VERSION"
echo "📁 Yedek dizini: $BACKUP_DIR"

