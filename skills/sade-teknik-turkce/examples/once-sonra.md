# Önce / Sonra Örnekleri

Baseline testlerde (skill yüklenmeden) gözlenen hatalardan türetildi. Her örnek bozulan kuralı adlandırır.

## 1. Kip yükseltme (içerik kuralı 1)

| Özgün | Skill'siz çıktı (hatalı) | Sade |
|---|---|---|
| "İsteğiniz ... başarısız olmuş olabilir." | "İstek başarısız oldu." | "İstek başarısız olmuş olabilir." |

Ajan değişikliği fark edip not düştü, yine de yaptı. Not düşmek kuralı karşılamaz. Hedge metinde kalır.

## 2. Bilgi ekleme (içerik kuralı 2)

Kaynak (docstring): `ConflictUnresolved (strategy="manual" ve çakışma varsa)`

| Skill'siz çıktı (hatalı) | Sade |
|---|---|
| "`ConflictUnresolved`: ... en az bir çakışma bulunduğunu gösterir. Hiçbir yazma yapılmamıştır." | "`ConflictUnresolved`: `strategy="manual"` iken en az bir çakışma varsa oluşur. Yazma durumu kaynakta belirtilmemiş." |

"Hiçbir yazma yapılmamıştır" kaynakta yok. Ajan buna güvenip geri alma adımını atlar.

Aynı testte eklenen diğer iddialar: "daha yeni olan kazanır", "Senkronizasyon geri alınamaz bir yazma işlemidir", "Geçersiz strategy değeri hata üretir". Hiçbiri kaynakta yok.

## 3. Sıra ile koşulu karıştırma

| Özgün | Skill'siz çıktı (hatalı) | Sade |
|---|---|---|
| "yedekleme işlemini gerçekleştirmesi ve ardından bağlantı kontrolü yaparak ... ancak ondan sonra komutu çalıştırması gerekmektedir" | "3. Yalnızca 1. ve 2. adım başarılıysa komutu çalıştırın." | "1. Yedek alın.<br>2. Bağlantıyı kontrol edin.<br>3. Komutu çalıştırın." |

Kaynak sıra bildirir, başarı koşulu bildirmez. "Başarılıysa" eklenmiş bir koşuldur.

## 4. Noktalı virgül ve gömülü komut

| Skill'siz çıktı (hatalı) | Sade |
|---|---|
| "Aktarım yarım kalmış olabilir; sipariş kayıtları çoğalmasın diye aktarımı tekrar başlatmayın." | "Aktarım yarım kalmış olabilir. Aktarımı tekrar başlatmayın. Aksi hâlde sipariş kayıtları çoğalır." |

Üç değişiklik: noktalı virgül nokta oldu, komut cümlenin başına geldi, gerekçe ayrı cümleye alındı. "olabilir" korundu.

## 5. Düşmüş özne

| Skill'siz çıktı (hatalı) | Sade |
|---|---|
| "Önce `verify_orders --repair` komutunu çalıştırın, sorun bildirmezse yeniden deneyebilirsiniz." | "Önce `verify_orders --repair` komutunu çalıştırın. Komut sıfır tutarsızlık bildirirse aktarımı yeniden çalıştırabilirsiniz." |

"Sorun bildirmezse" öznesiz: komut mu, kullanıcı mı? İki aday varsa özne yazılır. Ayrıca "sıfır tutarsızlık" kaynaktaki ölçüydü, "sorun yok"a yumuşatılmıştı.

## 6. İngilizce-Türkçe karışımı

| Skill'siz çıktı (hatalı) | Sade |
|---|---|
| "Backend'leri senkronize eder: yapılandırılmış veya belirtilen arka uçlar (backends) arasındaki..." | "Arka uçları senkronize eder. Yapılandırılmış veya belirtilen arka uçlar arasındaki..." |

Bir cümlede üç biçim. Biri seçilir. Hangisi seçildiği değil, tek olması önemlidir.

## 7. Adlaştırma

| Skill'siz çıktı (hatalı) | Sade |
|---|---|
| "hiçbir arka uca yazma yapılmaz" | "hiçbir arka uca yazmaz" |
| "yedekleme işlemini gerçekleştirmesi gerekmektedir" | "Yedek alın." |

## 8. Pazarlama sıfatı (skill'siz de doğru yapıldı)

| Özgün | Sade |
|---|---|
| "Bu güçlü ve kusursuz entegrasyon sayesinde müşterilerimizin verileri sorunsuz biçimde aktarılır" | "Entegrasyon müşteri verilerini aktarır." |

Baseline bu kuralı skill'siz de uyguladı. Skill bu konuda az söz söyler.
