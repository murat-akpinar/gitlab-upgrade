# 🔼 GitLab Otomatik Yükseltme Script'i

Tek node, Linux paketi (Omnibus) ile kurulmuş **GitLab CE**'yi resmi upgrade path'e uyarak, required stop'lardan geçe geçe repodaki en yeni sürüme taşıyan Bash scripti.

Script dosyası: `gitlab-upgrade.sh`

## ✅ Test Durumu

| Dağıtım   | Test Durumu    |
|-----------|----------------|
| Ubuntu 24 | ✅ Test Edildi |
| Rocky 9   | ✅ Test Edildi |
| Debian 11 | ✅ Test Edildi |

## ⚙ Ne Yapar?

Başlangıçta bir kez:

- Root ve `skip-auto-reconfigure` kontrolü
- **Eşzamanlı çalışmayı `flock` ile engeller** (`/run/gitlab-upgrade.lock`); ikinci kopya reddedilir
- **Kendi log dosyasını yazar**: `/var/log/gitlab-upgrade/upgrade_<tarih>.log` (ekrana da basar, satırlar zaman damgalı)
- **GitLab paket deposu ekli mi** kontrol eder (`packages.gitlab.com`); değilse durur
- **Yarım kalmış kurulum** kontrolü: paket `dpkg`/`rpm`'de tutarsızsa veya uygulanmamış DB migration varsa durur (aksi halde VERSION dosyası yeni sürümü gösterip bir sonraki adıma geçilirdi)

Her upgrade adımında sırayla:

1. Sürüm atlama ve GitLab 19 (Mattermost kaldırıldı) ön kontrolleri
2. **Disk alanı kontrolü** (`ensure_disk_space`): PG data kopyası + (backup alınacaksa) repo/upload boyutu + emniyet payı; `/opt` kopyası da hesaba katılır. Yetmiyorsa baştan durur
3. Major bazlı backup (`/opt/gitlab_backup_<major>.x`), config dosyalarının kopyası
4. **Batched background migration'ların bitmesini bekler** (GitLab dokümanı: her upgrade'den önce hepsi `finished` olmalı; `failed` görürse durur)
5. Hedef paketi kurar; paket kurulumu `gitlab-ctl upgrade`'i (reconfigure + db:migrate + restart) kendisi çalıştırır
6. **Sert sağlık kapısı** (`verify_running`): tüm servisler ayakta ve uygulama `/-/readiness`'e cevap verene kadar bekler, olmazsa durur
7. `gitlab:check` ve `gitlab:doctor:secrets` (bilgi amaçlı; zararsız uyarılar upgrade'i **durdurmaz**)

Herhangi bir komut hata verirse script durur (`set -Eeuo pipefail`) ve şu anki sürüm + backup dizini + rollback ipucunu basar. Tekrar çalıştırıldığında kaldığı sürümden devam eder.

## 📌 Sürüm Seçimi

Kural: mevcut sürümden yeni en küçük major içinde, **ilk required stop'a kadar (dahil) en yüksek minor**'ün en yeni patch'i.

Required stop'lar ([Upgrade Paths](https://docs.gitlab.com/update/upgrade_paths/)):

| Major | Required stop minor'ları                       |
|-------|------------------------------------------------|
| 15.x  | 0, 1*, 4, 11                                   |
| 16.x  | 0*, 1*, 2*, 3, 7, 11                           |
| 17.x  | 1*, 3, 5, 8, 11                                |
| 18.x+ | 2, 5, 8, 11 (17.5+ için resmi sabit takvim)    |

`*` koşullu stop'lar: güvenli tarafta kalmak için script bunları da uygular.

Bir required stop **repoda hiç yoksa** (örn. Ubuntu 24.04 deposunda eski minor'lar) script o stop'un üstünden atlamaz, hata verip durur. Stop henüz yayınlanmamışsa (repoda ondan yenisi de yok) mevcut en yüksek minor'a gider.

Örnek akış:

```text
17.11.2 -> 17.11.latest -> 18.2.latest -> 18.5.latest -> 18.8.latest -> 18.11.latest -> 19.2.latest -> ...
```

Path mantığı için tek testi çalıştırmak: `bash test_upgrade_path.sh`

## 💾 Backup Davranışı

- Backup dizini major bazlıdır: `/opt/gitlab_backup_17.x`, `/opt/gitlab_backup_18.x`
- Aynı major için `gitlab-backup create` (`STRATEGY=copy`) bir kez çalışır; `backup.done` varsa tekrar alınmaz
- `gitlab.rb` ve `gitlab-secrets.json` her adımda dizine kopyalanır
- Backup tar dosyası da aynı dizine kopyalanır; başka ortama taşımak için tek dizin yeter
- Dizin `700`, secrets dosyası orijinal izinleriyle (`600`) kopyalanır
- `SKIP_BACKUP=1` ile `gitlab-backup` atlanır (VM snapshot aldıysanız); config kopyası yine alınır

> ⚠️ Restore, backup'ın alındığı GitLab sürümüyle birebir aynı sürümde yapılmalıdır. Major başındaki backup'a dönmek için o sürüme downgrade gerekir. Her adımda backup istiyorsanız `backup.done` dosyasını her adımdan önce silin.

## 📝 Kullanım

Ön koşullar: root/sudo, resmi GitLab paket deposu ekli, backup için yeterli disk.

```bash
# Ubuntu/Debian için repo
curl -sS "https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh" | sudo bash

# Repodaki sürümler
apt-cache madison gitlab-ce            # Debian/Ubuntu
dnf repoquery gitlab-ce                # RHEL/Rocky

# Çalıştır (log otomatik: /var/log/gitlab-upgrade/upgrade_<tarih>.log)
sudo ./gitlab-upgrade.sh
```

Ayarlar (ortam değişkeni):

| Değişken             | Varsayılan                     | Açıklama                                                          |
|----------------------|--------------------------------|------------------------------------------------------------------|
| `BBM_WAIT_MINUTES`   | `120`                          | Background migration bekleme üst sınırı; dolarsa durur           |
| `READY_WAIT_MINUTES` | `15`                           | Adım sonrası uygulamanın hazır olması için bekleme üst sınırı    |
| `READINESS_URL`      | `http://127.0.0.1/-/readiness` | Sağlık kapısının kontrol ettiği adres (https/farklı host için)   |
| `DISK_MARGIN_MB`     | `2048`                         | PG data kopyası üstüne istenen boş alan payı (MB)                |
| `SKIP_BACKUP`        | `0`                            | `1`: `gitlab-backup create` atlanır (snapshot'ınız varsa)        |
| `LOG_DIR`            | `/var/log/gitlab-upgrade`      | Script'in log dosyasını yazdığı dizin                            |

> Not: Ubuntu 24.04 (Noble) deposunda 15.x gibi eski majorlar bulunmayabilir. Script sadece depoda bulunan sürümlere gidebilir; ara major veya required stop eksikse durur.

## 💡 Örnek Çıktı

```text
==============================
🔄 Upgrade adımı #2
   17.11.7 -> 18.2.10-ce.0
==============================
⏭️  Major 17.x için backup daha önce alınmış, yeniden alınmıyor.
📁  Backup dizini: /opt/gitlab_backup_17.x
⏳ Bitmemiş batched background migration var (0 sn beklendi):
BackfillSomething ci_builds.id [active]
✅ Bekleyen background migration yok.
🚩 Hedef sürüm: 18.2.10-ce.0
✅ Servisler ayakta ve uygulama hazır.
✅ Adım tamamlandı. Yeni sürüm: 18.2.10
```

Gerçek bir 18.1.6 → 19.3.2 koşusu tek script çalıştırmasıyla test edildi:

```text
18.1.6 → 18.2.8 → 18.5.7 → 18.8.11 → 18.11.11 → 19.2.6 → 19.3.2
```

18.11 adımında paket PostgreSQL'i 16'dan 17'ye otomatik yükseltti.

## 🧷 GitLab 19 Notları

- PostgreSQL 17 zorunlu. 18.11 paketi kurulurken PG otomatik 17'ye yükseltilir; yükseltilmediyse 19.0 paketi kurulumu reddeder. `/etc/gitlab/disable-postgresql-upgrade` dosyası varsa elle `gitlab-ctl pg-upgrade -V 17` gerekir.
- Bundled Mattermost ve Spamcheck kaldırıldı; `gitlab.rb`'de `mattermost` ayarı varsa script 19'a geçmeden durur.
- Harici Redis 6 desteklenmiyor (7.0+ veya Valkey 7.2 gerekir).
- Ubuntu 20.04 için 19.x paketi yok; script en son 18.x'te durur.

## 🛠 Manuel Kontroller

Script sonrası:

- 🔐 Web UI kullanıcı girişi
- 📁 Proje ve issue erişimi
- 🔄 Git clone/push

## ↩️ Rollback

> Rollback, veri kaybı riskine karşı kontrollü yapılmalıdır. Restore edilen backup ile kurulu GitLab sürümü aynı olmalıdır.

```bash
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq

sudo apt install --allow-downgrades -y gitlab-ce=<backup_surumu>-ce.0   # önce backup'ın alındığı sürüme dön
sudo cp /opt/gitlab_backup_<major>.x/gitlab.rb /etc/gitlab/gitlab.rb
sudo cp /opt/gitlab_backup_<major>.x/gitlab-secrets.json /etc/gitlab/gitlab-secrets.json
sudo gitlab-backup restore BACKUP=<backup_id>

sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
sudo gitlab-rake gitlab:check SANITIZE=true
```

## 📚 Referanslar

- [Upgrade Paths](https://docs.gitlab.com/update/upgrade_paths/)
- [Background migrations](https://docs.gitlab.com/update/background_migrations/)
- [Linux package upgrade](https://docs.gitlab.com/update/package/)
- [GitLab 19 changes](https://docs.gitlab.com/update/versions/gitlab_19_changes/)
- [Upgrade Path Tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/)
