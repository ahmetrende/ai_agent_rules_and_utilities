# local.example

Bu klasör, kişiye ve makineye özel dosyaların örneğidir. Gerçek dosyalar repo'ya girmez.

| Örnek dosya | Gerçek dosyanın yeri | Ne içerir |
|---|---|---|
| `ben.md` | `local/ben.md` | Meslek ve iş bilgisi. AGENTS.md bu dosyayı yükler. |
| `reader-tools.txt` | `local/reader-tools.txt` | `reader` agent'ının ek araçları. Her satırda bir araç adı. Örnek: bir MCP server'ın salt-okunur araçları. |
| `machines.md` | `local/machines.md` | Repo'nun clone'u olan diğer makineler. Repo'daki CLAUDE.md bu dosyayı yükler. |
| `accounts.md` | `local/accounts.md` | Claude hesaplarının adları. `/oturum` organizasyon kimliğinin yerine bu adı yazar. |
| `secret-guard.local.json` | `~/.claude/hooks/secret-guard.local.json` | Makineye özel gizli yollar. secret-guard hook'u bu dosyayı okur. |

`local/` klasörü `.gitignore` içindedir.

`./install.sh` terminalde çalışırsa eksik `ben.md` ve `reader-tools.txt` için soru sorar. Her soru isteğe bağlıdır. Enter'a basarsan soru atlanır.

- Bütün cevaplar boşsa dosya yazılmaz.
- `install.sh` her dosya için yalnız bir kez sorar. Boş bırakılan dosyalar `local/.install-asked` dosyasına yazılır.
- Yeniden sorulması için dosya adını `local/.install-asked` içinden sil.
- Terminal yoksa `install.sh` soru sormaz. Eksik dosyaları listeler ve kuruluma devam eder.

Dosyaları elle de oluşturabilirsin:

1. `mkdir -p local` çalıştır.
2. `cp local.example/ben.md local/ben.md` çalıştır.
3. `local/ben.md` içindeki `<...>` alanlarını doldur.

Bu bilgileri agent'ına da verebilirsin. Agent dosyaları senin için yazar.

Bir dosya yoksa ilgili kural o bilgi olmadan çalışır. `reader-tools.txt` yoksa `reader` yalnız temel araçlarla kurulur: Read, Grep, Glob ve ToolSearch.

`reader-tools.txt` dosyasını değiştirdikten sonra `./install.sh` çalıştır.

`reader` salt okunur kalmalıdır. Kurulum her ek aracın adına bakar:

- Adında veri değiştiren bir sözcük varsa araç eklenmez. Örnek: create, delete, run, update.
- Adında okuma sözcüğü varsa araç eklenir. Örnek: get, list, query, search.
- Diğer adlar yalnız satırın sonunda ` read-only` yazıyorsa eklenir. Örnek: `mcp__myserver__vm_top read-only`.
- Kurulum eklenen her aracı ayrı satırda gösterir. Atlanan araç için uyarı yazar.
- Ad yalnız bir işarettir. Aracın gerçekten salt okunur olması MCP server'ın iznine bağlıdır.
