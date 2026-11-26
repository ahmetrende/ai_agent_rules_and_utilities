# usage-feed modu: kurulum, kaldırma ve tasarım notu

Kaynak bu repo'dur. Dosyalar repo'daki `hooks/` ve `local-mods/` klasörlerindedir. Kurulumu repo kökündeki `install.sh` yapar. Değişikliği repo'da yap, test'ini aynı commit'e koy. Sonra her makinede `git pull` ve `./install.sh` çalıştır.

Hedef: macOS ve Linux (Ubuntu), Claude Code 2.1.308 veya daha yeni. Aynı dosyalar iki sistemde değişmeden çalışır.

Nereye kurulur: Claude Code'un çalıştığı makineye. Desktop uygulaması SSH ile bir sunucuya bağlanıyorsa Claude Code sunucuda çalışır. `install.sh` o SSH oturumunda çalışmalı. Dosyalar sunucunun `~/.claude` dizinine yazılır. Desktop'ın çalıştığı bilgisayara (ör. Mac) kurulum gerekmez. O bilgisayarda SSH'siz, yerel bir oturum açarsan o bilgisayarın `~/.claude` dizini okunur. Bu durumda kurulumu orada ayrıca yap.

SSH ile açılan Desktop oturumu bu belgelerde Desktop oturumu sayılır. Sunucu terminalinde doğrudan `claude` komutuyla açılan oturum CLI oturumudur.

Belgeler (üç belge):
1. `usage_feed_mod.md` (bu belge). İsteğe bağlı. Desktop uygulaması olmayan, yalnız CLI kullanılan makinede Grup B için gerekir. Mod ayrıca durum satırında plan kullanımını ve 5 saatlik pencerenin geçen süresini (saat:dakika) gösterir: `plan: five_hour 6% (02:47), seven_day 45%`.
2. `handoff_and_limit_hooks.md`: Grup A ve Grup B hook'ları.
3. `subagent_setup.md`: subagent düzeni.

Sıra değişirse veri bozulmaz. `get_usage` aracı ve mod yoksa Grup B okuma yapamaz.

Testler: `claude plugin validate local-mods/usage-feed` ve `claude plugin test local-mods/usage-feed` (22 test). `validate` yalnız katalog uyarıları verir (LICENSE, install satırı, ikon, `author`).

## İçindekiler

1. Ne kurulur
2. Kaldırma prompt'u
3. Nasıl çalışır
4. Ölçülen davranış
5. `usage-limit.sh` ile bağlantı
6. Kaynaklar

---

## 1. Ne kurulur

| Yol | Kim yazar | Görev |
|---|---|---|
| `~/.claude/local-mods/.claude-plugin/marketplace.json` | Kurulum (FILES) | Yerel klasör marketplace'i. Adı `local-mods`. |
| `~/.claude/local-mods/usage-feed/` | Kurulum (FILES) | Mod: `plugin.json`, `hooks/hooks.json`, `hooks/register.ts`, `hooks/register.test.ts`, `README.md`. |
| `~/.claude/settings.json` | `claude plugin` komutları | İki anahtar: `extraKnownMarketplaces."local-mods"` ve `enabledPlugins."usage-feed@local-mods"`. |
| `~/.claude/plugins/` | `claude plugin` komutları | `known_marketplaces.json`, `installed_plugins.json`, `cache/`. |
| `~/.claude/usage-feed/` | Mod, çalışırken | Okuma dosyaları. Kurulum bu dizine yazmaz. |

Ön koşullar:
- Claude Code CLI (`claude`) PATH'te olmalı. Kurulum `claude plugin` komutlarını kullanır. `claude` yoksa prompt durur ve kurulum rehberini gösterir: https://code.claude.com/docs/en/setup
- Claude Code 2.1.308 veya daha yeni. Daha eski sürümde prompt durur.
- `jq`, ayrıca `sha1sum` veya `shasum`.
- Oturumda `CLAUDE_CODE_ORGANIZATION_UUID` ve `CLAUDE_CODE_ACCOUNT_UUID` dolu olmalı. Biri yoksa mod dosya yazmaz.
- Organizasyon politikası modlara izin vermeli.
- Mod hiçbir yere yayınlanmaz. Kurulum yalnız bu makinedeki kullanıcı içindir.

---

Mod hakkında güncel gerçekler: iki yüklü kopya aynı geçmiş dosyasının üzerine yazar. Yeni veya değişen mod çalışan oturumda yalnız `/reload-plugins` veya yeniden başlatma sonrası yüklenir. Hesap kimlikleri oturumun ortamından gelir. Düz bir kabukta (örneğin SSH) bu iki değişken olmayabilir, o zaman mod dosya yazmaz.

---

## 2. Kaldırma prompt'u

Modu, marketplace kaydını ve dosyalarını siler. Hook'lara dokunmaz. Okuma dosyalarını (`~/.claude/usage-feed/`) yalnız onayınla siler.

````text
TARGET: macOS or Linux (Ubuntu). Remove the usage-feed mod completely. Do not touch other plugins, other marketplaces, or the hooks of handoff_and_limit_hooks.md. Detect the OS with uname -s (Darwin or Linux; anything else: stop and tell me). Use only portable commands: no sed -i, no readlink -f, no grep -P, no GNU-only flags. Never write a home path from memory: take it from $HOME.
CONFIG ROOT: the user config directory is $CLAUDE_CONFIG_DIR when it is set (resolve it with (cd "$CLAUDE_CONFIG_DIR" && pwd -P)), else $HOME/.claude. Every path below that starts with ~/.claude means that directory.

- First print: the OS, the config root, and the absolute paths you will delete. Use these literal absolute paths in every rm. No unexpanded shell variable and no glob inside an rm command.
- IDEMPOTENT (hard rule): this prompt may run any number of times. Anything already gone is reported as "not present" and skipped; never fail on it. A run on a machine where nothing is left changes nothing and says so.
- The claude CLI must be on PATH (command -v claude). If it is missing: stop and tell me. Never edit the files in ~/.claude/plugins/ by hand.
- Before the first command that changes state, copy ~/.claude/settings.json, ~/.claude/plugins/known_marketplaces.json and ~/.claude/plugins/installed_plugins.json (those that exist) to ~/.claude/backup-usage-feed-<YYYYMMDDTHHMMSS>/. Never overwrite a backup.
- If claude plugin list shows usage-feed@local-mods: claude plugin uninstall usage-feed@local-mods
- If claude plugin marketplace list shows local-mods with the path ~/.claude/local-mods, and claude plugin list shows no other plugin from local-mods: claude plugin marketplace remove local-mods. Otherwise keep it and tell me why.
- Delete these files: ~/.claude/local-mods/usage-feed/.claude-plugin/plugin.json, ~/.claude/local-mods/usage-feed/hooks/hooks.json, ~/.claude/local-mods/usage-feed/hooks/register.ts, ~/.claude/local-mods/usage-feed/hooks/register.test.ts, ~/.claude/local-mods/usage-feed/README.md, and the folder ~/.claude/local-mods/usage-feed/.claude-plugin/types/ if the engine generated it. Delete ~/.claude/local-mods/.claude-plugin/marketplace.json only if it lists no plugin besides usage-feed. Then remove each emptied directory, deepest first, only if it is empty. If a directory still holds other files, list them and keep them.
- Keep ~/.claude/usage-feed/ (readings and history written by the mod). Show its file count and size (du -sh), and delete it only after my explicit confirmation. Group B of handoff_and_limit_hooks.md falls back to get_usage by itself once the file stops being fresh.
- Verify: claude plugin list does not show usage-feed; ~/.claude/settings.json has no key "usage-feed@local-mods" under enabledPlugins and no key "local-mods" under extraKnownMarketplaces, and is valid JSON (jq -e .). If one of these keys is left, show it, and remove only that key after my confirmation: if settings.json is a symlink, stop and ask me; otherwise write a temp file in the same directory, chmod it to the current mode, check it with jq -e, check that settings.json still has the SHA-1 you noted when you read it, then mv -f the temp file onto settings.json.
- Sessions that are open keep the mod loaded until /reload-plugins or a restart.
- Finish with a table: every path, plugin, marketplace and settings key, and what happened to it (removed / not present / kept).
````

---

## 4. Nasıl çalışır

Dosyalar: `~/.claude/local-mods/usage-feed/`. Tam içerik §2'deki FILES bölümündedir.

Olaylar:

- `session.measure`: motor ölçümü iter. Mod `e.rateLimits` ve `e.context` değerlerini yazar. Taze bayrağını açar.
- `turn.start`: ana döngüde (subagent turunda değil) taze bayrağını kapatır.
- `tool.call`: araç çağrısından sonra çalışır. Taze bayrağı açıksa ve son yazmanın üzerinden 60 sn veya daha çok geçtiyse okumayı yeniden yazar (heartbeat). `$.session.usage()` ücretsizdir ve API çağrısı yapmaz.
- Yeniden yükleme (`session.start`) bir şey yazmaz (§5 bulgu 8).
- `session.start`: durum satırı için zamanlayıcıyı başlatır (`$.clock.every`, 60 sn). Yeniden yüklemede bu oturumun kendi son okumasını `$.store` içinden alıp satırı yeniden çizer. Başka oturumun okumasını göstermez.

Durum satırı (sürüm 0.2.1):

- Biçim: `plan: 5-hour limit 6% (02:47), Weekly 45%`. Pencere adları Desktop'taki kullanım kartıyla aynıdır: "5-hour limit", "Weekly"; tek modelin haftalık penceresi "Weekly · Opus" gibi. Parantezdeki süre 5 saatlik pencerenin geçen kısmıdır, saat:dakika olarak yazılır ve tam dakikaya aşağı yuvarlanır. 1 saatin altında saat `00` olur: `(00:40)`. Pencerenin 5 saat olduğu bilindiği için toplam yazılmaz.
- 0.2.0 sürümü süreyi `(2h47m/5h)` biçiminde yazıyordu. 0.2.1 bunu `(02:47)` yaptı.
- Hesap: pencere `resetsAt` anında biter, 5 saat önce başlamıştır. Geçen süre = 5 saat − (`resetsAt` − şimdi).
- Zamanlayıcı satırı dakikada bir yeniden çizer. Metin değişmediyse `$.ui.status` çağrılmaz. Zamanlayıcı dosya yazmaz.
- Yüzdeler yalnız yeni okumayla değişir (`session.measure` veya heartbeat). Süre ise her dakika güncellenir.
- `resetsAt` geçtiyse satır yeni okumaya kadar `5-hour limit reset` der. Eski yüzde gösterilmez.
- `resetsAt` yoksa veya okunamıyorsa yalnız yüzde yazılır.
- İlk okumadan önce satır boştur.
- Transcript'teki soluk satır değişmedi: yalnız yüzdeleri yazar (`usage-feed (measure): five_hour 5%, seven_day 22%`).
- Headless `-p` oturumunda durum satırı yoktur. Motor metni debug log'a yazar: `$.ui.status (usage-feed): plan: ...`.

Yazdığı yerler (`<config>` = `CLAUDE_CONFIG_DIR` veya `~/.claude`):

- `<config>/usage-feed/feed-<org>_<hesap>.json`: son okuma. Biçim `usage-limit.sh` içindeki `usage.json` ile aynıdır: `ts`, `five.pct`, `five.reset`, `week.pct`, `week.reset`. Ek alanlar: `source: "mod"`, `by` (oturum), `event`, `windows`, `context.percent`, `changed`, `surfaces`.
- `<config>/usage-feed/history-<org>_<hesap>.jsonl`: son 200 okuma.
- `$.store`: `last` ve `history`.
- Pencere bir puan değişince debug log'a bir satır: `usage-feed (measure): five_hour 5%, seven_day 22%`. Sohbete yazılmaz: paralel agent'lar varken değer gidip geldiği için satır çoğalıyordu. Güncel değer prompt kutusunun altındaki durum satırında görünür.

Hesap anahtarı hook ile aynıdır: `CLAUDE_CODE_ORGANIZATION_UUID` + `CLAUDE_CODE_ACCOUNT_UUID`, ikisi de `^[A-Za-z0-9-]{8,64}$` ile denetlenir. Biri yoksa veya biçimi bozuksa dosya yazılmaz. `$.store` yine yazılır.

Geçmiş dosyası (`history-*.jsonl`) her yazışta diskten okunur, yeni okuma eklenir, son 200 satır geri yazılır (B07 değişikliğinden beri). Bozuk satırlar atlanır. Eşzamanlı iki oturum aynı anda yazarsa bir satır kaybolabilir. Hook bu dosyayı okumaz, yalnız `feed-*.json` okur.

### B07: eski okuma yeni okumanın üzerine yazmaz

Sorun: uzun araç döngüsündeki oturum eski değerini (ör. five_hour %90) yeni `ts` ile, başka oturumun daha yeni %97 değerinin üzerine yazıyordu.

Çözüm: mod `feed` dosyasını yazmadan önce `$.fs.read` ile okur. Dosya yoksa, okunamıyorsa veya JSON geçersizse "dosya yok" sayılır. Birleştirme pencere türü (`kind`) başına yapılır:

- Aynı `resetsAt` ve eski okumada daha yüksek `percentUsed`: eski yüzde korunur.
- Eski okumada daha geç `resetsAt`: eski pencere korunur (gelen okuma eski pencereden).
- Gelen okumada daha geç `resetsAt`: gelen pencere kazanır.
- Yalnız eski okumada olan tür: korunur.
- `five` ve `week` birleşmiş pencerelerden türetilir.

Alanlar: `ts` yazma anı olarak kalır (heartbeat, `usage-limit.sh` tazelik için okur). Yeni `mts` değerlerin ölçüldüğü andır. `session.measure` için şimdi, heartbeat için bu modülün son `session.measure` zamanı. Birleştirmede eski okumadan bir değer geldiyse `mts = max(kendi mts, eski mts)`. Eski dosyada `mts` yoksa 0 sayılır.

Sınır: okuma ile yazma arasında atomiklik yoktur. İki oturum aynı anda yazarsa yarış kalır.

### B16: oturum başına context penceresi

Pencere boyutunu yalnız motor bilir. Her `record()` yazışında mod `(await $.session.usage()).context` değerinden `<config>/usage-feed/context-<oturum kimliği>.json` dosyasını yazar:

```json
{"ts": 1790000000, "by": "<oturum kimliği>", "window": 1000000, "tokens": 90000, "percent": 9}
```

- `tokens` ve `percent` yoksa `null` olur (ilk yanıttan önce).
- Dosya yalnız `window` pozitif sayıysa ve oturum kimliği `^[A-Za-z0-9_-]{1,128}$` ile eşleşiyorsa yazılır.
- Bu yazma başarısız olursa hata debug log'a gider, `feed` yazımı durmaz.
- Hesap kimliği (org, hesap) yoksa `feed` gibi bu dosya da yazılmaz.
- Okuyan: `hooks/context-pressure.sh` (bu değişiklikte yazılmadı, doğrulanmadı).

## 5. Canlı ölçüm (Ubuntu, CLI ve Desktop)

Kurulum: `claude -p --plugin-dir <mod>`. `usage-limit.sh` çocuk oturumda `ONLY_SESSIONS` ortam değişkeniyle devre dışı bırakıldı. CLI girişi bu Desktop oturumuyla aynı organizasyon ve e-postadır. Mod dosyası adı bu oturumun org ve hesap UUID'siyle birebir eşleşti.

| Zaman (UTC) | Kaynak | 5 saatlik | Haftalık (tüm modeller) |
|---|---|---|---|
| 09:44 | `get_usage` | 5 | 22 |
| 09:45:09 | mod (`measure`) | 4 | 22 |
| 09:46 | `get_usage` | 5 | 22 |
| 09:46:20 - 09:47:10 | mod, 4 okuma | 4 | 22 |
| 09:47:55 - 09:49:42 | mod, 5 okuma | 5 | 22 |
| 09:50:27 | `get_usage` | 6 | 22 |
| 09:53:07 | mod, Desktop (`start`) | 5 | 22 |
| 09:53:24 | mod, Desktop (`measure`) | 6 | 22 |
| 09:53:2x | `get_usage` | 6 | 23 |

Bulgular:

1. **Mod bir pencereyi 1 puana kadar düşük okuyabiliyor.** 5 saatlik: 4/5, 5/6, sonra 6/6. Haftalık: 22/22, sonra 22/23. Mod daima tam sayı aldı, ondalık gelmedi. Fark hiç 1 puanı geçmedi, mod hiç yüksek okumadı. Kesin kural belirtilmemiş. Muhtemel neden: kart yuvarlıyor, yanıt başlığı aşağı kesiyor.
2. **`session.measure` her API yanıtında ateşlenmiyor.** 4 yanıtlı 30 sn'lik turda 2 olay geldi: ilk okuma ve tur sonu. Belgedeki tanım: "after each main-thread turn, and when a rate-limit window moves a whole point". Uzun araç döngüsünde dosyanın `ts` alanı eskir, değerler ise güncel kalır.
3. **Heartbeat çalışıyor.** 82 sn'lik 3 araçlı döngüde 77. saniyede `tick` yazıldı (09:49:39).
4. **`resetsAt` modda tam saniye** (`10:40:00.000Z`). `get_usage` aynı pencere için `10:40:00.061Z`, `.595Z`, `.603Z` verdi. Hook'taki 1800 sn tolerans ikisini de kapsar.
5. **Hafta başına model penceresi modda yok.** `get_usage` "Weekly · Fable" verir, mod yalnız `five_hour` ve `seven_day` aldı. Hook bu pencereyi zaten kullanmıyor.
6. `surfaces` hem `claude -p` çalıştırmasında hem bu Desktop oturumunda boş liste döndü. Belge `-p` için bunu söyler: "Empty in a plain -p run". Desktop'u ayırt etmek için `surfaces` kullanılamaz, `by` (oturum kimliği) kullanılır.
7. **Desktop'ta `measure` tur ortasında da geldi.** 09:53:24 okuması bir araç çağrısından sonra, 5 saatlik pencere 5'ten 6'ya geçince geldi. Belgedeki "window moves a whole point" kuralıyla uyumlu.
8. **Boşta kalan oturumun heartbeat'i eski değer yazdı (düzeltildi).** Bu oturum 10:20'den 10:31'e kadar boştaydı. Yeni turun ilk araç çağrısında heartbeat %13 yazdı (10:31:37). Bundan 2 sn önce yeni Desktop oturumu %16 yazmıştı. 2 sn sonra `measure` %17 getirdi. Neden: `$.session.usage()` son yanıtın değerini verir, turun ilk araç çağrıları yeni yanıtın değeri gelmeden çalışır. Düzeltme: `turn.start` (ana döngü) taze bayrağını kapatır. Heartbeat yalnız aynı turda bir `measure` geldikten sonra yazar. Yeniden yükleme (`session.start`) artık bir şey yazmaz. Regresyon testi eklendi: 13/13.

## 6. `usage-limit.sh` ile bağlantı

Kod: `handoff_and_limit_hooks.md` FILES bloğu, `usage-limit.sh` içindeki `load_feed`. `load_usage` sonunda çağrılır. Testler: `run-ul-tests.sh` içinde `feed` bölümü, 28 kontrol.

Kurallar:

- Hook iki kaynağın yenisini alır: `get_usage` kaydı (`usage.json`) ve modun dosyası (`feed-<org>_<hesap>.json`).
- Mod dosyası yalnız şu koşullarla kullanılır: dosya bu kullanıcıya ait (`-O`), `source` alanı `mod`, `ts` en çok 60 sn ileride, beş sayı alanı geçerli.
- Hook mod değerlerine 1 ekler, tavan 100 (§5 bulgu 1). Durak en çok 1 puan erken gelir, geç gelmez.
- Hook mod dosyasını ilk kullandığında oturum başına bir log satırı yazar: `usage feed of the mod used by <oturum>`.
- Mod yüklü değilse veya dosya eskiyse hook `get_usage` yoluna döner.
- CLI'da mod yüklüyse koruma çalışır. Mod olmadan CLI'da `get_usage` aracı yoktur ve Grup B kapanır.

Açık noktalar:

- **+1 payının alternatifi (uygulanmadı):** mod okuması `STOP1_PCT - 2` üstündeyse tek bir `get_usage` doğrulaması iste. Bu, eşik yakınında birkaç okumayı geri getirir.
- **Dosya izinleri:** mod motorun umask'ıyla yazar: dizin 775, dosya 664. İçerik yüzdeler, oturum kimliği ve context yüzdesidir.

## 7. Kaynaklar

- Mods referansı: https://code.claude.com/docs/en/plugins/mods/reference (2026-10-26 okundu): `session.measure`, `$.session.usage()`, `$.store`.
- Motorun tip dosyası, Claude Code 2.1.308 (`claude-code.d.ts`, plugin-authoring skill'inin yazdığı kopya): `'session.measure'` açıklaması ("after each main-thread turn, and when a rate-limit window moves a whole point"), `SessionMeasureInput`, `SessionRateLimit` ("0 to 100 with at most one decimal"), `$.session.usage` ("The plain call costs nothing"), `$.fs.write`, `$.store`, `$.env.get`.
- `~/.claude/hooks/usage-limit.sh`: `load_usage`, `load_feed`.
- `handoff_and_limit_hooks.md` §2 "Grup B sınırları".
- Ölçüm ham verisi: `~/.claude/usage-feed/history-<org>_<hesap>.jsonl`.
- Claude Code kurulum rehberi (CLI): https://code.claude.com/docs/en/setup (2026-10-27'de açıldı).
