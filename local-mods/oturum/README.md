# oturum

`/oturum` komutunu ve Claude Desktop'ta bir yan panel ekler.
Panel, Claude oturumlarını ve son devir notlarının metadata'sını gösterir. Bu makineyi ve `local/machines.md` içindeki SSH makinelerini kapsar.

`/oturum` script'in hazır Markdown metnini (`text`) döndürür. Panel yalnız devir notu olan oturumları listeler. Her oturum kalın çizgiyle ayrılmış bir blok olur: ad, makine, hesap, devir notu zamanı, uyarılar, devir notu yolu ve prompt. Üstte arama kutusu, Hesap, Makine ve Sıralama seçicileri vardır.

Panelin ve `/oturum` metninin üstünde her hesabın son kullanım ölçümü vardır: 5-hour limit, Weekly ve ölçüm saati. Değerler usage-feed modunun bu makinede yazdığı `usage-feed/feed-*.json` dosyalarından gelir. Sıfırlanma saati geçmiş bir pencere "sıfırlandı" olarak görünür.

Veri `bin/sessions.py` script'inden gelir (Python 3, yalnız standart kütüphane). Mod hook, ayar veya dosya değiştirmez. Yalnız "Toplu devir notu" düğmesine basınca mesaj gönderir.

## Toplu devir notu

Açık oturumlar `/oturum` ve "Yenile" ile otomatik yüklenir (çevrimdışılar hariç). Yalnız açık oturumun satırında ☐ kutusu vardır. Kapalı oturum için önce onu Desktop'ta aç, sonra Yenile'ye bas. Eşleştirme oturum adıyla yapılır: aynı adlı iki açık oturum en yeni son hareketli iki oturumla eşleşir. Desktop'ta arşivlenen oturumlar gizlenir (`ccd_session_mgmt` `list_sessions` ile okunur, ad ve klasörle eşleşir). "Arşivlenenleri göster" düğmesi onları "arşivlendi" olarak gösterir. Liste okunamazsa hiçbiri gizlenmez ve panel bunu yazar. "Seçilenler için devir notu yazdır (N)" düğmesi seçilen her oturuma `[oturum:toplu-devir]` işaretli bir mesaj gönderir. Alıcı oturumda `hooks/context-pressure.sh` işareti tam devir notu isteğine çevirir.

Sınırlar:

- Çevrimdışı oturum mesaj alamaz.
- Çalışan oturum mesajı sıradaki adımında okur.
- Her oturum bir tur çalışır ve o anki hesabın limitinden harcar.
- Başka izin kipindeki oturum mesajı kullanıcının onayına kadar tutabilir.

Dosyalar:

- `bin/sessions.py`: oturumları ve devir notlarını tarar. `--json`, `--text`, `--all`, `--days N`.
- `bin/test_sessions.py`: script testleri.
- `hooks/register.tsx`: `/oturum` komutu ve panel.
- `hooks/register.test.tsx`: mod testleri.
- `types/index.d.ts`: JSON şeması ve `$.state` anahtarı.

Testler (repo kökünden):

- `python3 -m unittest discover -s local-mods/oturum/bin`
- `claude plugin test local-mods/oturum`
- `claude plugin validate local-mods/oturum`

Kurulum, makine listesi biçimi ve sınırlar: ai_agent_rules repo'sunda `docs/oturum_mod.md`.

"Seçilenlerin bilgilerini kopyala" butonu seçili oturumların bilgilerini tek seferde panoya koyar. Her oturum için üç satır yazar: "Oturum ismi:", "Klasör:" ve "Prompt:". Oturumlar arasında boş satır olur. Devir notu henüz listede olmayan oturumda prompt yerine bir uyarı yazar: notlar yazılınca Yenile'ye bas, sonra kopyala. Seçim yokken buton soluk görünür.
