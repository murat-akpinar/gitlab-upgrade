# GitLab Otomatik Yukseltme Scripti

Bu repo, kurulu GitLab CE sunucusunu uygun upgrade path adimlari ile otomatik yukseltmek icin `gitlab-upgrade.sh` scriptini icerir.

## Kurulum Adimlari

### 1) On kosullar

- Isletim sistemi: Ubuntu/Debian (`apt`) veya Rocky/RHEL (`dnf`)
- Paket: `gitlab-ce`
- Yetki: root veya sudo
- Diskte backup icin yeterli alan

> Not: Ubuntu 24.04 (Noble) deposunda 15.x gibi eski majorlar bulunmayabilir. Script sadece depoda bulunan surumlere gidebilir.

### 2) GitLab CE reposunu ekle (Ubuntu/Debian)

```bash
curl -sS "https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh" | sudo bash
sudo apt update
```

### 3) Kurulabilir surumleri gor

```bash
apt-cache madison gitlab-ce
```

### 4) Baslangic surumunu kur (ornek)

```bash
sudo EXTERNAL_URL="http://192.168.1.151" apt install -y gitlab-ce=17.11.2-ce.0
sudo gitlab-ctl reconfigure
```

### 5) Upgrade scriptini calistir

```bash
sudo ./gitlab-upgrade.sh |& tee "upgrade_log_$(date +%F_%H-%M-%S).log"
```

### 6) Script nasil surum secer?

- Required stop minorlara oncelik verir: `x.2`, `x.5`, `x.8`, `x.11`
- Her minorda en guncel patch'i alir
- Tum patchleri tek tek kurmaz
- Repoda daha yeni surum yoksa durur

Ornek:

`18.0.0 -> 18.2.latest -> 18.5.latest -> 18.8.latest -> 18.11.latest`

### 7) Backup davranisi

- Backup dizini major bazlidir: `/opt/gitlab_backup_17.x`, `/opt/gitlab_backup_18.x`
- Ayni major icin `gitlab-backup create` bir kez calisir
- `backup.done` varsa veri backup tekrar alinmaz
- `gitlab.rb` ve `gitlab-secrets.json` her adimda backup dizinine kopyalanir

Ornek log:

```text
==============================
🔄 Upgrade adımı #2
   17.11.7-ce.0 -> 18.0.0-ce.0
==============================
⏭️  Major 17.x için backup daha önce alınmış, yeniden alınmıyor.
📁  Backup dizini: /opt/gitlab_backup_17.x
🔎 GitLab sağlık kontrolleri çalıştırılıyor...
```

## Test Adimlari

Major gecislerinden sonra kisa smoke test onerilir:

1. Web UI login testi
2. Proje/issue ekranina giris
3. `git clone` ve `git push` testi

Ek teknik kontroller:

```bash
sudo gitlab-rake gitlab:check
sudo gitlab-rake gitlab:doctor:secrets
sudo gitlab-rake gitlab:env:info
```

## Geri Donme (Rollback) Adimlari

> Rollback, veri kaybi riskine karsi kontrollu yapilmalidir.

1. Gerekli servisleri durdur:

```bash
sudo gitlab-ctl stop unicorn
sudo gitlab-ctl stop sidekiq
```

2. Uygun backup'i geri yukle:

```bash
sudo gitlab-backup restore BACKUP=<backup_id>
```

3. Config dosyalarini backup dizininden geri koy:

```bash
sudo cp /opt/gitlab_backup_<major>.x/gitlab.rb /etc/gitlab/gitlab.rb
sudo cp /opt/gitlab_backup_<major>.x/gitlab-secrets.json /etc/gitlab/gitlab-secrets.json
```

4. Gerekirse paketi downgrade et:

```bash
sudo apt install --allow-downgrades -y gitlab-ce=<eski_surum>
```

5. Yeniden uygula ve servisleri baslat:

```bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
```

6. Son kontrol:

- Web UI login
- Proje erisimi
- Git clone/push

## Referanslar

- [GitLab Upgrade Paths](https://docs.gitlab.com/update/upgrade_paths/)
- [GitLab Linux package installation](https://docs.gitlab.com/install/package/)
# GitLab Otomatik Yukseltme Scripti

Bu proje, kurulu bir GitLab CE sunucusunu resmi paket deposundaki uygun adimlari izleyerek otomatik sekilde yukselten bir Bash scripti sunar.

Script dosyasi: `gitlab-upgrade.sh`

## Ne Yapar?

- Mevcut GitLab surumunu otomatik algilar.
- Repodaki uygun surumleri (`apt` veya `dnf`) listeler.
- Bir sonraki hedef surumu kurallara gore secer.
- Her adim oncesi/sirasi gerekli kontrolleri calistirir.
- Major bazli backup alir ve config dosyalarini kopyalar.

## Destek ve Kapsam

- Paket: yalnizca `gitlab-ce`
- Paket yoneticisi: `apt` (Ubuntu/Debian) ve `dnf` (RHEL/Rocky)
- Scriptin amaci: mevcut kurulu GitLab CE'yi guvenli sekilde ileri tasimak

> Not: Ubuntu 24.04 (Noble) uzerinde cok eski majorlar (ornegin 15.x) resmi depoda bulunmayabilir. Script sadece depoda gercekten var olan surumlerle calisir.

## Versiyon Gecis Mantigi

Script, GitLab upgrade path yaklasimina gore ilerler:

- Required stop minor'larina oncelik verir: `x.2`, `x.5`, `x.8`, `x.11`
- Her hedef minorda tek tek tum patch'leri degil, o minorun en guncel patch'ini kurar
- Ayni major bittiginde bir sonraki majora gecer
- Repoda daha yeni surum yoksa durur

Ornek akis:

`18.0.0 -> 18.2.latest -> 18.5.latest -> 18.8.latest -> 18.11.latest`

## Backup Davranisi

Backup dizini major bazinda olusur:

- `/opt/gitlab_backup_17.x`
- `/opt/gitlab_backup_18.x`

Kurallar:

- Ayni major icin veri backup'i (`gitlab-backup create`) bir kez alinir
- `backup.done` varsa tekrar veri backup'i alinmaz
- `gitlab.rb` ve `gitlab-secrets.json` her adimda bu dizine kopyalanir

## On Kosullar

1. GitLab CE kurulu olmali
2. Resmi GitLab paketi deposu ekli olmali
3. Root veya sudo yetkisi olmali
4. Diskte backup icin yeterli alan olmali

Ubuntu icin repo ekleme:

```bash
curl -sS "https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh" | sudo bash
```

Depodaki surumleri gormek:

```bash
apt-cache madison gitlab-ce
```

## Kullanim

```bash
sudo ./gitlab-upgrade.sh |& tee "upgrade_log_$(date +%F_%H-%M-%S).log"
```

## Scriptin Calisma Sirasi

Her upgrade adiminda ozetle:

1. Backup kontrolu/alimi
2. Saglik kontrolleri (`gitlab:check`, `gitlab:doctor:secrets`)
3. Hedef surumun kurulumu
4. `gitlab-ctl reconfigure`
5. `gitlab-ctl upgrade`
6. `gitlab-ctl restart`
7. Tekrar saglik kontrolleri

Herhangi bir adim hata verirse script durur (`set -Eeuo pipefail`).

## Manuel Smoke Test (onerilir)

Her major gecisi sonrasi asagidakileri hizlica test edin:

- Web UI login
- Bir proje/issue ekrani acilisi
- `git clone` ve `git push`

## Ornek Log Parcasi

```text
==============================
Upgrade adimi #3
  18.0.0-ce.0 -> 18.2.8-ce.0
==============================
```

Bu, required stop mantigina gore beklenen bir adimdir.

## Rollback (Genel Adimlar)

1. Gerekli servisleri durdur
2. Uygun backup dosyasini geri yukle
3. `gitlab.rb` ve `gitlab-secrets.json` dosyalarini backup dizininden geri kopyala
4. Gerekirse hedef eski paketi downgrade et
5. `gitlab-ctl reconfigure` ve `gitlab-ctl restart` calistir

Ornek:

```bash
gitlab-backup restore BACKUP=<backup_id>
cp /opt/gitlab_backup_17.x/gitlab.rb /etc/gitlab/gitlab.rb
cp /opt/gitlab_backup_17.x/gitlab-secrets.json /etc/gitlab/gitlab-secrets.json
apt install --allow-downgrades -y gitlab-ce=<eski_surum>
gitlab-ctl reconfigure
gitlab-ctl restart
```

## Referanslar

- [GitLab Upgrade Paths](https://docs.gitlab.com/update/upgrade_paths/)
- [GitLab Linux package installation](https://docs.gitlab.com/install/package/)
# 🔼 GitLab Otomatik Yükseltme Script'i

Bu script, **Ubuntu 24.04** üzerinde kurulu GitLab CE (Community Edition) sürümünü, zorunlu sıralı sürüm geçişlerini takip ederek adım adım yükseltir.

## ✅ Test Durumu

| Dağıtım       | Test Durumu |
|---------------|-------------|
| Ubuntu 24     | ✅ Test Edildi |
| Rocky 9       | ✅ Test Edildi |
| Debian 11     | ✅ Test Edildi |



## 📌 Amaç

GitLab, belirli sürümler arasında **doğrudan yükseltmeye izin vermez**. Bu nedenle sürüm geçişleri sıralı şekilde yapılmalıdır. Bu script:

- Mevcut GitLab sürümünü algılar
- Sıradaki geçerli sürümü belirler
- Yedek alır
- Güncellemeyi gerçekleştirir
- Gerekli kontrolleri yapar

## ⚙ Özellikler

- 🔁 Adım bazlı upgrade akışı (`Upgrade adımı #n` + `from -> to`)
- 💾 Major bazlı yedekleme (`/opt/gitlab_backup_<major>.x`)
- ⏭️ Aynı major için backup daha önce alındıysa yeniden almaz (`backup.done`)
- 🔎 Upgrade öncesi ve sonrası GitLab sağlık kontrollerini çalıştırır
- 📦 Hedef paketi kurar, `reconfigure`, `upgrade` ve `restart` uygular

## 📝 Kullanım

### 1. Script'i indirin veya oluşturun

```bash
git clone https://github.com/murat-akpinar/gitlab-upgrade.git
cd gitlab-upgrade
```

### 2. Script'i çalıştırın (root yetkisiyle)

```bash
sudo ./gitlab-upgrade.sh |& tee "upgrade_log_$(date +%F_%H-%M-%S).log"
```

## 💡 Örnek Çıktı

```text
==============================
🔄 Upgrade adımı #2
   17.11.7-ce.0 -> 18.0.0-ce.0
==============================
⏭️  Major 17.x için backup daha önce alınmış, yeniden alınmıyor.
📁  Backup dizini: /opt/gitlab_backup_17.x
🔎 GitLab sağlık kontrolleri çalıştırılıyor...
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

