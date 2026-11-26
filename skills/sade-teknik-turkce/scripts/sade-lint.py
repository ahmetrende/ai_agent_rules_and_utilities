#!/usr/bin/env python3
"""Sade Teknik Türkçe için deterministik linter.

Yalnızca mekanik olarak denetlenebilen yapısal kuralları kontrol eder.
Kipi ve kesinlik derecesini (olabilir, muhtemelen, -mIş olabilir) ASLA
işaretlemez: skill güveni içerik sayar, hedge'leri baskılayan bir linter
iddiayı değiştirir.

Kullanım:
    sade-lint.py DOSYA [DOSYA ...]
    echo "metin" | sade-lint.py [--json]
    sade-lint.py --baseline 5 DOSYA        # 5 sert ihlale kadar geçer
    sade-lint.py --disable uzun-cumle DOSYA
    sade-lint.py --selftest

Sert ihlaller baseline'ı (varsayılan 0) aşarsa exit 1. Öneri (advisory)
bulgular hiçbir zaman başarısızlık saymaz.
"""
import bisect
import json
import re
import sys

MAX_WORDS = 18  # açıklama sınırı; talimat sınırı 15 ama bağlamsız ayırt edilemez

# -Ip ile biten ama fiil olmayan yaygın sözcükler (komut zinciri heuristiği için)
IP_NOUNS = {"tip", "ip", "ekip", "sahip", "garip", "tertip", "takip", "talip",
            "nasip", "prensip", "çip", "klip", "grip", "katip", "kalıp", "sip",
            "hip", "trip", "zip", "dip", "kip", "ilkip", "grup", "kulüp", "şirup", "kup", "tup"}
IMPERATIVE_END = re.compile(r"\w{2,}(?:ın|in|un|ün|yın|yin|yun|yün)(?:ız|iz|uz|üz)?$", re.I)
ARAK_TOKEN = re.compile(r"\b\w{2,}(?:arak|erek)\b", re.I)
ARAK_EXCLUDE = {"gerek", "erek", "gerçek"}
IP_TOKEN = re.compile(r"\b\w{2,}(?:ıp|ip|up|üp)\b", re.I)

RULES = [
    ("noktali-virgul", "sert",
     re.compile(r";"),
     "Noktalı virgül iki cümledir. Nokta koy, yeni cümle başlat."),
    ("adlastirma", "sert",
     re.compile(r"\b\w+(?:ma|me)(?:sı|si|yı|yi|sını|sini|nın|nin)?\s+(?:işlemini\s+)?(?:yap|gerçekleştir|uygula|icra\s+et)\w*", re.I),
     "Adlaştırma. Fiili kullan: 'yazma yapmayın' değil 'yazmayın', 'kontrol yapın' değil 'kontrol edin'."),
    ("adlastirma", "sert",
     re.compile(r"\b(?:kontrol|analiz|test|kurulum|yedek|yedekleme|doğrulama|güncelleme|yükleme|silme|işlem|değişiklik)\s+(?:işlemini\s+)?(?:yap|gerçekleştir)\w*", re.I),
     "Adlaştırma. 'kontrol yap' değil 'kontrol et', 'güncelleme gerçekleştir' değil 'güncelle'."),
    ("pazarlama-sifati", "sert",
     re.compile(r"\b(?:kusursuz|sorunsuz|zahmetsiz|son\s+teknoloji|çığır\s+aç\w*|yenilikçi|devrim\s+niteliğinde|eşsiz|benzersiz|mükemmel|ultra\s+hızlı|ışık\s+hızında|güçlü\s+ve\s+güvenli|güçlü\s+ve\s+esnek)\b", re.I),
     "Pazarlama sıfatı. Sil, ya da iddiayı hak eden ölçümü yaz."),
    ("resmi-kalip", "oneri",
     re.compile(r"\b(?:gerekmektedir|bulunmaktadır|söz\s+konusu|olup\b|edilmektedir|yapılmaktadır|\w+(?:ması|mesi)\s+h[aâ]linde|tarafından\s+\w+(?:ılması|ilmesi|ulması|ülmesi)|\w+(?:makta|mekte)dır)\b", re.I),
     "Resmî kalıp. Düz biçim: 'gerekir' veya emir kipi, 'bu', '-se', etken çatı, geniş zaman."),
]

# Bir kavram, bir sözcük: aynı eylem için dönüşümlü kullanılan gruplar.
# Yalnızca gerçekten birbirinin yerine kullanılan üyeler; hata/sorun/arıza ayrı kavramlardır.
SYNONYM_GROUPS = [
    ("kontrol et", "doğrula", "teyit et", "denetle"),
    ("sil", "kaldır"),
    ("göster", "görüntüle"),
    ("gönder", "ilet", "yolla"),
    ("durdur", "sonlandır"),
    ("düzelt", "onar"),
    ("kullan", "faydalan", "yararlan"),
]
VERB_SUFFIX = r"(?:yın|yin|yun|yün|yınız|yiniz|yunuz|yünüz|yıp|yip|yup|yüp|yarak|yerek|yacak|yecek|in|ın|un|ün|iniz|ınız|unuz|ünüz|ir|ır|ur|ür|er|ar|me|ma|mek|mak|ip|ıp|up|üp|ecek|acak|di|dı|du|dü|ti|tı|tu|tü|en|an|iyor|ıyor|uyor|üyor|erek|arak|il|ıl|ul|ül|ebil|abil)\w*"
def verb_re(base):
    base = re.escape(base).replace(r"\ ", r"\s+")
    if base.endswith("et"):  # et -> edin, edilir (ünsüz yumuşaması)
        base = base[:-1] + "[td]"
    return re.compile(r"\b" + base + r"(?:" + VERB_SUFFIX + r")?\b", re.I)
SYNONYM_PATTERNS = [[(w, verb_re(w)) for w in g] for g in SYNONYM_GROUPS]

# İngilizce-Türkçe karışımı da rotasyondur.
EN_TR_PAIRS = [
    ("backend", r"arka\s+uç\w*"),
    ("frontend", r"ön\s*yüz\w*"),
    ("client", r"istemci\w*"),
    ("server", r"sunucu\w*"),
    ("database", r"veri\s*tabanı\w*"),
    ("request", r"istek\w*"),
    ("response", r"yanıt\w*"),
    ("timeout", r"zaman\s+aşımı\w*"),
    ("default", r"varsayılan\w*"),
    ("query", r"sorgu\w*"),
    ("deploy", r"dağıt(?:ım|ma|ın|ılır|ılm)\w*"),
]
EN_TR_PATTERNS = [(en, re.compile(r"\b" + en + r"(?:'\w*|s|ler|lar|leri|ları|i|ı|e|a|de|da|den|dan|in|ın)?\b", re.I),
                   re.compile(r"\b" + tr, re.I)) for en, tr in EN_TR_PAIRS]

CODE_FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`]*`")
TABLE_SEP_CELL = re.compile(r"^:?-{3,}:?$")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
BLOCKQUOTE = re.compile(r"^\s*>\s?")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")


class Unit:
    """Bir paragraf, liste maddesi, alıntı, başlık veya tablo hücresi.

    Bir paragrafın satıra sarılmış satırları tek metinde birleşir. Böylece
    cümle uzunluğu editörün satır düzenine bağlı olmaz. lines, metindeki her
    parçanın başladığı yeri ve satır numarasını tutar.
    """

    def __init__(self, kind, lineno, text):
        self.kind = kind
        self.text = text
        self.lines = [(0, lineno)]

    def join(self, lineno, text):
        self.text += " "
        self.lines.append((len(self.text), lineno))
        self.text += text

    def lineno_at(self, offset):
        index = bisect.bisect_right([start for start, _ in self.lines], offset) - 1
        return self.lines[max(index, 0)][1]


def iter_units(text):
    """Kod bloklarını atlar, inline kodu siler, tablo satırlarını hücrelere böler.

    Ardışık düz yazı satırlarını tek birime birleştirir. Boş satır, başlık,
    liste maddesi, tablo satırı, alıntı ve code fence yeni birim başlatır.
    Liste maddesinin ve alıntının sarılmış devam satırları o birime katılır.
    """
    in_fence = False
    unit = None
    for lineno, raw in enumerate(text.splitlines(), 1):
        if CODE_FENCE.match(raw):
            in_fence = not in_fence
            if unit:
                yield unit
                unit = None
            continue
        if in_fence:
            continue
        line = INLINE_CODE.sub("", raw)
        if not raw.strip():
            if unit:
                yield unit
                unit = None
            continue
        if "|" in line and line.strip().startswith("|"):
            if unit:
                yield unit
                unit = None
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if all(TABLE_SEP_CELL.match(c) or not c for c in cells):
                continue
            for c in cells:
                if c:
                    yield Unit("cell", lineno, c)
            continue
        if HEADING.match(raw):
            if unit:
                yield unit
            yield Unit("heading", lineno, line)
            unit = None
            continue
        quote = BLOCKQUOTE.match(line)
        if quote:
            if unit and unit.kind == "quote":
                unit.join(lineno, line[quote.end():])
                continue
            if unit:
                yield unit
            unit = Unit("quote", lineno, line[quote.end():])
            continue
        if LIST_ITEM.match(line):
            if unit:
                yield unit
            unit = Unit("list", lineno, line)
            continue
        if unit and unit.kind in ("prose", "list", "quote"):
            unit.join(lineno, line.strip())
            continue
        if unit:
            yield unit
        unit = Unit("prose", lineno, line)
    if unit:
        yield unit


def sentences(line):
    """(başlangıç konumu, cümle) çiftleri verir."""
    start = 0
    for m in list(SENTENCE_SPLIT.finditer(line)) + [None]:
        end = m.start() if m else len(line)
        chunk = line[start:end]
        stripped = chunk.strip()
        if stripped:
            yield start + (len(chunk) - len(chunk.lstrip())), stripped
        if m:
            start = m.end()


def word_count(s):
    return len([w for w in re.split(r"\s+", s) if re.search(r"\w", w)])


def check_chain(sentence):
    """Komut cümlesinde -ArAk (sert) veya -Ip (öneri) ile ikinci komut."""
    words = re.findall(r"\w+", sentence)
    if not words:
        return None
    last = words[-1]
    if not IMPERATIVE_END.search(last):
        return None
    for m in ARAK_TOKEN.finditer(sentence):
        if m.group(0).lower() not in ARAK_EXCLUDE:
            return ("komut-zinciri", "sert", m.group(0),
                    "Bir cümlede iki komut (-ArAk). Her komutu ayrı cümle veya liste maddesi yap.")
    for m in IP_TOKEN.finditer(sentence):
        if m.group(0).lower() not in IP_NOUNS:
            return ("komut-zinciri", "oneri", m.group(0),
                    "Olası komut zinciri (-Ip). Her komutu ayrı cümle veya liste maddesi yap.")
    return None


def lint(text, name="<stdin>", disabled=()):
    findings = []
    seen_syn = {}
    seen_en_tr = {}
    total_words = 0
    for unit in iter_units(text):
        line = unit.text
        for start, sent in sentences(line):
            lineno = unit.lineno_at(start)
            n = word_count(sent)
            total_words += n
            if "uzun-cumle" not in disabled and n > MAX_WORDS and unit.kind != "heading":
                findings.append(dict(file=name, line=lineno, rule="uzun-cumle", level="sert",
                                     match=sent[:60] + ("…" if len(sent) > 60 else ""),
                                     msg=f"{n} sözcük, sınır {MAX_WORDS}. Cümleyi böl."))
            if "komut-zinciri" not in disabled:
                c = check_chain(sent)
                if c:
                    rule, level, match, msg = c
                    findings.append(dict(file=name, line=lineno, rule=rule, level=level, match=match, msg=msg))
        for rule, level, rx, msg in RULES:
            if rule in disabled:
                continue
            for m in rx.finditer(line):
                findings.append(dict(file=name, line=unit.lineno_at(m.start()), rule=rule, level=level,
                                     match=m.group(0), msg=msg))
        if "esanlamli-rotasyon" not in disabled:
            for gi, group in enumerate(SYNONYM_PATTERNS):
                for w, rx in group:
                    m = rx.search(line)
                    if m:
                        seen_syn.setdefault(gi, {}).setdefault(w, unit.lineno_at(m.start()))
        if "en-tr-karisimi" not in disabled:
            for en, en_rx, tr_rx in EN_TR_PATTERNS:
                m = en_rx.search(line)
                if m:
                    seen_en_tr.setdefault(en, {}).setdefault("en", unit.lineno_at(m.start()))
                m = tr_rx.search(line)
                if m:
                    seen_en_tr.setdefault(en, {}).setdefault("tr", unit.lineno_at(m.start()))
    for gi, hits in seen_syn.items():
        if len(hits) >= 2:
            words = ", ".join(f"{w} (satır {ln})" for w, ln in hits.items())
            findings.append(dict(file=name, line=min(hits.values()), rule="esanlamli-rotasyon", level="sert",
                                 match=words, msg="Aynı eylem için birden çok sözcük. Birini seç, hepsinde onu kullan."))
    for en, hits in seen_en_tr.items():
        if len(hits) == 2:
            findings.append(dict(file=name, line=min(hits.values()), rule="en-tr-karisimi", level="sert",
                                 match=f"{en} (satır {hits['en']}) / Türkçesi (satır {hits['tr']})",
                                 msg="Aynı kavram hem İngilizce hem Türkçe. Birini seç."))
    findings.sort(key=lambda f: (f["file"], f["line"]))
    return findings, total_words


def selftest():
    clean = [
        "İşlem başarısız olmuş olabilir.",
        "Yedek alın. Bağlantıyı kontrol edin. Komutu çalıştırın.",
        "Aktarımı tekrar başlatmayın. Aksi hâlde sipariş kayıtları çoğalır.",
        "Bu değer muhtemelen eski bir istemci sürümünden kaynaklanıyor.",
    ]
    for s in clean:
        f, _ = lint(s)
        assert not f, f"temiz olmalıydı: {s!r} -> {f}"
    bad = "Yedek alıp bağlantıyı kontrol ederek komutu çalıştırın; aksi takdirde yazma yapmayın."
    f, _ = lint(bad)
    rules = {x["rule"] for x in f}
    assert {"noktali-virgul", "komut-zinciri", "adlastirma"} <= rules, rules
    mix = "Backend'leri senkronize eder. Arka uçlar arasında veri aktarır. Önce doğrulayın, sonra teyit edin."
    f, _ = lint(mix)
    rules = {x["rule"] for x in f}
    assert {"en-tr-karisimi", "esanlamli-rotasyon"} <= rules, rules
    f, _ = lint("Bu kusursuz entegrasyon sayesinde veriler sorunsuz aktarılır.")
    assert sum(x["rule"] == "pazarlama-sifati" for x in f) == 2, f
    f, _ = lint("Kullanıcının yedekleme işlemini gerçekleştirmesi gerekmektedir.")
    rules = {x["rule"] for x in f}
    assert {"adlastirma", "resmi-kalip"} <= rules, rules
    long_sentence = ("Bu cümle on sekiz sözcüğü aşacak kadar uzun olduğu için linter tarafından "
                     "uzun cümle olarak işaretlenmeli ve bölünmeli diye buradadır.")
    f, _ = lint(long_sentence)
    assert any(x["rule"] == "uzun-cumle" for x in f), f
    # Satıra sarılmış paragraf: aynı cümle iki satırda da uzun sayılır. Satır numarası cümlenin başıdır.
    wrapped = "Giriş cümlesi kısa.\n" + long_sentence.replace("tarafından ", "tarafından\n")
    f, _ = lint(wrapped)
    long_hits = [x for x in f if x["rule"] == "uzun-cumle"]
    assert len(long_hits) == 1 and long_hits[0]["line"] == 2, f
    # Liste maddeleri, tablo hücreleri, başlık ve code fence birleşmez.
    # Cümle sonunda nokta yok: birleşirse iki parça tek uzun cümle olur.
    short = "Bu madde on sözcükten az ama birleşirse uzun olur"
    for text in ("- " + short + "\n- " + short, "1. " + short + "\n2. " + short,
                 "| " + short + " | " + short + " |", "# " + short + "\n" + short,
                 short + "\n```\n" + short + "\n```\n" + short, short + "\n\n" + short,
                 "> " + short + "\n\n" + short):
        f, _ = lint(text)
        assert not any(x["rule"] == "uzun-cumle" for x in f), (text, f)
    # Liste maddesinin sarılmış devam satırı maddeye katılır.
    f, _ = lint("- " + long_sentence.replace("olduğu ", "olduğu\n  "))
    assert any(x["rule"] == "uzun-cumle" and x["line"] == 1 for x in f), f
    # Satır sınırını aşan kalıp da yakalanır, satır numarası kalıbın başıdır.
    f, _ = lint("Kısa giriş.\nSonra kontrol\nyapın.")
    assert any(x["rule"] == "adlastirma" and x["line"] == 2 for x in f), f
    print("selftest OK")


def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        selftest()
        return 0
    as_json = "--json" in args
    baseline = 0
    disabled = set()
    files = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--json":
            pass
        elif a == "--baseline":
            baseline = int(args[i + 1]); i += 1
        elif a == "--disable":
            disabled |= set(args[i + 1].split(",")); i += 1
        elif a.startswith("-"):
            print(f"bilinmeyen seçenek: {a}", file=sys.stderr); return 2
        else:
            files.append(a)
        i += 1
    inputs = [(f, open(f, encoding="utf-8").read()) for f in files] if files else [("<stdin>", sys.stdin.read())]
    all_f = []
    words = 0
    for name, text in inputs:
        f, w = lint(text, name, disabled)
        all_f += f
        words += w
    hard = [f for f in all_f if f["level"] == "sert"]
    if as_json:
        print(json.dumps(dict(findings=all_f, hard=len(hard), baseline=baseline, words=words), ensure_ascii=False, indent=2))
    else:
        for f in all_f:
            tag = "" if f["level"] == "sert" else " (öneri)"
            print(f"{f['file']}:{f['line']} {f['rule']}{tag}: {f['msg']} [{f['match']}]")
        rate = (len(all_f) / words * 100) if words else 0
        print(f"\n{len(all_f)} bulgu ({len(hard)} sert, baseline {baseline}), {words} sözcük, 100 sözcükte {rate:.1f}")
        print("Kip ve kesinlik (olabilir, muhtemelen) asla işaretlenmez: güven içeriktir.")
    return 1 if len(hard) > baseline else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
