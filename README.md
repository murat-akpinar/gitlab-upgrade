# 🔼 GitLab Otomatik Yükseltme Script'i

Bu script, **Ubuntu 24.04** üzerinde kurulu GitLab CE (Community Edition) sürümünü, zorunlu sıralı sürüm geçişlerini takip ederek adım adım yükseltir.

## ✅ Test Durumu

| Dağıtım       | Test Durumu |
|---------------|-------------|
| Ubuntu 24.04  | ✅ Test Edildi |
| Rocky Linux   | ⛔ Henüz Test Edilmedi |
| Debian        | ✅ Test Edildi |



## 📌 Amaç

GitLab, belirli sürümler arasında **doğrudan yükseltmeye izin vermez**. Bu nedenle sürüm geçişleri sıralı şekilde yapılmalıdır. Bu script:

- Mevcut GitLab sürümünü algılar
- Sıradaki geçerli sürümü belirler
- Yedek alır
- Güncellemeyi gerçekleştirir
- Gerekli kontrolleri yapar

## ⚙ Özellikler

- 🔁 Zorunlu sürüm yükseltme yollarını takip eder
- 💾 Otomatik yedekleme (veri + yapılandırma dosyaları)
- 🧪 Pre ve post-upgrade kontrolleri
- 📦 Belirtilen GitLab paketini kurar
- 🔄 Reconfigure & restart işlemleri

## 📝 Kullanım

### 1. Script'i indirin veya oluşturun

```bash
git clone https://github.com/murat-akpinar/gitlab-upgrade.git
```

### 2. Yürütülebilir hale getirin

```bash
chmod +x gitlab-upgrade.sh
```

### 3. Script'i çalıştırın (root yetkisiyle)

```bash
sudo ./gitlab-upgrade.sh |& tee "upgrade_log_$(date +%F_%H-%M-%S).log"
```

## 💡 Örnek Çıktı

```text
✅ Mevcut versiyon: 17.3.7-ce.0
🚩 Güncellenecek sürüm: 17.5.5-ce.0
📂 Backup dizini oluşturuluyor: /opt/gitlab_backup_17.3.7-ce.0
💾 GitLab yedeği alınıyor...
🧪 Pre-upgrade kontrolleri...
📦 17.5.5-ce.0 kuruluyor...
⚙ GitLab reconfigure ediliyor...
✅ Post-upgrade kontrolleri...
🎉 Yükseltme tamamlandı: 17.3.7-ce.0 → 17.5.5-ce.0
```

## 📁 Yedekler

Yedekler aşağıdaki dizinde saklanır:

```
/opt/gitlab_backup_<MEVCUT_SÜRÜM>
```

İçerik:

- `gitlab.rb`
- `gitlab-secrets.json`
- Otomatik alınan veri yedeği (`/var/opt/gitlab/backups`)
- Aynı zamanda bu backup.tar dosyasını oluşan backup dizinin içine de kopyalıyor bu yedeği başka ortama da yedeklemek istersek tek bir dizini kopyalamak daha kolay olacağını düşündüm. 

## 🛠 Manuel Kontroller (Zorunlu)

Script sonrası aşağıdaki testlerin manuel yapılması önerilir:

- 🔐 Web UI kullanıcı girişi
- 📁 Proje ve issue erişimi
- 🔄 Git üzerinden clone/push işlemleri

## 🧷 Notlar

- Bu script sadece **GitLab CE** sürümleri içindir.
- Script içindeki `UPGRADE_PATHS` listesi sabittir ve [GitLab Upgrade Path Docs](https://docs.gitlab.com/ee/update/#upgrade-paths) referans alınarak hazırlanmıştır.
- `apt install` komutu `--allow-downgrades` flag’i içerir; bu sayede versiyon eşleştirmeleri hassas yapılabilir.

- [Upgrade Paths Doc](https://docs.gitlab.com/update/upgrade_paths/)
- [Upgrade Path Web Tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/)

## 🛑 Uyarılar

- Script `set -e` ile başlar, herhangi bir komutta hata oluşursa durur.
- Yükseltme sırasında sistem yükünü azaltın, mümkünse yedek bir ortamda test edin.

## 🧑‍💻 Yazar

Bu script, GitLab CE sistemlerini güvenli ve kontrollü şekilde yükseltmek isteyen sistem yöneticileri için hazırlanmıştır.



# GitLab Yedeğe Geri Dönme Adımları

Bu adımlar, belirli bir GitLab yedeğine geri dönmek için izlenmelidir.

## 1. GitLab Servislerini Durdurun

```bash
gitlab-ctl stop unicorn
gitlab-ctl stop sidekiq
```

## 2. Backup Dosyasını Belirleyin ve Geri Yükleyin

> `/var/opt/gitlab/backups/` dizinindeki `.tar` uzantılı dosyalardan biri seçilmeli.

```bash
# Örnek:
gitlab-backup restore BACKUP=1752974016_2025_07_20_17.3.7
```

## 3. Yapılandırma Dosyalarını Geri Yükleyin

```bash
cp /opt/gitlab_backup_17.3.7-ce.0/gitlab.rb /etc/gitlab/gitlab.rb
cp /opt/gitlab_backup_17.3.7-ce.0/gitlab-secrets.json /etc/gitlab/gitlab-secrets.json
```

## 4. GitLab Sürümünü Geri Alın (Downgrade)

```bash
apt install --allow-downgrades -y gitlab-ce=17.3.7-ce.0
```

## 5. Yapılandırmaları Yeniden Uygulayın ve Servisleri Başlatın

```bash
gitlab-ctl reconfigure
gitlab-ctl restart
```

> ✅ Geri yükleme tamamlandıktan sonra arayüzde projelerinize ve verilere erişimi test edin.

