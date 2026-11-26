# Katkı

Katkıya açığız. Küçük düzeltmeler için doğrudan pull request aç. Büyük bir değişiklik için önce bir issue aç.

## Kurallar

1. Değişiklikten sonra `scripts/verify.sh` çalıştır. Bütün testler geçmeli.
2. Test sayısı değiştiyse `scripts/install_hooks.sh` içindeki `EXPECT_` satırlarını güncelle.
3. Repo'ya kişisel bilgi yazma: ad, e-posta, IP, makine adı, ev klasörü yolu, şirket veya proje adı, secret. Bunlar `local/` klasörüne gider. Örnekler: `local.example/`.
4. Dil: kurallar, Türkçe skill'ler ve dokümanlar Türkçedir. Code, yorum ve commit mesajı İngilizce olabilir.
5. İngilizce skill'ler (`skills/i-have-adhd`, `skills/humanizer`, `skills/asd-ste100`) upstream kopyasıdır. Onları burada değiştirme. Bkz. [UPSTREAM.md](UPSTREAM.md).

## English

Contributions are welcome. Run `scripts/verify.sh` before you open a pull request. Do not commit personal data: it belongs in `local/`. Rules and docs are in Turkish. Code and commit messages may be in English.
