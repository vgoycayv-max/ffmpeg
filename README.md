# Video Birleştirici (v1.1)

Bir **resim** ile bir **sesi** birleştirip YouTube'a yüklenebilir **mp4 video** yapan Android uygulaması.
(Radyo tiyatrosu gibi: sabit resim + uzun ses.)

---

## 1. Ne işe yarar?

| Özellik | Açıklama |
|---|---|
| Resim + ses → mp4 | `/sdcard/ffmpeg` klasöründeki aynı isimli dosyaları birleştirir (`tiyatro.mp3` + `tiyatro.jpg` → `tiyatro.mp4`) |
| Hepsini birleştir | Düzenleme yapmadan tüm çiftleri tek tuşla videoya çevirir (videosu zaten olanları atlar) |
| **YENİ** Ana sesi dinle ve kes | Sesin başını ve sonunu kesersin |
| **YENİ** Üste ses ekle | İstediğin kadar ses ekle; her biri videonun istediğin saniyesinde başlar |
| **YENİ** Eklenen sesi dinle ve kes | Eklediğin her sesten sadece istediğin parçayı alırsın |
| Aralıkta müziği azalt / sesi kapat | Seçtiğin saniye aralıklarında ana sesi azaltır ya da kapatır |

---

## 2. Nasıl kullanılır?

1. Ses ve resim dosyalarını telefonda `/sdcard/ffmpeg` klasörüne koy. İkisinin **adı aynı** olmalı.
2. Uygulamayı aç, "tüm dosyalara erişim" iznini ver.
3. Listeden bir çifte dokun. Düzenleme sayfası açılır.

### 2.1 Ana sesi kesmek
- **Dinle** → sesi baştan dinlersin. Üstteki çubukla istediğin yere atlarsın.
- Kesmek istediğin yerde dururken **Başlangıç = şimdi** veya **Bitiş = şimdi** düğmesine bas.
- Ya da alttaki kutulara saat / dakika / saniye yaz.
- **Kesilen parçayı dinle** → sadece tuttuğun parçayı çalar, doğru mu diye kontrol edersin.

### 2.2 Üste ses eklemek
1. **Ses ekle** düğmesine bas, telefondan bir veya birkaç ses seç.
2. Her ses için ayrı bir kart açılır:
   - Dinle ve kes (ana sesteki gibi).
   - **Videonun kaçıncı saniyesinde başlasın**: örnek `0 sa 2 dk 30 sn` yazarsan ses videonun 2:30'unda girer.
   - **Ses seviyesi**: %0 ile %200 arası.
3. İstediğin kadar ses ekleyebilirsin. Sesler aynı anda çalabilir.
4. Silmek için çöp kutusu simgesi.

### 2.3 Aralıkta müziği azaltma / sesi kapatma
- **Aralık ekle** ile başlangıç ve bitiş saniyesi seç.
- *Gürültüyü/müziği azalt*: ses temizleme filtresi çalışır (aşağıdaki "Sınırlar" bölümüne bak).
- *Ana sesi tamamen kapat*: o aralıkta ana ses susar. **Üste eklediğin sesler susmaz.** Yani ana sesi kapatıp yerine başka bir ses koyabilirsin.
- Bu aralıkların süreleri, **kesme işleminden sonraki** sese göredir.

### 2.4 Videoyu oluştur
**Videoyu oluştur** düğmesine bas. İşlem bitene kadar uygulamayı kapatma. Video `/sdcard/ffmpeg/ISIM.mp4` olarak kaydedilir.

---

## 3. Sınırlar (dürüst bilgi)

- **Müzik tam silinmez.** Kullandığımız araç (RNNoise) *gürültü* temizlemek için yapılmış, müzik silmek için değil. Müziği sesten gerçekten ayırmak için çok büyük bir yapay zekâ modeli gerekir; telefon uygulamasına sığmaz. Bu yüzden "azalt" seçeneğinde fark küçük olabilir. Kesin sonuç istiyorsan "Ana sesi tamamen kapat" seçeneğini kullan.
- Konuşma modeli (`model.rnnn`) internetten indirilir. İndirme başarısız olursa temizleme sadece basit filtrelerle yapılır, fark daha da az olur. GitHub'daki derleme günlüğünde `ls -la app/assets` satırında `model.rnnn` görünmeli.
- Eklenen seslerle birlikte **karışık önizleme yok**. Her sesi ayrı dinlersin, birleşik sonucu video oluşunca dinlersin.
- Eklenen sesler bittikten sonra ana ses uzunsa video ana ses kadar sürer. Eklenen ses ana sesten uzun sürerse video en uzun sese göre biter.

---

## 4. Derleme (APK yapma)

GitHub'da şu dosya yapısı olmalı:

```
.github/workflows/build.yml   (değişmedi)
source/main.dart              (yenisi)
source/pubspec.yaml           (yenisi)
```

1. `source/main.dart` ve `source/pubspec.yaml` dosyalarını yenileriyle değiştir.
2. `build.yml` **aynı kalır**, dokunma.
3. GitHub → Actions → "APK derle" → Run workflow.
4. Bitince "video-birlestirici-apk" dosyasını indir. Telefonun işlemcisine göre `arm64-v8a` olanı kur (çoğu yeni telefon).

Yeni eklenen paketler:
- `audioplayers`: sesleri uygulama içinde dinletir.
- `file_picker`: telefondan ses dosyası seçtirir.

---

## 5. Sorun giderme

| Sorun | Çözüm |
|---|---|
| Liste boş | Dosya adları aynı mı? İzin verildi mi? Sağ üstteki yenile düğmesine bas |
| "FFmpeg hatası" yazıyor | Ekrandaki hata metnini kopyalayıp gönder |
| Eklenen ses listede çıkmıyor / okunamadı | Dosya bozuk ya da desteklenmeyen biçim olabilir; mp3 / m4a dene |
| Derleme hatası (paket sürümü) | Hata metnini gönder |
