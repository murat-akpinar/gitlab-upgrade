#!/bin/bash
set -e

# 🔁 Zorunlu upgrade path listesi
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

# 🔍 Mevcut versiyonu al
CURRENT_VERSION=$(gitlab-rake gitlab:env:info 2>/dev/null | awk '/^GitLab information/,/^GitLab Shell/ {if ($1 == "Version:") print $2}')
[[ "$CURRENT_VERSION" != *-ce.0 ]] && CURRENT_VERSION="${CURRENT_VERSION}-ce.0"
echo "✅ Mevcut versiyon: $CURRENT_VERSION"

# 🔄 Bir sonraki upgrade versiyonunu bul
NEXT_VERSION=""
for version in "${UPGRADE_PATHS[@]}"; do
dpkg --compare-versions "$version" gt "$CURRENT_VERSION" && { NEXT_VERSION=$version; break; }
done

if [[ -z "$NEXT_VERSION" ]]; then
echo "🚫 Son sürümde veya listede yok. Güncellenecek bir sonraki sürüm bulunamadı."
exit 0
fi

echo "🚩 Güncellenecek sürüm: $NEXT_VERSION"

# 📂 Yedek dizini
BACKUP_DIR="/opt/gitlab_backup_${CURRENT_VERSION}"
echo "📂 Backup dizini oluşturuluyor: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# 💾 Backup
echo "💾 GitLab yedeği alınıyor..."
gitlab-backup create
cp /etc/gitlab/gitlab.rb "$BACKUP_DIR/gitlab.rb"
cp /etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/gitlab-secrets.json"

# 🩺 Pre-check
echo "🧪 Pre-upgrade kontrolleri..."
gitlab-rake gitlab:check
gitlab-rake gitlab:doctor:secrets

# 📦 Paket kurulumu
echo "📦 $NEXT_VERSION kuruluyor..."
apt update
apt install -y gitlab-ce="$NEXT_VERSION" --allow-downgrades

# 🔧 Reconfigure ve upgrade
echo "⚙ GitLab reconfigure ediliyor..."
gitlab-ctl reconfigure
gitlab-ctl upgrade
gitlab-ctl restart

# ✅ Kontroller
echo "✅ Post-upgrade kontrolleri..."
gitlab-rake gitlab:check
gitlab-rake gitlab:doctor:secrets

echo "🎉 Yükseltme tamamlandı: $CURRENT_VERSION → $NEXT_VERSION"
echo "📁 Yedek dizini: $BACKUP_DIR"

# Manuel kontrol
echo ""
echo "🛠 Lütfen aşağıdaki testleri manuel yapın:"
echo "- 🔐 Web UI kullanıcı girişi"
echo "- 📁 Proje ve issue erişimi"
echo "- 🔄 Git clone/push testi"

exit 0
