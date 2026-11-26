# Subagent düzeni: kurulum, kaldırma ve güncel durum

Kaynak bu repo'dur. Dosyalar repo'daki `agents/` ve `rules/` klasörlerindedir. Kurulumu repo kökündeki `install.sh` yapar. Değişikliği repo'da yap. Sonra her makinede `git pull` ve `./install.sh` çalıştır.

Hedef: macOS ve Linux (Ubuntu). Aynı dosyalar iki sistemde değişmeden çalışır.

Nereye kurulur: Claude Code'un çalıştığı makineye. Desktop uygulaması SSH ile bir sunucuya bağlanıyorsa Claude Code sunucuda çalışır. `install.sh` o SSH oturumunda çalışmalı. Dosyalar sunucunun `~/.claude` dizinine yazılır. Desktop'ın çalıştığı bilgisayara (ör. Mac) kurulum gerekmez. O bilgisayarda SSH'siz, yerel bir oturum açarsan o bilgisayarın `~/.claude` dizini okunur. Bu durumda kurulumu orada ayrıca yap.

SSH ile açılan Desktop oturumu bu belgelerde Desktop oturumu sayılır. Sunucu terminalinde doğrudan `claude` komutuyla açılan oturum CLI oturumudur.

Amaç: Fable ve Opus limitlerinin gereksiz subagent çağrılarıyla tükenmesini azaltmak. Görev kalitesi ve iş akışı korunur.

Kurulum sırası:
1. Hook'lar (Grup A ve Grup B) ve `usage-feed` modu: bu repo'da. Kurulum için repo klasöründe `./install.sh` çalıştır. Belgeleri repo'da `docs/` altında.
2. `subagent_setup.md` (bu belge). Hook'lardan ve moddan bağımsızdır.

## İçindekiler

1. Ne kurulur
2. Kaldırma prompt'u
3. Gerçek tasarruf ölçümü
4. Sınırlar
5. Kaynaklar

---

## 1. Ne kurulur

Kullanıcı düzeyinde, bu makinedeki bütün projeler için.

| Agent | Model | effort | maxTurns | Araçlar | Ne zaman |
|---|---|---|---|---|---|
| `reader` | haiku | low | 10 | Read, Grep, Glob, ToolSearch ve `local/reader-tools.txt` içindeki araçlar | Salt-okunur log, metrik, not, konfigürasyon |
| `coder` | sonnet | medium | 20 | Read, Grep, Glob, Edit, Write. Bash yok | Yerel kod yazma ve düzeltme. Testleri ana oturum koşar |
| `reviewer` | opus | high | 8 | Read, Grep, Glob | Yalnız açık istek veya kritik migration, failover, cutover |
| `opus-worker` | opus | high | 20 | Read, Grep, Glob, Edit, Write. Bash yok | Yalnız kullanıcı "Opus kullan" derse |
| `fable-worker` | fable | high | 20 | Read, Grep, Glob, Edit, Write. Bash yok | Yalnız kullanıcı "Fable kullan" derse |

- Repo'daki `reader` dosyası yalnız temel araçları listeler. `local/reader-tools.txt` her satırda bir araç adı tutar. Kurulum bu araçları `tools:` satırının sonuna ekler. Dosya yoksa `reader` yalnız temel araçlarla kurulur. Örnek: `local.example/reader-tools.txt`.
- Kurulum ek araçların adına bakar. Veri değiştiren sözcük taşıyan ad eklenmez. Okuma sözcüğü taşımayan ad yalnız ` read-only` işaretiyle eklenir. Ayrıntı: `local.example/README.md`.
- Her agent dosyası `DURUM: tamamlandı | kısmi | engellendi` satırıyla biter.
- Geniş kod keşfi built-in `Explore` ile yapılır. `Explore.md` ve `Plan.md` yazılmaz.
- `Explore` varsayılan olarak ana oturumun modelini kullanır. Ana model Fable ise bağlantı biçimine göre Opus'ta çalışabilir. Örnek: abonelik, Console veya `ANTHROPIC_BASE_URL` ile gateway kullanılırsa Opus. Bedrock ve benzeri sağlayıcılarda Fable'da kalır. Kaynak: [Claude Code · yerleşik subagent'lar](https://code.claude.com/docs/en/sub-agents#built-in-subagents).- Keşif için belirli bir model gerekiyorsa iki yol var: `Explore` adlı bir custom agent tanımla veya `CLAUDE_CODE_SUBAGENT_MODEL` ile `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` ayarla. Bu repo ikisini de yapmaz. Force açıkken agent dosyalarındaki `model` alanı yok sayılır.

`~/.claude/settings.json`:

- `permissions.deny`: `Agent(model:*opus*)` ve `Agent(model:*fable*)`. Yalnız çağrıda açıkça verilen `model` parametresi eşleşir. Agent dosyasındaki model eşleşmez. Bu yüzden `reviewer`, `opus-worker` ve `fable-worker` parametresiz çağrıyla çalışır.
- `env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = "2"`. Fazla başlatma kuyruğa alınmaz, reddedilebilir.
- Eklenmez: `Agent(model:*)`, `Agent(general-purpose)`, `Agent(claude)`.

`~/.claude/CLAUDE.md` içinde işaretli bölüm (`<!-- subagent-duzeni:baslangic -->` ile `<!-- subagent-duzeni:bitis -->` arası): hangi işe hangi agent, `model` ve `effort` parametresi verilmez, en çok 2 eşzamanlı subagent. Dosyanın geri kalanına dokunulmaz.

Effort önceliği (resmi sub-agents dokümanı): `CLAUDE_CODE_EFFORT_LEVEL` > çağrıdaki `effort` > agent dosyasındaki `effort` > oturum.

Ön koşullar: `jq`, ayrıca `sha1sum` veya `shasum`. `claude` CLI isteğe bağlıdır. Varsa son doğrulamayı yeni bir oturumla yapar.

---

## 2. Kaldırma prompt'u

Not (repo düzeni): Bu düzeni repo kökündeki `install.sh` her makineye kurar. Kurallar `CLAUDE.md` içindeki işaretli bölümden değil, `rules/subagent-routing.md` dosyasına giden bir import satırından gelir. Aşağıdaki prompt bu satırı silmez. Prompt'u çalıştırırsan kurallar yüklenmeye devam eder ve artık olmayan agent'lara yönlendirir. Sonraki `./install.sh` de her şeyi yeniden kurar. Tek bir makinede kapatma yolu şu an yok. Düzeni kaldırmak için değişikliği repo'da yap: `agents/` ve `rules/subagent-routing.md` dosyalarını ve `install.sh` içindeki 8. adımı kaldır. Sonra her makinede `git pull` ve `./install.sh` çalıştır.

5 agent dosyasını, iki deny kuralını, env anahtarını ve `CLAUDE.md` bölümünü siler. Başka hiçbir şeye dokunmaz. Her silinen şeyin yedeği alınır.

````text
TARGET: macOS or Linux (Ubuntu). Remove the subagent setup: five agent files, two deny strings, one env key and one CLAUDE.md section. Touch nothing else. Detect the OS with uname -s (Darwin or Linux; anything else: stop and tell me). Use only portable commands: no sed -i, no readlink -f, no grep -P, no GNU-only flags. Never write a home path from memory: take it from $HOME.
CONFIG ROOT: the user config directory is $CLAUDE_CONFIG_DIR when it is set (resolve it with (cd "$CLAUDE_CONFIG_DIR" && pwd -P)), else $HOME/.claude. Every path below that starts with ~/.claude means that directory.

- First print: the OS, the config root, and the absolute paths you will delete. Use these literal absolute paths in every rm. No unexpanded shell variable and no glob inside an rm command.
- IDEMPOTENT (hard rule): this prompt may run any number of times. Anything already gone is reported as "not present" and skipped; never fail on it. A run on a machine where nothing is left changes nothing and says so.
- Backups: before you change or delete anything, copy it to ~/.claude/backup-subagent-<YYYYMMDDTHHMMSS>/ under the same relative path. Never overwrite a backup.
- Agent files: ~/.claude/agents/reader.md, coder.md, reviewer.md, opus-worker.md and fable-worker.md. For each one that exists: show its size and its name line, back it up, then delete it. Keep every other file in ~/.claude/agents/, and keep the directory.
- settings.json: if it is a symlink, stop and ask me. Build the result with exactly this jq program (it removes only our two deny strings and the env key when its value is "2", and then empty containers):
  (if .permissions.deny then .permissions.deny -= ["Agent(model:*opus*)", "Agent(model:*fable*)"] else . end)
  | (if .permissions.deny == [] then del(.permissions.deny) else . end)
  | (if .permissions == {} then del(.permissions) else . end)
  | (if .env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS == "2" then del(.env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS) else . end)
  | (if .env == {} then del(.env) else . end)
  If env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS has another value, the program keeps it: show it and ask me whether to remove it too. If the result equals the current file (jq -S .), write nothing. Otherwise write it atomically: note the SHA-1 of settings.json, write a temp file in the same directory, chmod it to the current mode, check it with jq -e, check that settings.json still has the SHA-1 you noted, then mv -f the temp file onto settings.json. Show the diff.
- CLAUDE.md: if it is a symlink, stop and ask me. If the marker lines <!-- subagent-duzeni:baslangic --> and <!-- subagent-duzeni:bitis --> are missing: report "not present". If they are unbalanced, out of order, or appear more than once: stop and ask me. Otherwise remove the lines from the start marker to the end marker, both included, and one empty line directly before the start marker if there is one. Write through a temp file in the same directory, keep the file mode, then mv -f. If the file is then empty or holds only whitespace, ask me before you delete it.
- Keep every ~/.claude/backup-subagent-* directory and every backup of an earlier setup.
- Verify: none of the five agent files exists; neither deny string appears in ~/.claude/settings.json; settings.json is valid JSON (jq -e .); CLAUDE.md has no marker line.
- Open sessions keep the agents they loaded at start until a restart.
- Finish with a table: every path, settings entry and the CLAUDE.md section, and what happened to it (removed / not present / kept).
````

---

## 3. Gerçek tasarruf ölçümü

Gerçek limit tasarrufu ölçülmedi. Baz çizgisi olarak kurulumdan önceki 7 gün alınır.

Yöntem:

1. Yedi günlük pencerenin başlangıç, bitiş ve zaman dilimini yaz.
2. Agent tipini `subagents/*.meta.json` içindeki `agentType` alanından al. `meta.model` çağrıdaki parametredir.
3. Gerçek modeli `message.model` alanından al. Tekrarlı ve streaming kayıtları ayıkla. Eksik `usage` kaydını sıfır sayma.
4. Önce ve sonra değerlerini tek tabloda ver: tamamlanan görev, başarı oranı, görev başına token (input, output, cache ayrı), subagent'ta Opus ve Fable payı, reddedilen çağrılar, retry ve iç içe başlatma.
5. Eksik veriyi `ölçülemedi` diye yaz. "Kurulum doğrulaması" ve "gerçek tasarruf" sonuçlarını ayrı ver.

API dolar maliyeti abonelik limit tüketimiyle aynı değildir. Tasarruf yüzdesi uydurma. Ölçümü kendiliğinden zamanlama.

## 4. Sınırlar

- Gerçek subagent çağrısında `DURUM` satırı ve etkin effort test edilmedi.
- `opus-worker` ve `fable-worker` gerçek çağrıyla test edilmedi.
- Reddedilen bir çağrı ana oturumda yine token harcar.
- Prompt ve deny kuralları production yazma güvenliği sağlamaz. Bu ayrı bir iştir.
- `coder` için Bash ertelendi. Neden: workspace'te production erişimi olan bir cloud profili tanımlı olabilir.

## 5. Kaynaklar

- Repo'daki `agents/*.md` ve `rules/subagent-routing.md`. Kurulu kopyalar `~/.claude/agents/` altındadır.
- Resmi dokümanlar: https://code.claude.com/docs/en/sub-agents, https://code.claude.com/docs/en/permissions, https://code.claude.com/docs/en/settings
