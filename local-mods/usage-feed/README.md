# usage-feed

Claude Code motorunun `session.measure` olayıyla ittiği plan kullanımını bir dosyaya yazar.
Amaç: `usage-limit.sh` hook'unun modele `get_usage` çağrısı yaptırmasını gereksiz kılmak.

Yazdığı dosyalar (`<config>` = `CLAUDE_CONFIG_DIR` veya `~/.claude`):

- `<config>/usage-feed/feed-<org>_<hesap>.json`: son okuma. Biçim `usage-limit.sh` içindeki `usage.json` ile aynı (`ts`, `five.pct`, `five.reset`, `week.pct`, `week.reset`), artı `source: "mod"`.
- `<config>/usage-feed/history-<org>_<hesap>.jsonl`: son 200 okuma.
- `$.store` anahtarları `last` ve `history`.
- `<config>/usage-feed/context-<oturum kimliği>.json`: oturumun context penceresi (`ts`, `by`, `window`, `tokens`, `percent`). `hooks/context-pressure.sh` okur. Yalnız `window` pozitif sayıysa yazılır.

Aynı hesabın iki oturumu aynı `feed` dosyasına yazar. Mod yazmadan önce dosyayı okur ve pencere türü başına birleştirir: aynı pencerede yüzde düşmez, daha geç `resetsAt` kazanır, yalnız eski okumada olan tür korunur. `ts` yazma anıdır (heartbeat). `mts` değerlerin ölçüldüğü andır. `history` dosyası diskten okunup eklenir: tüm oturumların okumasını tutar.

Yazma anları: ilk okuma, ana turun sonu, bir pencerenin tam puan değişmesi, uzun araç döngüsünde en çok 60 sn'de bir (araç çağrısından sonra). Bu son yazma yalnız aynı turda bir `session.measure` geldikten sonra yapılır. Yeniden yükleme bir şey yazmaz.
Durum satırı: `plan: 5-hour limit 6% (02:47), Weekly 45%`. Adlar Desktop'taki kullanım kartıyla aynıdır. Parantezdeki süre (saat:dakika) 5 saatlik pencerenin geçen kısmıdır. Bir zamanlayıcı satırı dakikada bir yeniden çizer. Yüzdeler yalnız yeni okumayla değişir. Pencere bitince satır `five_hour reset` der.
Hook, ayar veya araç çağrısı değiştirmez. Kurulum, kaldırma ve tasarım notu: ai_agent_rules repo'sunda `docs/usage_feed_mod.md`.
