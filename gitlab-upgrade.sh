#!/bin/bash
set -e

# 🧭 Zorunlu upgrade yolları
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

# ➡️ Sonraki sürümü belirle
NEXT_VERSION=""
found_current=false
for version in "${UPGRADE_PATHS[@]}"; do
  if $found_current; then
    NEXT_VERSION="$version"
    break
  fi
  [[ "$version" == "$CURRENT_VERSION" ]] && found_current=true
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

# 💾 Backup oluşturuluyor
echo "💾 GitLab veritabanı yedeği alınıyor..."
gitlab-backup create || { echo "❌ Backup alınamadı."; exit 1; }

# 📦 .tar dosyasını bul ve kontrol et
BACKUP_FILE=$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar | head -n 1)
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "❌ Backup .tar dosyası bulunamadı!"
  exit 1
fi
echo "✅ .tar yedeği bulundu: $BACKUP_FILE"

# 🗂️ .tar dosyasını yedek dizinine kopyala
cp "$BACKUP_FILE" "$BACKUP_DIR/" || { echo "❌ .tar dosyası yedek dizinine kopyalanamadı."; exit 1; }

# 🛡️ Config dosyalarını yedekle
cp /etc/gitlab/gitlab.rb "$BACKUP_DIR/" || { echo "❌ gitlab.rb yedeklenemedi."; exit 1; }
cp /etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/" || { echo "❌ gitlab-secrets.json yedeklenemedi."; exit 1; }

# 🔎 Pre-upgrade kontroller
gitlab-rake gitlab:check || { echo "❌ Pre-upgrade kontrolü başarısız."; exit 1; }
gitlab-rake gitlab:doctor:secrets || { echo "❌ Secrets kontrolü başarısız."; exit 1; }

# 📦 Güncelleme
apt update
apt install -y gitlab-ce="$NEXT_VERSION" || { echo "❌ $NEXT_VERSION kurulamadı."; exit 1; }

# ⚙️ Reconfigure ve upgrade işlemleri
gitlab-ctl reconfigure || { echo "❌ Reconfigure başarısız."; exit 1; }
gitlab-ctl upgrade || { echo "❌ DB upgrade başarısız."; exit 1; }
gitlab-ctl restart || { echo "❌ Restart başarısız."; exit 1; }

# ✅ Post-upgrade kontroller
gitlab-rake gitlab:check || { echo "❌ Post-upgrade kontrol başarısız."; exit 1; }
gitlab-rake gitlab:doctor:secrets || { echo "❌ Post-upgrade secrets kontrol başarısız."; exit 1; }

# 🎉 Sonuç
echo "🎉 Yükseltme tamamlandı: $CURRENT_VERSION → $NEXT_VERSION"
echo "📁 Yedek dizini: $BACKUP_DIR"
echo ""
echo "🛠 Lütfen aşağıdaki testleri manuel yapın:"
echo "- 🔐 Web UI kullanıcı girişi"
echo "- 📁 Proje ve issue erişimi"
echo "- 🔄 Git clone/push testi"
echo "- 🚀 CI/CD job çalıştırma (varsa runner testleri)"

