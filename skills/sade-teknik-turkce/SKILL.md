---
name: sade-teknik-turkce
description: "Use when Turkish text must be parsed without a human to resolve ambiguity (araç/tool açıklaması, hata mesajı, ajanlar arası talimat, sistem promptu, durum raporu, prosedür) and misreading has a real cost, or when Turkish text reads as dense, resmî, hedged, or chained. Triggers: sadeleştir, netleştir, yanlış anlaşılmasın, tek anlamlı yaz, STE Türkçe, kontrollü Türkçe, Türkçe tool description yaz, Türkçe hata mesajı yaz. Not for creative or marketing copy. For English text use asd-ste100."
version: 0.1.0
---

# Sade Teknik Türkçe

ASD-STE100 (Simplified Technical English) havacılık bakım talimatlarının yanlış okunmasını engellemek için kurulmuş bir kontrollü dil standardıdır. Bu skill, STE'nin **ilkesini** Türkçeye taşır: bir sözcüğün bir anlamı, bir cümlenin bir yapısı, kaynaktaki her olgunun ve her belirsizliğin aynen korunması.

Okuyucu bir **yazılım ajanı ya da alt sistemdir**. Soru soramaz, bağlamdan tahmin yürütürse maliyeti vardır.

STE'nin İngilizceye özgü kuralları (phrasal verb yasağı, present perfect yasağı, 900 sözcüklük onaylı sözlük) burada yoktur. Yerlerine Türkçe teknik metnin kendi belirsizlik kaynakları için kurallar vardır: zincir cümle, sıfat-fiil yığını, düşmüş özne, "-ma yapmak" adlaştırması, kanıtsallık (-dI / -mIş) kaybı.

## Ne zaman kullanılır

- Türkçe metni başka bir ajan, bir çeviri hattı veya bir alt sistem okuyacak.
- Türkçe bir araç açıklaması, hata mesajı, prompt veya prosedür yazılıyor.
- Mevcut Türkçe metin resmî, zincirli, "olup / halinde / gerekmektedir" dolu.
- Kullanıcı "sadeleştir", "netleştir", "yanlış anlaşılmasın" dedi.

Yaratıcı, pazarlama veya ikna metni için kullanılmaz. STE bilerek düz ve literaldir.

## İki kip

**Sıkı**: prosedür, hata mesajı, araç açıklaması, ajanlar arası talimat, güvenlik metni. Aşağıdaki tüm kurallar, uzunluk sınırları dahil.

**Esnek**: README, PR açıklaması, değişiklik notu, açıklayıcı düzyazı. Yapısal kurallar tam uygulanır, sözcük kuralları öneri olarak kalır.

Kullanıcı belirtmediyse metin türünden çıkar. Seçimi kullanıcı kural tablosu istemedikçe söyleme.

## İçerik kuralları: önce bunlar

Baseline testlerde en sık ve en pahalı hata **içerik** hatasıydı, biçim değil. Bu iki kural diğer her kuralın önüne geçer.

**1. Kesinlik derecesi aynen kalır.** "olabilir", "muhtemelen", "-mIş olabilir", "bazı durumlarda" yazarın güven düzeyidir ve güven düzeyi içeriktir. Kısa cümle uğruna bir belirsizliği kesinliğe çevirmek sadeleştirme değildir, başka bir iddiadır. Türkçeye özgü ek nokta: **-dI ve -mIş farklı iddialardır.** "başarısız oldu" tanıklı kesinlik, "başarısız olmuş" çıkarım bildirir. Kaynakta hangisi varsa o kalır.

**2. Kaynakta olmayan hiçbir bilgi eklenmez.** Durum iddiası ("hiçbir yazma yapılmamıştır"), mekanizma ("daha yeni olan kazanır"), sonuç ("işlem otomatik tamamlanır"), nitelik ("geri alınamaz") kaynakta yoksa metinde de yoktur. Mantıksal çıkarım da eklemedir. Ajan açıklamaya güvenir ve o bilgiye göre davranır. Bilgi gerekli ama kaynakta yoksa: "Kaynakta belirtilmemiş." yaz.

Bir kesinti bu iki kuralı bozacaksa uzun hâli tut ve sonuna not düş (bkz. Çıktı biçimi).

## Yapısal kurallar: uygula

| Kural | Yap | Yapma |
|---|---|---|
| Cümle başına tek eylem | "Yedek alın. Bağlantıyı kontrol edin. Komutu çalıştırın." | "Yedek alıp bağlantıyı kontrol ederek komutu çalıştırın." (-Ip, -ArAk, -dIktAn sonra, "ve", "ya da" ile komut zinciri) |
| Noktalı virgül yok | "Aktarımı tekrar başlatmayın. Aksi hâlde kayıtlar çoğalır." | "Aktarımı tekrar başlatmayın; aksi hâlde kayıtlar çoğalır." Türkçe teknik yazımda "; aksi hâlde / ; ancak / ; yoksa" en sık zincir biçimidir. Noktalı virgül iki cümledir, nokta koy. |
| Cümle uzunluğu | Talimatta ≤15 sözcük, açıklamada ≤18 sözcük | Türkçe eklemeli dildir, aynı bilgi daha az sözcüğe sığar. STE'nin 20/25 sınırı Türkçede uzundur. |
| Özne açık | "Komut sorun bildirmezse yeniden deneyin." "Kullanıcı onay verdikten sonra çağırın." | "Sorun bildirmezse yeniden deneyin." (kim bildirmez?) "Onay alındıktan sonra çağırın." (kim alır?) Özne düşürme Türkçede doğaldır. Koşul veya edilgen cümlede **iki özne adayı varsa** özneyi yaz. Tek aday varsa düşür. |
| Sıfat-fiil yığını | Bir ismin önünde en fazla bir -An / -dIğI / -AcAk cümleciği | "Yapılandırılmış olan tüm arka uçlardaki durumu senkronize etmeye çalışacak olan sistem..." Böl. |
| Tamlama zinciri | En fazla 3 isim: "yakıt pompası valfi" | "arka uç görev kuyruğu öncelik işleyicisi" |
| Etken çatı, açık eylemci | "Ajan dosyayı siler." | "Dosya silinir." yalnızca eylemci gerçekten bilinmiyor veya önemsizse. "Onay alınır", "yazma yapılmaz" gibi eylemcisi önemli edilgenler yasak. |
| Komut veya koşul önce, gerekçe sonra | "Aktarımı tekrar başlatmayın. Aksi hâlde sipariş kayıtları çoğalır." | "Sipariş kayıtları çoğalmasın diye aktarımı tekrar başlatmayın." Gerekçe komutu gömer. Güvenlik komutu cümlenin ilk sözcükleriyle başlar. |
| Eksiltili cümle yok | Özne, yüklem ve gerekli tümleç yazılır | Yer kazanmak için sözcük atma: "Yedeklenmemiş dosyalar silinir." (hangi dosyalar? kim siler?) |
| Paragraf | Tek konu, ≤6 cümle | Çok konulu paragraf |
| Sıralı iş | 3+ adım veya koşul için numaralı liste | Sırayı tek bir düzyazı cümlesine gömmek |

## Sözcük kuralları: yön olarak uygula

Türkçe için onaylı bir sözlük yoktur. Bu kuralların denetlenebilen kısmı **metin içi tutarlılık**tır. Hangi sözcüğün "doğru" olduğu değil, aynı kavram için her yerde aynı sözcüğün kullanıldığı denetlenir.

| Kural | Yap | Yapma |
|---|---|---|
| Bir kavram, bir sözcük | Hep "kontrol et". Hep "sil". Hep "başlat". | "kontrol et / doğrula / teyit et" karışık. "sil / kaldır" karışık. |
| İngilizce-Türkçe karışımı da rotasyondur | Belgede ya "backend" ya "arka uç". Biri seçilir, hepsinde o kullanılır. | "Backend'leri senkronize eder: arka uçlar (backends) arasındaki..." Üç biçim, bir cümle. |
| Fiil, adlaştırma değil | "yazmayın", "kontrol edin", "güncelleyin", "analiz edin" | "yazma yapmayın", "kontrol yapın", "güncelleme gerçekleştirin", "analiz işlemini yapın" |
| Resmî kalıp yerine düz biçim | "gerekir" / emir kipi, "bu", "-se", "ile" | "gerekmektedir", "söz konusu", "-mesi hâlinde", "tarafından ... edilmesi", "-acak olup", "bulunmaktadır" |
| Pazarlama sıfatı yok | Sil, ya da iddiayı hak eden ölçümü yaz | kusursuz, sorunsuz, güçlü, zahmetsiz, son teknoloji, çığır açan, yenilikçi, hızlı ve güvenli |
| Alan terimi | Gerekli teknik terimi tut, yaygın değilse bir kez tanımla | Jargonu tanımsız bırakma |

## Tarama listesi

Yeniden yazmadan önce altısını da tara. Her biri mekaniktir: kuralı bozan sözcüğü veya işareti parmakla gösterebilirsin.

1. **Eşanlamlı rotasyonu**: aynı şey birkaç adla ("kullanıcı / müşteri / istemci", "backend / arka uç"). Düzelt: bir ad seç.
2. **Kip yığını**: "belirtmek gerekir ki bu durum potansiyel olarak ... yardımcı olabilir". Düzelt: iddiayı söyle veya sil. Gerçek belirsizlik taşıyan tek bir "olabilir" kalır.
3. **Adlaştırma**: "-ma yapmak", "-ma gerçekleştirmek", "-ma işlemini uygulamak". Düzelt: fiil.
4. **Pazarlama sıfatı**: kusursuz, sorunsuz, güçlü. Düzelt: sil veya ölçüm.
5. **Zincir cümle**: noktalı virgül, "olup", "-ip", "-arak", "aksi takdirde" ile bağlı birden çok fikir. Düzelt: cümle başına bir fikir.
6. **Düşmüş özne**: iki adaylı koşul veya edilgen. Düzelt: özneyi yaz.

## Süreç

1. Kipi seç (Sıkı / Esnek).
2. Metni önce anlam için bir kez oku. Yeniden yazmadan ne söylemesi gerektiğini bil.
3. Cümle cümle ilerle. Önce İçerik kurallarını, sonra Yapısal kuralları ve Tarama listesini uygula. Esnek kipte sözcük kurallarını işaretle ama zorlamadan geç. Mekanik ilk geçiş için `python3 scripts/sade-lint.py` çalıştır (stdin veya dosya, `--json` yapısal çıktı). Noktalı virgül, cümle uzunluğu, komut zinciri, adlaştırma, pazarlama sıfatı, resmî kalıp, eşanlamlı rotasyonu ve İngilizce-Türkçe karışımını denetler. **Kipi ve "olabilir"i asla işaretlemez**: bunlar içeriktir.
4. Her işaretli cümleyi anlamı aynen koruyarak yeniden yaz.
   - **Yazmadan önce kesinlik derecesini kontrol et.** Uzunluk sınırının kesmeye en çok ittiği sözcük "olabilir"dir. Onu kesen cümle kısalmış değil, değişmiş olur.
   - **Kaynağa olmayan bilgi ekleme.** Daha iyi okunuyorsa çünkü bir neden, bir durum ya da bir mekanizma eklediysen o artık yeniden yazım değildir.
   - Bir kesinti gerekli bir koşulu, kapsam sınırını veya sayıyı düşürecekse uzun hâli tut ve not düş.
5. Çıktıyı ver (bkz. Çıktı biçimi).
6. Metin zaten uyumluysa öyle de. Uyumlu metne değişiklik dayatma.

## Çıktı biçimi

**Varsayılan: yalnızca yeniden yazılmış metin.** Giriş yok, kip duyurusu yok, ihlal sayısı yok, değişiklik özeti yok, "başka bir şey ister misiniz" yok.

İzinli tek ek: 4. adımda bilerek uzun bırakılan bir yer varsa metnin altına tek satır, `Olduğu gibi bırakıldı:` ile başlar, ifadeyi ve korunan kesinliği adlandırır. Bu satır da kurallara uyar: noktalı virgül yok, birden çok madde varsa her biri ayrı cümle. Gözlendi: not satırında üç madde noktalı virgülle zincirlendi.

**İstek üzerine kural tablosu.** Kullanıcı "farkı göster", "hangi kuralı bozdu", "önce/sonra" derse tabloyu ver:

```markdown
| Bozulan kural | Özgün | Sade |
|---|---|---|
| Kip yükseltme | "başarısız olmuş olabilir" | "başarısız olmuş olabilir" (korundu) |
| Noktalı virgül | "başlatmayın; aksi hâlde" | "başlatmayın. Aksi hâlde" |

Kip: Sıkı. 7 ihlal.
```

Tablonun altına bilerek sadeleştirmediğin şey varsa tek satır not.

## Bahane tablosu

Baseline testlerde ajanların kullandığı gerekçeler. Bunlardan birini düşünüyorsan dur.

| Bahane | Gerçek |
|---|---|
| "Başarısız olduğu zaten belli, 'olabilir' fazlalık." | Kaynak kesin demedi. Kesinlik eklemek yeni bir iddia. Gözlendi: "başarısız olmuş olabilir" → "başarısız oldu". |
| "Ajana faydalı olsun diye durumu belirttim." | Kaynakta yok. Ajan buna güvenir ve geri alma adımını atlar. Gözlendi: "Hiçbir yazma yapılmamıştır." |
| "Bu uydurma değil, mantıksal çıkarım." | Çıkarım da eklemedir. Kaynakta yoksa "belirtilmemiş" yaz. Gözlendi: "daha yeni olan kazanır." |
| "İki cümle sınırı vardı, noktalı virgülle sığdırdım." | Noktalı virgül iki cümledir. Sınıra sığmıyorsan gerekçeyi kes, koşulu değil. |
| "Özne bağlamdan anlaşılıyor." | İki aday varsa anlaşılmıyor. Gözlendi: "sorun bildirmezse", "onay alındıktan sonra". |
| "Sıralı adımlar zaten 'ancak ondan sonra' diyor, koşula çevirdim." | Sıra ile koşul farklı iddiadır. "Önce A, sonra B" demek "A başarılıysa B" demek değildir. |
| "Teknik terim İngilizce kalsın, açıklaması Türkçe olsun." | Olabilir. Ama tek biçimde: ya "backend" ya "arka uç". Parantezli üçüncü biçim yok. |

## Kırmızı bayraklar

- Kaynaktaki bir "olabilir" çıktıda yok.
- Çıktıda kaynakta olmayan bir -mIştIr / -mAz / -Ir iddiası var.
- Bir cümlede noktalı virgül var.
- Bir komut cümlesinde -Ip veya -ArAk ile ikinci bir komut var.
- Koşul cümlesinin öznesi yok ve iki aday var.
- "yapmak / gerçekleştirmek / uygulamak" yanında -ma / -me isim var.
- Aynı kavram için ikinci bir sözcük kullandın.

**Hepsi aynı anlama gelir: o cümleye dön, kaynağı yeniden oku.**

## Sınırlar

**Yapar:**
- Belirsiz veya yoğun Türkçeyi kısa, tek anlamlı, etken cümlelere çevirir.
- Varsayılan olarak yalnızca metni döndürür, istenirse kuralları adlandırır.
- Her olguyu, koşulu, kapsam sınırını, kesinlik derecesini ve kanıtsallığı korur.
- Kalması gereken alan terimleri için tek satırlık sözlük önerir.

**Yapmaz:**
- Yaratıcı, pazarlama veya ikna metnini sadeleştirmez.
- Kısaltmak için güvenlik koşulu, istisna veya kapsam sınırı düşürmez. Bunun yerine not düşer.
- "başarısız olmuş olabilir"i "başarısız oldu"ya çevirmez.
- Kaynakta olmayan durum, neden, mekanizma veya sonuç eklemez.
- Boş içeriği doğru veya faydalı yapmaz. STE biçimi düzeltir, özü değil. Metnin söyleyecek bir şeyi yoksa bunu söyler, metni cilalamaz.
- Netlik sınırını geçip kısaltmaz. Hedef az sözcük değil, tek anlamdır.

## Her zaman açık kullanım

Bu skill `~/.claude/CLAUDE.md` üzerinden varsayılan yanıt stili olarak yüklendiğinde **Esnek** kip kendi yanıtlarına uygulanır: tek eylemli cümleler, noktalı virgül yok, açık özne, kesinlik korunur, bilgi eklenmez. Sözcük kuralları öneri olarak kalır. Kullanıcı bir metni "sadeleştir" dediğinde bu dosyanın tamamı ve Sıkı kip devreye girer.

## Ek kaynaklar

- `examples/once-sonra.md`: baseline testlerden türetilmiş önce/sonra örnekleri, bozulan kuralla birlikte.
- `scripts/sade-lint.py`: yalnızca standart kütüphane kullanan deterministik linter. `--selftest` ile "başarısız olmuş olabilir" cümlesinin temiz geçtiğini doğrular. Satıra sarılmış paragrafı tek metin olarak denetler. Liste maddesi, tablo hücresi, başlık ve code block ayrı kalır.
- İngilizce metin için kardeş skill: `asd-ste100`.
