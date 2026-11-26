# ai_agent_rules_and_utilities: repo kuralları

Bu kurallar yalnız bu repo'da çalışırken geçerlidir.

## Değişiklik yaparken

- Değişiklikten sonra `scripts/verify.sh` çalıştır. Test sayısı değiştiyse `scripts/install_hooks.sh` içindeki `EXPECT_` satırlarını güncelle.
- Değişiklik hook'lara veya modlara dokunuyorsa `./install.sh --check` çalıştır. `./install.sh` için kullanıcıya sor.

## Kişiye özel bilgi

- Repo'ya kişisel bilgi, IP, makine adı, kullanıcı adı, ev klasörü yolu veya gizli yol yazma.
- Bu bilgiler `local/` klasörüne veya `~/.claude/hooks/secret-guard.local.json` dosyasına gider. Örnekler: `local.example/`.

## Kişisel çalışma kuralları

`local/repo-rules.md` varsa kullanıcının bu repo için kendi kuralları oradadır. Örnek: commit ve push sıklığı, diğer makinelerdeki clone'ları güncelleme. Örnek dosya: `local.example/repo-rules.md`.

@local/repo-rules.md
@local/machines.md
