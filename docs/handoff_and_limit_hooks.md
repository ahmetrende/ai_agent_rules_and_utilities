# Claude Code hook'ları — kurulum ve kaldırma (tek dosya)

Kaynak artık bu repo'dur. Dosyalar repo'daki `hooks/` ve `local-mods/` klasörlerindedir. Kurulumu repo kökündeki `install.sh` yapar. Değişikliği repo'da yap, test'ini aynı commit'e koy. Sonra her makinede `git pull` ve `./install.sh` çalıştır.

Hedef: Linux (Ubuntu) ve macOS, Claude Code Desktop veya CLI (CLI'da Grup B için `usage-feed` modu gerekir). Aynı dosyalar iki sistemde değişmeden çalışır.

Nereye kurulur: Claude Code'un çalıştığı makineye. Desktop uygulaması SSH ile bir sunucuya bağlanıyorsa Claude Code sunucuda çalışır. `install.sh` o SSH oturumunda çalışmalı. Dosyalar sunucunun `~/.claude` dizinine yazılır. Desktop'ın çalıştığı bilgisayara (ör. Mac) kurulum gerekmez. O bilgisayarda SSH'siz, yerel bir oturum açarsan o bilgisayarın `~/.claude` dizini okunur. Bu durumda kurulumu orada ayrıca yap.

SSH ile açılan Desktop oturumu bu belgelerde Desktop oturumu sayılır. Sunucu terminalinde doğrudan `claude` komutuyla açılan oturum CLI oturumudur.

Belgeler:
1. `usage_feed_mod.md`: isteğe bağlı. Yalnız CLI kullanılan makinede Grup B için gerekir.
2. `handoff_and_limit_hooks.md` (bu belge).
3. `subagent_setup.md`: öteki iki belgeden bağımsızdır.

Sıra değişirse veri bozulmaz. `get_usage` aracı ve mod yoksa Grup B okuma yapamaz (§1 ön koşullar).

Testler: `hooks/tests/run-tests.sh` (Grup A) ve `hooks/tests/run-ul-tests.sh` (Grup B). İkisi de bash script'idir. Hook klasörünü ve bir koşu etiketini argüman olarak alır. Örnek: `bash hooks/tests/run-tests.sh hooks normal-A`. Yedek-araç PATH'i ile koşu (`tac` ve `sha1sum` yok, BSD `stat` ve `tail -r`) için `hooks/tests/shims/stat` ve `shims/tail` kullanılır.

## İçindekiler

1. Ne kurulur
2. Nasıl çalışır
3. Kaldırma prompt'u: Grup A (handoff)
4. Kaldırma prompt'u: Grup B (kullanım limiti)

---

## 1. Ne kurulur

| Grup | Dosya | Olay | Görev |
|---|---|---|---|
| A | `~/.claude/hooks/context-pressure.sh` | `UserPromptSubmit`, `PostToolBatch`, `Stop` | Bağlam eşiği geçince Claude'a memory ve handoff yazdırır. Eşik 300K token'dır. usage-feed modu oturumun context penceresini bildirirse eşik pencerenin %60'ıdır, ama 300K'yı geçmez: 200K pencerede 120K, 1M pencerede 300K. Her kullanıcı mesajında ve her araç grubundan sonra bakar; uzun araç döngüsünde de uyarır. Eşik üstünde her yeni 10K adımında Claude'a güncel bağlam boyutunu verir. CLEAR veya COMPACT satırı bu boyutu yazar. `Stop`'ta denetler: CLEAR veya COMPACT satırıyla biten turda devir notu yazılmadıysa cevabı bir kez geri gönderir. |
| A | `~/.claude/hooks/session-end-mark.sh` | `SessionEnd` | Biten oturumu proje kaydına ekler. |
| A | `~/.claude/hooks/handoff-load.sh` | `SessionStart` | `/clear` sonrası biten oturumun notunu yükler. İlk cevap `Handoff yüklendi: …` satırıyla başlar. Nottan sonra oturumda yeni istem varsa notun önüne uyarı koyar. |
| B | `~/.claude/hooks/usage-limit.sh` | `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolBatch` | 5 saatlik veya haftalık limit %90'ı ve %95'i geçince çalışan oturumları birer kez durdurur, devir notu yazdırır. %90 üstünde her cevabın sonunda uyarı ve yeni oturum prompt'u verir. |
| B | `~/.claude/hooks/usage-limit.conf` | — | Grup B ayarları. |
| Test | `~/.claude/hooks/tests/run-tests.sh`, `run-ul-tests.sh`, `shims/stat`, `shims/tail` | — | Grup A ve Grup B test paketleri. |

Ön koşullar:
- Araçlar: `bash` (3.2+), `jq`, `iconv`, `awk`, `sed`, `find`, `sort`, `head`, `tail`, `wc`, `cut`, `tr`, `mktemp`, `date`, `grep`. Ayrıca `sha1sum` veya `shasum`, `tac` veya `tail -r`, GNU veya BSD `stat`.
- Grup B'nin limit okuması iki kaynaktan gelir: Claude Desktop'ın `mcp__ccd_session_mgmt__get_usage` aracı veya `usage-feed` modu (`usage_feed_mod.md`). Bu belge modu kurmaz.
- Desktop oturumunda ikisi de çalışır. Mod yüklüyse `get_usage` çok daha seyrek istenir.
- Terminal CLI oturumunda `get_usage` yoktur. Mod da yoksa Grup B okuma yapamaz: 3 denemeden sonra 30 dakika, aynı oturumda ikinci kez olursa 24 saat devre dışı kalır.
- Yalnız CLI kullanılan makinede (örneğin Desktop'sız bir Ubuntu sunucu) Grup B yalnız mod kuruluysa okuma yapabilir.
- Yapılandırma dizini: `CLAUDE_CONFIG_DIR` ayarlıysa o, değilse `~/.claude`. Script'ler bunu kendileri okur. Bu belgede `~/.claude` o dizin anlamındadır.
- Her makine ve her workspace diski ayrı kurulur.

Grup A eşiği: `context-pressure.sh` 300000 token'da uyarır. Mod oturumun pencere boyutunu bildirirse ve `CTX_PRESSURE_WINDOW_PCT` (varsayılan 60) yüzdesi daha düşükse o eşik geçerlidir (200K pencerede 120000). `CTX_PRESSURE_THRESHOLD` ayarlıysa o kazanır. Mod yoksa 200K pencereli oturum 300K'ya hiç ulaşmaz, bu yüzden uyarı almaz.

Hook kayıtları `~/.claude/settings.json` içindedir. Her kayıt `type: command`, `timeout: 5` taşır. `SessionStart` kaydının matcher'ı `startup|resume|clear|compact` olur ve `fork` yoktur. Grup B'nin `PostToolUse` matcher'ı `Write|Edit|MultiEdit|mcp__ccd_session_mgmt__get_usage` olur. Hook değişikliği çalışan oturumlarda sonraki araç grubunda geçerli olur, yeniden başlatma gerekmez.

---

## 2. Nasıl çalışır

### Grup A (handoff)

1. Bağlam eşiği geçince (varsayılan 300K, pencere biliniyorsa en çok pencerenin %60'ı) Claude önce memory'yi, sonra `<proje>/.claude/<oturum-adı>-handoff-<session_id>.md` dosyasını yazar.
   - `<oturum-adı>`, Desktop kenar çubuğunda görünen oturum adıdır (örnek: `MyProject-handoff-8148da30-….md`). Türkçe harfler ASCII'ye döner. Boşluk ve işaretler `-` olur. Büyük-küçük harf korunur. En çok 50 karakterdir.
   - Ad kaynağı sırası: transcript'teki en yeni `customTitle` kaydı, `CLAUDE_CODE_SESSION_NAME` (Desktop SSH oturumlarında açılışta verilir), en yeni `aiTitle` kaydı. Hiçbiri yoksa proje klasörünün adı kullanılır.
   - `<proje>` klasörü değişmez: oturumun çalıştığı klasördür (örnek: `~/projects/my-project`).
   - Oturumun adı değişirse hook bir sonraki uyarıda eski dosyayı yeni ada taşır. Hook'lar dosyayı oturum kimliğiyle bulur, bu yüzden eski adlı dosyalar da bulunur.
   - Claude doğal bir durakta cevabı tek satırla bitirir: CLEAR veya COMPACT, bağlam boyutu (`~350K token`), kısa neden, devir notunun son yazılma saati (`handoff 14:32`) ve devir notu yolu. Örnek: `CLEAR · ~915K token · iş bitti · handoff 14:32 · ~/my-project/.claude/MyProject-handoff-<id>.md`.
   - **Not saati:** saat Türkiye saatidir (UTC+3, yaz-kış aynı, 2016'dan beri). Hook bölge dosyası kullanmaz, UTC'ye 3 saat ekler. Claude saati kendisi hesaplamaz: ilk uyarıdan sonra not her yazıldığında, sonraki araç grubunda (`PostToolBatch`) hook şu notu verir: `Handoff time: <dosya> was last written at 14:32 Turkey time (UTC+3)`. Not yalnız ilk uyarıdan sonra yazılan ve son nottan yeni olan yazım için gelir (`state/<session_id>.hnote`).
   - Boyut transcript'teki son ana-oturum kaydından gelir. Hook her 100K kovada bir tam uyarı verir. Kova içinde her yeni 10K adımında tek satırlık boyut notu verir. Satırdaki sayı en çok bir adım eskidir.
   - Desktop arayüzü bağlam boyutunu artık göstermiyor. Bu satır o bilgiyi verir.
   - İlk uyarıdan sonra CLEAR veya COMPACT satırıyla biten her cevap, aynı turda devir notunu günceller. En azından kullanıcının son isteği ve durumu nota girer. Taslak, gönderilen mesaj, karar, onay, açık soru ve yeni adım da girer.
   - **Stop denetimi:** cevap CLEAR veya COMPACT satırı taşıyorsa ve notun mtime'ı turun başından eskiyse hook cevabı bir kez geri gönderir. Claude notu günceller ve satırı tek başına yeniden yazar. Turun başı: `UserPromptSubmit` anında kaydedilen saat (`state/<session_id>.turn`) veya transcript'teki en yeni istem ya da olay kaydı. Hangisi yeniyse o alınır. `stop_hook_active` doğruysa hook susar, döngü olmaz.
   - **Saat denetimi:** not bu turda yazıldıysa hook satırdaki saati notun gerçek saatiyle karşılaştırır. Satırda `handoff` sözcüğünden sonra en çok 40 karakter içinde `SS:DD` aranır. `handoff güncel (14:32)` ve `Handoff 9:05` de sayılır. Saat yoksa veya farklıysa hook cevabı bir kez geri gönderir. Geri gönderim doğru saati verir, Claude satırı tek başına yeniden yazar. Satır dışındaki saatler ve yoldaki rakamlar sayılmaz.
2. Sen `/clear` yazarsın.
3. İlk mesajı 10 dakika içinde gönderirsin.
4. Projede son 10 dakikada tek oturum `/clear` (`clear`) veya Desktop'ın `/clear` kapanışıyla (`other`) bittiyse hook o oturumun notunu yükler. `prompt_input_exit`, `logout` ve `resume` kapanışları sayılmaz.
5. Yeni oturumun ilk satırı `Handoff yüklendi: <dosya> (<yaş> önce yazılmış)` olur.
6. **Tazelik denetimi:** hook yüklemeden önce biten oturumun transcript'ini okur. Notun mtime'ından sonraki kullanıcı istemlerini ve olayları sayar.
   - Olay: `task-notification`, `ci-monitor-event`, `side-sessions-event`, `cross-session-message`, `[AUTOMATIC CHECK` / `[OTOMATİK KONTROL` ile başlayan kayıt ve yalnız `system-reminder` taşıyan kayıt.
   - Sayılmayan: araç sonuçları, meta kayıtlar, compact özetleri, komut çıktıları (`<local-command-…>`, `<bash-stdout>`), kesinti kayıtları.
   - En az bir istem varsa notun önüne uyarı gelir: sayılar, son turun saati, transcript yolu ve son istemin ilk 300 baytı. İlk satır şöyle olur: `Handoff yüklendi: <dosya> (<yaş> önce yazılmış; sonrasında 3 istem, 1 olay var)`.
   - Uyarı varken yeni oturum ilk cevapta transcript'in o kayıtlarını okur ve notu tamamlar. Not gövdesi 8000 yerine 7000 bayta kesilir.
   - Yalnız olay varsa uyarı gelmez. Transcript okunamazsa uyarı gelmez, not yine yüklenir, log bir satır yazar.
   - Hook transcript'in son 4 MB'ını ve son 2000 satırını okur. Bu pencere notun saatine uzanmıyorsa sayılar "en az" diye verilir.

Eski notun yeni oturuma yanlış durum olarak sunulmasına karşı üç katman vardır: uyarı metni her CLEAR turunda güncelleme ister, Stop denetimi bunu zorlar, yükleyici kaçan turları bulur ve yeni oturuma okutur.

Bedel: durumu değiştirmeyen bir CLEAR turunda da Claude notu yazmak zorunda kalır. Stop denetimi bir tur ekleyebilir. Durum değişmediyse yükleyici uyarısı yeni oturuma gereksiz bir transcript okuması yaptırır.

Bu kesin eşleşme değildir, tek yakın aday tahminidir. O 10 dakikada aynı projede ilgisiz bir iş açarsan not yine yüklenebilir. Bu durumda ilk cevap notun başka bir işe ait olduğunu söyler ve notu kullanmaz.

Aynı projede iki oturum 10 dakika içinde biterse hook not yüklemez. Yalnız liste verir. Kapanış kaydı kilit altında alınır: iki yeni oturum aynı notu almaz.

Proje bir git deposundaysa ve devir notu yolu git-ignore değilse, uyarı mesajı bunu söyler. Önerilen satır: `**/.claude/*handoff*.md`, `.git/info/exclude` (yalnız bu klon) veya `.gitignore` içine.

### Üç dosyalı devir

Bir oturum devir notu yazınca üç dosya oluşur. Yeni oturum başka bir Claude hesabında veya Codex'te de kayıpsız devam edebilsin diye.

| Dosya | Yol | Kim yazar |
|---|---|---|
| Devir notu | `<proje>/.claude/<oturum-adı>-handoff-<session_id>.md` | Model. En çok 6000 karakter. READ FIRST ile başlar. |
| Detay notu | Devir notuyla aynı yer, sonu `.detay.md` | Model. Boyut sınırı yok. |
| Tam döküm | `~/.claude/handoff-dumps/<devir notu adı>.transcript.md` | Hook (`handoff-dump.py`). Model yazmaz. |

- Model önce detay notunu, sonra devir notunu yazar.
- Detay notunda sekiz başlık zorunludur: `## Decisions and reasons`, `## User requests in their words`, `## Open tasks`, `## Background jobs`, `## Ruled out and why`, `## Lessons learned`, `## Memory changes`, `## Environment`. Boş başlığın altına "Yok." yazılır. Başlık atlanmaz.
- Detay notu eksikse hook modele eksik başlıkları söyler. CLEAR veya COMPACT satırlı cevabı bir kez geri gönderir.
- Hook, devir notunun başlığının altına `Ek dosyalar: detay notu <yol> · tam döküm <yol>` satırını ekler.
- Tam döküm şunları içerir:
  - Git durumu: dal, HEAD, `git status --porcelain` (en çok 100 satır) ve `git log --oneline -15`. Proje git deposu değilse bu bölüm yoktur.
  - Memory klasörü: `MEMORY.md` tam metin. Oturumun ilk kaydından sonra değişen memory dosyaları tam metin. Diğer memory dosyaları yalnız ad olarak.
  - Konuşma: kullanıcı mesajları ve asistan metinleri aynen yazılır. Araç girdileri, araç sonuçları, düşünce blokları, sistem ve agent bildirimleri, compact özetleri ve hook mesajları 4000 karakterde kesilir (`--max-field` varsayılanı). Subagent kayıtları (`isSidechain`) yazılmaz. Tam metin transcript dosyasındadır.
- Dökümdeki metinler maskelenmez. Hook secret'ları aramaz ve silmez. Kullanıcı mesajı, asistan metni, kesilen alanın ilk 4000 karakteri, memory dosyaları ve git çıktısı içinde bir secret varsa dökümde de görünür.
- Döküm `$CLAUDE_CONFIG_DIR/handoff-dumps/` altına yazılır (`CLAUDE_CONFIG_DIR` yoksa `~/.claude/handoff-dumps/`). Dosya adı `<devir notu adı>.transcript.md` olur. Dosya 600 izinlidir. Klasörü script yoksa 700 izinle oluşturur. Klasör zaten varsa izni değiştirilmez. `python3` yoksa döküm atlanır, hook çalışmaya devam eder.
- Limit prompt'u "devir notunu ve bağlı detay notunu tamamen oku" der. Uzun prompt dosyası (`.prompt.txt`) detay notunun metnini de taşır.
- `/clear` sonrası yükleyici yeni oturuma detay notunu tamamen okumasını söyler.
- Devir notu ve detay notunu model yazar. Modele secret yazmaması söylenir, ama bunu hiçbir hook denetlemez.

### Grup B (kullanım limiti)

1. Her araç grubundan sonra hook son limit okumasının yaşına bakar. Okuma eskiyse hesabın tek bir oturumundan `get_usage` çağrısı ister. Sonucu hook kaydeder.
   - `usage-feed` modu varsa okuma iki kaynaktan gelir: `get_usage` kaydı (`usage.json`) ve modun dosyası `~/.claude/usage-feed/feed-<organizasyon>_<hesap>.json`. Hook yeni olanı alır.
   - Mod dosyası yalnız şu koşullarla kullanılır: dosya bu kullanıcıya ait, `source` alanı `mod`, `ts` en çok 60 sn ileride, beş sayı alanı geçerli.
   - Mod bir pencereyi `get_usage`'dan 1 puana kadar düşük okur (ölçüldü). Hook mod değerlerine 1 ekler, tavan 100. Durak en çok 1 puan erken gelir, geç gelmez.
   - Mod dosyayı her tur sonunda, her tam puan değişiminde ve uzun araç döngüsünde en çok 60 sn'de bir yazar. Bu yüzden okuma taze kalır ve `get_usage` istenmez. Mod durursa dosya eskir, hook eski yola döner.
   - İstekten sonra Claude `get_usage` çağırdıysa hook diğer araçları reddetmez. Çağrı hata verse veya zaman aşımına düşse de reddetmez.
   - Çağrı okuma getirmezse hook araç grubunun sonunda isteği kapatır. Bu oturumda 10 dakika yeni okuma istenmez. İstek metni Claude'a başarısız çağrıyı tekrarlamamasını söyler.
2. Okuma aralığı: en yüksek yüzde %75 altındaysa 10 dakika, üstündeyse 2 dakika.
3. **İki otomatik durak:** 5 saatlik veya haftalık (tüm modeller) yüzde %90'ı geçince (≥91) birinci durak, %95'i geçince (≥96) ikinci durak gelir. O an konuşması olan her oturum her durakta bir kez durur. Durakta izin verilen tek iş devir notunu yazmaktır.
4. Durak anından sonra açılan yeni oturum durmaz, yalnız uyarı alır. Durak anında boşta olan oturum, ilk mesajında bir kez durur.
5. Devir notu: `<proje>/.claude/<oturum-adı>-handoff-<session_id>.md`. Grup A ile aynı dosya ve aynı kurallar: en çok 6000 karakter, 1. satır oturum adıyla başlar (`# <oturum adı> — limit devir notu`), READ FIRST en üstte. Notun ikinci satırını hook doldurur: `Son güncelleme: … TR` (Türkiye saati).
   - **Worktree oturumu:** Desktop worktree oturumu `<proje>/.claude/worktrees/<ad>` altında çalışır. App bu oturumdan `<proje>/.claude/` altına Write ve Edit'i reddeder. Durak da Bash'i engeller. Bu yüzden hook, notu worktree'nin kendi `.claude/` klasörüne taslak olarak yazdırır: `<worktree>/.claude/<not adı>`. PostToolUse taslağı asıl yola kopyalar ve taslağı siler.
6. Not kaydedilince Claude uyarı satırını ve kopyalanabilir prompt'u gösterir, cevabı bitirir.
   - Cevaptaki prompt kısadır: `Önceki oturumun işine devam ediyorum. <devir notu> devir notunu ve bağlı detay notunu tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle.` Bu metin `/oturum` komutunun verdiği prompt ile aynıdır. Başka hesapta da aynı hesapta da kullanılabilir. Uyarı satırının altında iki kod bloğu vardır: önce "Claude oturum ismi:" etiketiyle oturum adı, sonra "Prompt:" etiketiyle prompt. Her blok tek tıkla ayrı kopyalanır. Onaya kadar yalnız okur, iki kez yapıştırmak zarar vermez.
   - Uzun sürüm (devir notunun tamamı, oturum adı, proje, ek okuma listesi) `~/.claude/limit-handoffs/<not adı>.prompt.txt` dosyasındadır. Diğer hesap başka bir diskte çalışıyorsa bunu kullan.
   - Dizin dosyası `~/.claude/limit-handoffs/INDEX.md`, her oturumun devir notunu ve prompt dosyasını listeler.
7. **Durak sonrası:** tekrar yazarsan oturum normal çalışır. %90 üstünde her cevap devir notunu günceller ve şu uyarıyla biter: `⚠️ Kullanım limiti eşiği aşıldı …` ve yeni oturum prompt'u. Uyarı durak eşiklerini de yazar. Eşikler varsayılandan (%91, %96) farklıysa bunu ayrıca belirtir.
8. Mesaja `#limit-devam` yazarsan bekleyen durak atlanır. Uyarılar sürer.
9. Pencere sıfırlanınca duraklar ve uyarılar kendiliğinden kapanır. Sonraki pencerede duraklar yeniden geçerlidir.

Workspace'ler `CLAUDE_CODE_ORGANIZATION_UUID` + `CLAUDE_CODE_ACCOUNT_UUID` ile ayrılır. Aynı kişi iki Team workspace'inde aynı hesap kimliğini taşır, bu yüzden organizasyon kimliği şarttır (ölçüldü). Bir workspace'in limiti diğer workspace'in oturumlarını durdurmaz. Kayıtlar: `~/.claude/hooks/state/usage/<organizasyon>_<hesap>/`.

İki kimlikten biri yoksa Grup B o oturumda kapalıdır: okuma kaydedilmez, durak ve uyarı olmaz. İlk mesajda bir kez `Kullanım limiti koruması bu oturumda kapalı` satırı gelir. Gerekçe: kimliksiz bir okuma başka bir workspace'in oturumlarını durdurabilir.

`~/.claude/limit-handoffs/INDEX.md` bu makinedeki bütün workspace ve hesapların devir notlarını listeler.

**Hangi oturumlarda çalışır:** kurulduğu makinedeki bütün Claude Desktop oturumlarında, kendiliğinden. CLI oturumlarında yalnız `usage-feed` modu yüklüyse. Hook'lar `~/.claude/settings.json` içindedir ve hangi hesapla giriş yapıldığına bakmaz. Her hesabın limiti ayrı izlenir. Başka bir makinede (örneğin Mac) `./install.sh` çalıştır.

### Grup B ayarları (`~/.claude/hooks/usage-limit.conf`)

| Anahtar | Varsayılan | Anlamı |
|---|---|---|
| `STOP1_PCT` | 91 | Birinci durak ve uyarıların başladığı yüzde (iki pencere için) |
| `STOP2_PCT` | 96 | İkinci durak yüzdesi |
| `POLL_LOW_MIN` | 10 | Okuma aralığı (dk), yüzde düşükken |
| `POLL_HIGH_MIN` | 2 | Okuma aralığı (dk), yüzde yüksekken |
| `POLL_HIGH_FROM_PCT` | 75 | Kısa aralığa geçiş yüzdesi |
| `ONLY_SESSIONS` | boş | Boş = tüm oturumlar. Test için oturum kimlikleri. |
| `OVERRIDE_WORD` | `#limit-devam` | Bekleyen durağı atlatan sözcük |
| `HANDOFF_COPY_TTL_DAYS` | 7 | Devir notu kopyalarının silme süresi (gün). `~/.claude/limit-handoffs` altındaki prompt dosyaları ve dizin kayıtları bu süreden sonra silinir. Projedeki devir notu silinmez. Kontrol günde bir kez, kullanıcı mesajında yapılır. |

Her anahtar aynı adlı ortam değişkeniyle de verilebilir. Ortam değişkeni dosyadaki değeri geçersiz kılar.

Yalnız ortam değişkeni: `USAGE_FEED_DIR` modun dosya dizinini değiştirir. Varsayılan `~/.claude/usage-feed`.

### Grup B sınırları

- Boştaki oturum araç çağırmaz, bu yüzden durak anında durmaz. O oturuma ilk yazdığında bir kez durur.
- Araçsız tek bir uzun cevap ortada kesilmez. Oturum cevap bitince durur.
- Gecikme en çok bir okuma aralığı artı bir araç çağrısıdır. Oturum %91 yerine %92-93'te durabilir.
- Her okuma yaklaşık 1-2K token harcar. Hesap başına saatte yaklaşık 6 okuma yapılır, %75 üstünde 30. `usage-feed` modu yüklü ve dosyası tazeyse okuma istenmez.
- %90 üstünde her cevap devir notunu günceller ve prompt'u yazar. Bu da limit harcar.
- `UserPromptSubmit` kullanıcı yazmadan da gelir: zamanlanmış görev, arka plan subagent sonucu, başka oturumdan mesaj. Payload'da bunu ayıran alan yok (resmi hooks dokümanı). Durak sonrası böyle bir tur gelirse hook durağı kaldırır, ama Claude'a şu kuralı verir: tur kullanıcının kendi mesajı değilse durdurulan işe devam etme, ne geldiğini tek satırda söyle ve cevabı bitir.
- Durak bayrakları pencere başınadır ve pencerenin sıfırlanma zamanını taşır. Haftalık limit yüksek kalırken yeni 5 saatlik pencere başlarsa duraklar yeniden kurulur.
- Desktop uygulaması oturuma yanıt vermezse `get_usage` çalışmaz. Görülen hata: `PreToolUse hook did not respond before its timeout (host client may be unreachable)`. Her çağrı 30 sn bekler ve düşer. Bu sürede okuma gelmez, bu yüzden durak gecikebilir. Mod dosyası tazeyse hook onu okur. Diğer araçlar çalışır.
- Yalnız CLI'da (mod var, `get_usage` yok): oturum okuma aralığından (10 dk, %75 üstünde 2 dk) uzun boşta kalırsa ve başka oturum mod dosyasını tazelemediyse, dosya eskir. Mod tur içinde yalnız bir `measure` geldikten sonra yazar (`usage_feed_mod.md` §5 bulgu 8). Bu yüzden boşluktan sonraki ilk turda hook bir kez `get_usage` isteyebilir. Araç olmadığı için en çok 3 araç çağrısı reddedilir. Sonra istek 30 dk, aynı oturumda ikinci kez olursa 24 saat kapanır. Bu sürede de hook mod dosyasını okur ve duraklar çalışır. Kaynak: `usage-limit.sh` PreToolUse yolu.

### Doğrulama

```bash
grep -E 'session-end|forced|ambiguous|usage-limit' ~/.claude/hooks/context-pressure.log | tail -n 8
```

Devir notu denetimleri (Stop geri gönderimi, satırdaki not saati ve eski not uyarısı). Saat denetiminin log satırı `stop: handoff time in the line is '…', not 14:32` biçimindedir:

```bash
grep -E 'stop:|older than|freshness' ~/.claude/hooks/context-pressure.log | tail -n 8
```

---


## 3. Kaldırma prompt'u: Grup A (handoff)

Grup B'ye dokunmaz. Paylaşılan log ve test shim'lerini yalnız Grup B kurulu değilse siler.

````text
TARGET: Linux (Ubuntu) and macOS. Remove the group A hooks (context-pressure, session-end-mark, handoff-load) completely. Do not touch group B (usage-limit.sh, usage-limit.conf, run-ul-tests.sh, state/usage) or any other hook. Detect the OS with uname -s (Linux or Darwin; anything else: stop and tell me). Use only portable commands: no sed -i, no readlink -f, no grep -P, no GNU-only flags. Never write a home path from memory: take it from $HOME.
CONFIG ROOT: the user config directory is $CLAUDE_CONFIG_DIR when it is set (resolve it with (cd "$CLAUDE_CONFIG_DIR" && pwd -P)), else ~/.claude. Every path below that starts with ~/.claude or <home>/.claude means that directory.

- First print: the OS, $HOME resolved with (cd "$HOME" && pwd -P), and the absolute paths you will delete (expand $HOME yourself). Use these literal absolute paths in every rm. No unexpanded shell variable and no glob inside an rm command.
- IDEMPOTENT (hard rule): this prompt may run any number of times. A file, directory or settings entry that is already gone is reported as "not present" and skipped; never fail on it. A run on a machine where nothing is left changes nothing and says so.
- settings.json: build the result first. If it equals the current file (jq -S .), write nothing and make no backup. Otherwise back it up as settings.json.bak-<YYYYMMDD> (if that name exists, use settings.json.bak-<YYYYMMDDTHHMMSS>; never overwrite a backup), then write it.
- Finish with a table: every path and settings entry, and what happened to it (removed / not present / kept).
- In ~/.claude/settings.json delete only our entries, each found by its exact command string ("~/.claude/hooks/<name>.sh", "<config dir>/hooks/<name>.sh" or "<home>/.claude/hooks/<name>.sh"), whatever its matcher is: context-pressure.sh under hooks.UserPromptSubmit, under hooks.PostToolBatch and under hooks.Stop, session-end-mark.sh under hooks.SessionEnd, handoff-load.sh under hooks.SessionStart. Never remove an entry only because its command ends with the same file name. If a group's hooks array becomes empty remove the group, if an event array becomes empty remove that key, and if hooks becomes empty remove it. Keep all other hooks and settings untouched, including usage-limit.sh entries. Write the result atomically: if settings.json is a symlink, stop and ask me; otherwise write a temp file in the same directory, chmod it to the current mode, check it with jq -e, check that settings.json still has the SHA-1 you noted when you read it, then mv -f the temp file onto settings.json.
- Delete: ~/.claude/hooks/context-pressure.sh, ~/.claude/hooks/session-end-mark.sh, ~/.claude/hooks/handoff-load.sh, any *.bak-* copies of these three scripts in ~/.claude/hooks/, any leftovers named <script>.new.<pid> or <script>.tmp.<pid>, and ~/.claude/hooks/tests/run-tests.sh.
- Shared files: ~/.claude/hooks/context-pressure.log is also written by usage-limit.sh, and ~/.claude/hooks/tests/shims/ is also used by run-ul-tests.sh. Delete them only if ~/.claude/hooks/usage-limit.sh does not exist. Remove ~/.claude/hooks/tests/ and ~/.claude/hooks/ only if they are empty afterwards.
- State, SAFE DELETE (group A parts only):
  - Delete with literal paths: <home>/.claude/hooks/state/pending.d, <home>/.claude/hooks/state/ended, and the throttle files directly under <home>/.claude/hooks/state whose names match ^[A-Za-z0-9_-]{1,128}$ or ^[A-Za-z0-9_-]{1,128}\.turn$ or ^[A-Za-z0-9_-]{1,128}\.hnote$ (per session id: the context step, the turn start of the Stop check and the last handoff time note; list them first). Never delete <home>/.claude/hooks/state/usage (group B). Remove <home>/.claude/hooks/state itself only if it is empty afterwards.
  - The legacy /tmp/claude-context-pressure: delete it with that literal path if it exists. On macOS /tmp is a symlink to /private/tmp: delete the directory, never the symlink or /private/tmp itself.
  - If CTX_PRESSURE_STATE_DIR is set anywhere, resolve it with (cd "$dir" && pwd -P). Delete it automatically ONLY if it equals <home>/.claude/hooks/state or /tmp/claude-context-pressure, and then only the group A parts above. Otherwise show me the resolved path and its contents (ls -la, file count, du -sh) and wait for my explicit confirmation. Refuse outright, even with confirmation, if it is /, /home, /Users, <home>, /tmp, /private/tmp, <home>/.claude, <home>/Library, or any directory that contains a .git or a .claude/settings*.json.
- If CLAUDE_CODE_AUTO_COMPACT_WINDOW, CTX_PRESSURE_THRESHOLD, CTX_PRESSURE_STATE_DIR, HANDOFF_PENDING_TTL_MIN or HANDOFF_ENDED_MAX_AGE_S is set in the env block of ~/.claude/settings.json or in a shell startup file, show me where (file:line) and remove it only after I confirm. Files to check on both OSes: ~/.bashrc, ~/.bash_profile, ~/.profile, ~/.zshrc, ~/.zprofile, ~/.zshenv. Linux also: /etc/environment and ~/.config/environment.d/*.conf. macOS also: launchctl getenv <NAME> for each variable (report only; unsetting it is my call).
- Do not delete any handoff file and do not delete ~/.claude/handoff-archive/ or ~/.claude/limit-handoffs/. List the handoff files with size and mtime (stat -c '%s %y' on Linux, stat -f '%z %Sm' on macOS: probe, do not branch on the OS name). Search roots: <home> with -maxdepth 8 for -path '*/.claude/*handoff*.md', pruning .claude/projects, handoff-archive, node_modules, .Trash and (macOS) <home>/Library. On macOS also search <home>/Library/CloudStorage/* and "<home>/Library/Mobile Documents" as separate roots with -maxdepth 6 and timeout 90 (when timeout or gtimeout exists; otherwise without it, and say so). Also list the archive contents.
- Verify: show the settings.json diff against the backup made in this run (if no backup was made, say "settings.json unchanged"), confirm it is still valid JSON (jq -e .), and confirm nothing references the group A scripts any more: grep -rn "context-pressure\|handoff-load\|session-end-mark" in ~/.claude/settings.json, ~/.claude/settings.local.json and the .claude/settings*.json files of the project folders I name. Ask me for that list. Do not scan the whole disk.
- Plugin hooks (for example i-have-adhd SessionStart, aws-core PreToolUse) and hooks of other tools are separate: do not touch them.
````

---

## 4. Kaldırma prompt'u: Grup B (kullanım limiti)

Grup A'ya dokunmaz. Paylaşılan log ve test shim'lerini yalnız Grup A kurulu değilse siler.

````text
TARGET: Linux (Ubuntu) and macOS. Remove the group B hook (usage-limit.sh) completely. Do not touch group A (context-pressure.sh, session-end-mark.sh, handoff-load.sh, run-tests.sh) or any other hook. Detect the OS with uname -s (Linux or Darwin; anything else: stop and tell me). Use only portable commands: no sed -i, no readlink -f, no grep -P, no GNU-only flags. Never write a home path from memory: take it from $HOME.
CONFIG ROOT: the user config directory is $CLAUDE_CONFIG_DIR when it is set (resolve it with (cd "$CLAUDE_CONFIG_DIR" && pwd -P)), else ~/.claude. Every path below that starts with ~/.claude or <home>/.claude means that directory.

- First print: the OS, $HOME resolved with (cd "$HOME" && pwd -P), and the absolute paths you will delete (expand $HOME yourself). Use these literal absolute paths in every rm. No unexpanded shell variable and no glob inside an rm command.
- Show me the content of ~/.claude/hooks/usage-limit.conf before you delete it.
- IDEMPOTENT (hard rule): this prompt may run any number of times. A file, directory or settings entry that is already gone is reported as "not present" and skipped; never fail on it. A run on a machine where nothing is left changes nothing and says so.
- settings.json: build the result first. If it equals the current file (jq -S .), write nothing and make no backup. Otherwise back it up as settings.json.bak-<YYYYMMDD> (if that name exists, use settings.json.bak-<YYYYMMDDTHHMMSS>; never overwrite a backup), then write it.
- Finish with a table: every path and settings entry, and what happened to it (removed / not present / kept).
- In ~/.claude/settings.json delete only the entries whose command is exactly "~/.claude/hooks/usage-limit.sh", "<config dir>/hooks/usage-limit.sh" or "<home>/.claude/hooks/usage-limit.sh", in every event where they appear (expected: UserPromptSubmit, PreToolUse, PostToolUse, PostToolBatch), whatever their matcher is. Never remove an entry only because its command ends with usage-limit.sh. If a group's hooks array becomes empty remove the group, if an event array becomes empty remove that key, and if hooks becomes empty remove it. Keep all other hooks and settings untouched, including the group A entries. Write the result atomically: if settings.json is a symlink, stop and ask me; otherwise write a temp file in the same directory, chmod it to the current mode, check it with jq -e, check that settings.json still has the SHA-1 you noted when you read it, then mv -f the temp file onto settings.json.
- Delete: ~/.claude/hooks/usage-limit.sh, ~/.claude/hooks/usage-limit.conf, any *.bak-* copies of these two in ~/.claude/hooks/, any usage-limit.conf.livecheck-* copies (show their content first), leftovers named usage-limit.*.new.<pid> or usage-limit.*.tmp.<pid>, and ~/.claude/hooks/tests/run-ul-tests.sh.
- State, SAFE DELETE: delete <home>/.claude/hooks/state/usage with that literal path. If USAGE_LIMIT_STATE_DIR is set anywhere, resolve it with (cd "$dir" && pwd -P), show me the path and its contents (ls -la, file count, du -sh) and wait for my explicit confirmation. Refuse outright, even with confirmation, if it is /, /home, /Users, <home>, /tmp, /private/tmp, <home>/.claude, <home>/.claude/hooks, <home>/.claude/hooks/state, <home>/Library, or any directory that contains a .git or a .claude/settings*.json. Remove <home>/.claude/hooks/state only if it is empty afterwards.
- Shared files: ~/.claude/hooks/context-pressure.log is also written by group A, and ~/.claude/hooks/tests/shims/ is also used by run-tests.sh. Delete them only if ~/.claude/hooks/context-pressure.sh does not exist. Remove ~/.claude/hooks/tests/ and ~/.claude/hooks/ only if they are empty afterwards.
- Do not delete ~/.claude/usage-feed/: the usage-feed mod writes it, not this group. Report it as kept.
- Do not delete ~/.claude/limit-handoffs/ or any handoff file. List the handoff files (-path '*/.claude/*-handoff-*.md'; group A and group B write the same name <session name>-handoff-<session id>.md, earlier versions wrote <project name>-handoff-<session id>.md, and the older group B name <title>-handoff-<timestamp>Z.md matches too) under <home> with -maxdepth 8, pruning .claude/projects, handoff-archive, node_modules, .Trash and on macOS <home>/Library) with size and mtime (stat -c '%s %y' on Linux, stat -f '%z %Sm' on macOS: probe, do not branch on the OS name), and list ~/.claude/limit-handoffs/.
- If STOP1_PCT, STOP2_PCT, LIMIT_5H_PCT, LIMIT_WEEKLY_PCT (older version), POLL_LOW_MIN, POLL_HIGH_MIN, POLL_HIGH_FROM_PCT, ONLY_SESSIONS, OVERRIDE_WORD, USAGE_LIMIT_CONF, USAGE_LIMIT_STATE_DIR, USAGE_LIMIT_INDEX_DIR or USAGE_FEED_DIR is set in the env block of ~/.claude/settings.json or in a shell startup file, show me where (file:line) and remove it only after I confirm. Files to check on both OSes: ~/.bashrc, ~/.bash_profile, ~/.profile, ~/.zshrc, ~/.zprofile, ~/.zshenv. Linux also: /etc/environment and ~/.config/environment.d/*.conf. macOS also: launchctl getenv <NAME> for each variable (report only).
- Verify: show the settings.json diff against the backup made in this run (if no backup was made, say "settings.json unchanged"), confirm it is still valid JSON (jq -e .), and confirm nothing references usage-limit any more: grep -rn "usage-limit" in ~/.claude/settings.json, ~/.claude/settings.local.json and the .claude/settings*.json files of the project folders I name. Ask me for that list. Do not scan the whole disk.
- Running sessions pick up the removal at their next tool batch. A session that is in an automatic stop at that moment simply continues normally.
- Plugin hooks and hooks of other tools are separate: do not touch them.
````
