# Upstream kaynakları

Bu repo'daki İngilizce skill'ler, aşağıdaki repo'lardan değiştirilmeden kopyalandı. Türkçe sürümler bu kopyalardan uyarlandı.

| Skill | Kaynak repo | Commit | Lisans | Repo'daki klasör |
|---|---|---|---|---|
| i-have-adhd | https://github.com/ayghri/i-have-adhd | `1ecea1993b7fce257ffbd686c070948b5e07eda6` | MIT, Ayoub Ghriss | `skills/i-have-adhd` |
| humanizer | https://github.com/blader/humanizer | `a32f24407364c74c812b43c15926d638bee1e072` | MIT, Siqi Chen | `skills/humanizer` |
| asd-ste100 | https://github.com/danyuchn/asd-ste100-skill | `65c8ab6ef5fcb3619c8e6daca43e68627f3d7b4a` | MIT, Dustin Yuchen Teng | `skills/asd-ste100` |

## Türkçe sürümler

| Türkçe skill | Kaynağı | Not |
|---|---|---|
| `adhd-tr` | i-have-adhd | Kurallar korundu. Örnekler Türkçeye çevrildi. Öncelik bölümü eklendi. |
| `humanizer-tr` | humanizer | Örüntüler Türkçe karşılıklarıyla değiştirildi. Türkçe örüntü listeleri gözleme dayanır, ölçülmedi. |
| `sade-teknik-turkce` | asd-ste100 (ilke olarak) | Bu repo'dan önce ayrıca yazılmıştı. `~/.agents/skills` klasöründen taşındı. |

`sade-teknik-turkce` bu repo'nun özgün içeriğidir. asd-ste100'ün fikrinden yola çıkar, ondan metin kopyalamaz. Kök dizindeki MIT lisansı bu skill'i de kapsar.

## Kopyalanan dosyalar

- i-have-adhd: `skills/i-have-adhd/SKILL.md`, `LICENSE`. Plugin, hook ve eval dosyaları kopyalanmadı.
- humanizer: `SKILL.md`, `LICENSE`.
- asd-ste100: `SKILL.md`, `LICENSE`, `references/`, `examples/`, `scripts/`.

## Upstream güncellemesi

1. Kaynak repo'yu yeni commit'te clone et.
2. Yukarıdaki dosyaları ilgili klasöre kopyala.
3. Bu dosyadaki commit değerini güncelle.
4. Değişiklikleri ilgili Türkçe sürüme elle aktar.

Lisans metinleri her skill klasöründe `LICENSE` dosyası olarak durur. Türkçe sürümler de kaynaklarının `LICENSE` dosyasını taşır.

Kök dizindeki `LICENSE` (MIT) bu repo'nun kendi içeriği içindir. Yukarıdaki upstream skill'ler ve onlardan uyarlanan `adhd-tr` ile `humanizer-tr`, kaynaklarının MIT lisansıyla gelir. Asıl yazarlar her klasördeki `LICENSE` dosyasında ve bu dosyanın tablosunda yazar.
