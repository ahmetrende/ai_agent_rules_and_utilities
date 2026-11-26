# oturum modu: Claude oturumları ve devir notları ekranı

Mod `/oturum` komutunu ve Claude Desktop'ta bir yan panel ekler. Panel bu makinedeki ve SSH ile bağlı makinelerdeki oturumları gösterir. Her oturumun son devir notunun metadata'sı da görünür.

Kaynak: `local-mods/oturum/`. Mod hook, ayar veya dosya değiştirmez. Yalnız "Toplu devir notu" düğmesine basınca seçilen oturumlara mesaj gönderir.

## Ne gösterir

`/oturum` çalışınca iki şey olur. Komut cevabında devir notu olan oturumlar blok blok listelenir. Yan panel açılır ve aynı listeyi arama, filtre ve sıralamayla gösterir.

Yalnız devir notu olan oturumlar görünür. Devir notu olmayanların sayısı en altta yazar. `agent-a9` gibi alt agent oturumları gösterilmez.

Her oturum bir bloktur. Bloklar numaralıdır ve aralarında bir boş satır vardır. Blokta şunlar yazar:

- Kalın başlık: numara ve oturum adı. Oturum adı önce `customTitle`, yoksa `aiTitle`, ikisi de yoksa oturum kimliğinin ilk 8 karakteridir.
- Küçük satır: makine · hesap · devir notunun son yazılma saati (`yyyy-MM-dd HH:mm`, Türkiye saati). Yerel makine "Mac (bu makine)" diye yazar.
- Klasör: yeni oturumun açılacağı klasör. Worktree oturumunda ana repo klasörüdür.
- Uyarılar, yalnız gerektiğinde: "⚠ nottan sonra 2 sa daha çalıştı" (oturum devir notundan 10 dakikadan uzun süre sonra da çalıştıysa not eski olabilir) ve "⚠ detay notu yok".
- Sohbetteki cevapta prompt code block'ta yazar. Devir notunun yolu prompt'un içindedir, ayrıca yazılmaz. Yan panelde prompt yazmaz: "Prompt'u kopyala" ve "Klasörü kopyala" düğmeleri panoya kopyalar.

Prompt: "Önceki oturumun işine devam ediyorum. <yol> devir notunu ve bağlı detay notunu tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle."

Komut cevabındaki liste devir notu en yeni olan üstte olacak biçimde sıralanır. Panel son harekete göre sıralar. Komut cevabı en çok 15 oturum gösterir. Yan panel hepsini gösterir.

Yan panelin üstünde son yenileme saati ve "Yenile" düğmesi, altında arama kutusu (oturum adı, yol veya hesap), onun altında yan yana üç açılır menü vardır: hesap, makine ve sıralama (yeniden eskiye, eskiden yeniye, ada göre).

### Hesap

Hesap, oturumun başladığı Claude organizasyonudur. Transcript bunun kimliğini tutar (`credential_org`). Kimliğin adı `local/accounts.md` dosyasından gelir. Örnek: `local.example/accounts.md`. Dosyada olmayan veya transcript'te kimliği olmayan oturumda "hesap bilinmiyor" yazar. Komut hangi hesapla açılırsa açılsın iki hesabın oturumlarını birlikte gösterir.

## Toplu devir notu

Panel, açık Claude oturumlarından seçtiklerine devir notu yazma isteği gönderir. Ayrı bir liste getirme düğmesi yoktur. `/oturum` ve "Yenile" düğmesi hem `sessions.py` verisini hem de açık oturumları (`ListAgents` aracı) yeniler.

1. Açık oturumların satırında ☐ kutusu vardır. Kutu satırın ilk satırıdır. Kapalı oturumda kutu yoktur.
2. Kapalı bir oturum için önce onu Desktop'ta aç. Sonra "Yenile"ye bas.
3. Kutuları seç. "Tümünü seç" filtrelerin gösterdiği açık satırları seçer. "Seçimi temizle" seçimi siler.
4. "Seçilenler için devir notu yazdır (N)" düğmesine bas. Hiç seçim yokken düğme soluk görünür ve basınca "Önce oturum seç" yazar. Seçili oturumlara sırayla birer mesaj gider.

Eşleştirme oturum adıyla yapılır. `ListAgents` satırında yalnız ad, ref, tür ve durum vardır. Oturum kimliği, makine ve zaman yoktur. Bu yüzden bir açık oturumun adı `sessions.py` oturumunun adıyla birebir aynıysa ikisi eşleşir. Aynı ada sahip birden çok oturum varsa en yeni son hareketli oturumlar sırayla eşleşir. Eşleşen oturumun devir notu olmasa da satırı görünür. Oturumu bulunamayan açık oturum yalnız adıyla görünür. Makine, hesap ve son hareket bilinmez.

Desktop uygulamasında arşivlenen oturumlar varsayılan olarak gizlenir. Arşiv bilgisi transcript dosyalarında değil, uygulamanın kendi oturum listesindedir. Mod bu listeyi `ccd_session_mgmt` MCP sunucusunun `list_sessions` aracıyla (`include_archived`) okur. `/oturum` ve "Yenile" bunu da yeniler. Eşleştirme oturum adı ve klasörle yapılır. Aynı ad ve klasördeki oturumlardan biri arşivli değilse hiçbiri gizlenmez. Açık oturumlar hiçbir zaman gizlenmez. Filtrelerin yanındaki "☐ Arşivlenenleri göster" düğmesi gizlenenleri "arşivlendi" durumuyla gösterir. Alt bilgide "arşivlenen N gizli" yazar. MCP sunucusuna ulaşılamazsa veya cevap JSON liste değilse hiçbir oturum gizlenmez. Panel "Arşiv listesi okunamadı: ... Arşivlenenler de görünüyor." satırını yazar. Bu sunucunun bir modden erişilebildiği doğrulanmadı.

Her satırın ikinci satırında makine, hesap, son hareket saati ve durum (boşta, çalışıyor, kapalı) yazar. Sıralama son harekete göredir. Gönderimden sonra satırda "devir isteği gönderildi HH:MM TR" veya "gönderilemedi: sebep" yazar.

Mesajda `[oturum:toplu-devir]` işareti vardır. Alıcı oturumdaki `hooks/context-pressure.sh` bu işareti görünce tam devir notu isteğini (kurallar ve dosya yolu) o tura ekler. Hook notu gelmezse mesajın kendisi kısa kuralları da taşır.

Sınırlar:

- Çevrimdışı oturum mesaj alamaz.
- Çalışan oturum mesajı sıradaki adımında okur.
- Her oturum bir tur çalışır ve o anki hesabın limitinden harcar.
- Başka izin kipindeki oturum mesajı kullanıcının onayına kadar tutabilir.
- "Gönderildi", mesajın alıcının kuyruğuna girdiği anlamına gelir. Notun yazıldığını göstermez.

"Seçilenlerin bilgilerini kopyala" butonu seçili oturumların bilgilerini tek seferde panoya koyar. Her oturum için üç satır yazar: "Oturum ismi:", "Klasör:" ve "Prompt:". Oturumlar arasında boş satır olur. Devir notu henüz listede olmayan oturumda prompt yerine bir uyarı yazar: notlar yazılınca Yenile'ye bas, sonra kopyala. Seçim yokken buton soluk görünür.

## Veri nereden gelir

Veri `local-mods/oturum/bin/sessions.py` script'inden gelir. Python 3 kurulu olmalı. Başka paket gerekmez.

- Oturumlar: `<config>/projects/*/*.jsonl`. `<config>` değeri `CLAUDE_CONFIG_DIR` veya `~/.claude`. Alt klasörlerdeki subagent dosyaları sayılmaz. Son 3 günde değişen dosyalar alınır (`--days N` ile değişir).
- Devir notu: oturumun cwd klasöründeki `.claude/` içinde `*-handoff-<oturum kimliği>.md` veya `handoff-<oturum kimliği>.md`. Cwd bir worktree ise (`/.claude/worktrees/` içeriyorsa) ana repo'nun `.claude/` klasörüne de bakılır. Birden çok dosya varsa en yenisi seçilir.
- Döküm: `<config>/handoff-dumps/<devir notu adı>.transcript.md`.

Script'i elle de çalıştırabilirsin:

- `python3 local-mods/oturum/bin/sessions.py --text` bu makineyi komut cevabındaki biçimde yazar.
- `python3 local-mods/oturum/bin/sessions.py --json` bu makineyi JSON olarak yazar.
- `python3 local-mods/oturum/bin/sessions.py --all --text` SSH makinelerini de ekler. Aynı oturum iki makinede görünürse klasörü o makinede olan kayıt kalır.

## machines.md biçimi

SSH makineleri `local/machines.md` dosyasından okunur. Dosya repo'da yoktur, makineye özeldir. Örnek: `local.example/machines.md`. Her makine bir satırdır:

```
- <makine adı>: `ssh <ssh argümanları>`, repo yolu `<repo yolu>`
```

Repo klasörü şu sırayla bulunur:

1. `AI_AGENT_RULES_DIR` ortam değişkeni.
2. `<config>/CLAUDE.md` içindeki `@<yol>/AGENTS.md` satırı.
3. Script'in üç seviye üstündeki klasör, içinde `AGENTS.md` varsa.

`machines.md` yoksa bu bir hata sayılmaz. Panel yalnız bu makineyi gösterir ve bir not yazar. Makine satırı biçime uymuyorsa not düşülür, satır atlanır.

## SSH gereksinimi

Her uzak makine için script şu komutu çalıştırır. Makineler paralel çalışır.

```
ssh -n -o BatchMode=yes -o ConnectTimeout=10 <argümanlar> 'cd <repo yolu> && python3 local-mods/oturum/bin/sessions.py --json --days N'
```

- `BatchMode=yes` olduğu için şifre sorulmaz. Anahtarla giriş (ssh-agent veya parolasız anahtar) hazır olmalı.
- Uzak makinede repo'nun güncel olması gerekir. Script orada yoksa `git pull` çalıştır.
- Bir makine hata verirse panelde adının altında ilk stderr satırı görünür. Diğer makineler yine gösterilir.
- `~/x` biçimindeki repo yolu uzakta `"$HOME"/x` olarak açılır.

## Kurulum

Mod `local-mods` marketplace'indedir. `usage-feed` ile aynı yoldan kurulur. Desktop uygulaması SSH ile bir sunucuya bağlıysa Claude Code sunucuda çalışır. Modu o sunucuya kur. Panel o oturumda sunucunun ve `machines.md` içindeki makinelerin verisini gösterir.

Kurulumdan önce repo'nun kökünde şunları çalıştır:

1. `python3 -m unittest discover -s local-mods/oturum/bin`
2. `claude plugin validate local-mods/oturum`
3. `claude plugin test local-mods/oturum`

## Sınırlar

- Tarama oturum başına transcript dosyasını baştan sona okur. 10 MB üstü dosyalar taramayı yavaşlatır. Tarama için süre sınırı 90 sn (komut) ve makine başına 120 sn (SSH).
- Yalnız son N günde değişen oturumlar listelenir. Daha eski oturum görünmez.
- Devir notu cwd'ye göre aranır. Not başka bir klasöre yazıldıysa "devir notu yok" görünür.
- Oturum adı ve cwd transcript içindeki en yeni kayıttan okunur. Biçim değişirse alan boş kalır.
- `$.process.run` komutu Claude Code motorunun çalıştığı makinede çalıştırır. Tip dosyasında "CLI only" yazıyor. Desktop yerel oturumunda çalıştığı 2026-11-23 doğrulandı.
- Komut cevabı en çok 15 oturum yazar. Panelde sınır yoktur.
- Mod sonucu `$.state` içinde tutar. Oturum kapanınca veri gider. Panel ilk açılışta boştur, "Yenile" veya `/oturum` gerekir.
- Mac'te `/home/...` yollarının her kontrolü ~20 ms sürer. sessions.py klasör kontrollerini önbelleğe alır: var olmayan bir üst klasörün altındaki yollara bakmaz.
