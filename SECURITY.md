# Güvenlik

Bu repo bir güvenlik kontrolü içerir: `secret-guard` hook'u gizli bilgileri ekrana döken komutları engeller. Ayrıntı: [docs/secret_guard.md](docs/secret_guard.md).

## Açık bildirme

Bir güvenlik açığı bulursan herkese açık bir issue açma. GitHub'da bu repo'nun **Security** sekmesinden **Report a vulnerability** ile gizli bildir.

Bildirime şunları yaz:

1. Açığın kısa tanımı.
2. Tekrar üretme adımları. Örnek: engellenmesi gereken ama geçen bir komut.
3. İşletim sistemi, Claude Code sürümü ve bu repo'nun commit'i.

Bildirime gerçek bir secret koyma. Sahte bir değer kullan.

## Kapsam

- `hooks/secret-guard.py` ve `hooks/secret-guard-codex.py`: engellemesi gereken bir komutu geçirmek.
- Hook'ların ve script'lerin kullanıcı verisini beklenmeyen bir yere yazması veya göndermesi.
- Kurulum script'lerinin repo ve `~/.claude` dışında dosya değiştirmesi.

## English

To report a security issue, do not open a public issue. Use **Security → Report a vulnerability** on this repository. Include steps to reproduce, your OS, Claude Code version and the commit. Never include a real secret.
