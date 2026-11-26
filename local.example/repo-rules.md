Bu repo için kişisel çalışma kuralların. Repo'nun `CLAUDE.md` dosyası bu dosyayı `local/repo-rules.md` yolundan okur. Dosya git'e girmez. İstemiyorsan oluşturma.

Örnek: birden fazla makinede aynı repo'yu kullanıyorsan.

## Senkronizasyon

- Repo'daki her değişikliği hemen commit et. Sonra push et. Kullanıcıya sorma.
- Push'tan sonra `git status -sb` çalıştır. Çıktı `## main...origin/main` olmalı.
- Diğer makinelerdeki clone'ları da güncelle. Komut: `ssh <kullanıcı>@<host> 'cd <repo yolu> && git pull -q'`.
- Makine listesi `local/machines.md` dosyasındadır. Dosya yoksa bu adımı atla ve kullanıcıya söyle.
- Değişiklik hook'lara veya modlara dokunuyorsa her makinede `./install.sh --check` çalıştır.
