# Ritual text sources

Provenance for `BornlessRitual/Resources/RitualText.json`. All texts were retrieved on
**2026-09-11**. Nothing in the data file is quoted from memory: every line was taken from a
fetched copy of the source and, for both editions, checked against page images of the
original printing.

## 1. Goodwin 1852 (`goodwin1852`)

**Charles Wycliffe Goodwin (ed. & tr.), _Fragment of a Græco-Egyptian Work upon Magic,
from a Papyrus in the British Museum_.** Publications of the Cambridge Antiquarian Society,
Octavo Series No. II. Cambridge: Deighton; Macmillan and Co.; London: J. W. Parker; Oxford:
J. H. Parker, 1852. Printed by Richard Taylor, Red Lion Court, Fleet Street.

The passage used is Goodwin's section **"4. An address to the god drawn upon the letter"**
(his numbering of the spells in the papyrus; the papyrus is British Museum Papyrus XLVI,
now catalogued as PGM V, and the passage is PGM V.96–172). Goodwin prints the Greek on the
even pages and his English on the facing odd pages:

| Printed page | Content | PDF leaf (0-based) |
|---|---|---|
| 6 | Greek: opening through the six spirit names (`Αωθ … σαβαωθ,`) | 88 |
| 7 | English: "I call thee, the headless one …" through "deliver such an one . . ." | 89 |
| 8 | Greek: `ιαω, οὗτός ἐστιν ὁ κύριος τῶν θεῶν …` through the rubric and `Ἔστιν δὲ τὸ ἀγαθὸν ζώδιον` | 90 |
| 9 | English: "This is the lord of the gods …" through "And all the spirits shall be obedient to you." | 91 |

### Where it was fetched from

* Item page: <https://archive.org/details/publications00verogoog>
  (Google-digitised copy from the University of California library; the item is a bound
  volume of Cambridge Antiquarian Society octavo publications, of which Goodwin's is No. II.
  Archive.org metadata: `possible-copyright-status = NOT_IN_COPYRIGHT`, source
  `books.google.com/books?id=FuA4AAAAIAAJ`.)
* OCR text actually used for the transcription:
  <https://archive.org/stream/publications00verogoog/publications00verogoog_djvu.txt>
  (HTTP 200).
* Page images used to verify the OCR:
  <https://archive.org/download/publications00verogoog/publications00verogoog.pdf>
  (HTTP 200; leaves 88–91 rendered with PyMuPDF and read visually; the Greek name lists on
  p. 6 were additionally checked from a 300-dpi crop).

### What the verification changed

* The OCR had `Iapds`; the print reads **Iapōs** (macron).
* The OCR had `residing in the empty WING`; the print reads **"residing in the empty wind,"**.
* The OCR dropped the last clause of p. 7; the print ends **"deliver such an one . . . ."**
  (the trailing dots stand for the six spirit names).
* Goodwin renders every run of Barbarous Names in his English as a row of dots. The data
  file reproduces each such run as `. . . . . . . .`. The names themselves are printed
  only in his Greek (see the table in §4).
* `(?)` after "the bringer forth" is Goodwin's own query and is kept.

## 2. Liber Samekh (`samekh1930`)

**Aleister Crowley, _Liber Samekh. Theurgia Goetia Summa (Congressus cum Daemone) sub figura
DCCC_**, printed as Appendix IV of _Magick in Theory and Practice_ by the Master Therion
(Aleister Crowley), "Published for subscribers only", title page dated 1929, printed at the
Lecram Press, Paris (the four-part subscribers' issue actually appeared 1929–30, hence the
edition key `samekh1930`). The ritual text is **Point I, "Evangelii Textus Redactus — The
Invocation"**, pp. 265–273; the performance commentary is Point II, "Ars Congressus cum
Daemone", pp. 274 ff.

### Where it was fetched from

Attempted first, as instructed, and **blocked**:

| URL | Result |
|---|---|
| `https://hermetic.com/crowley/libers/lib800` | HTTP 403 — Cloudflare "Just a moment…" JavaScript challenge (`cZone: hermetic.com`), both via WebFetch and curl |
| `https://sacred-texts.com/oto/lib800.htm`, `https://www.sacred-texts.com/oto/lib800.htm`, `https://archive.sacred-texts.com/oto/lib800.htm` | HTTP 403 — Cloudflare JavaScript challenge |
| `https://lib.oto-usa.org/libri/liber0800.html` | HTTP 403 |
| `https://web.archive.org/web/…/hermetic.com/crowley/libers/lib800` and `…/sacred-texts.com/oto/lib800.htm` | connection reset (egress relay closed the tunnel to web.archive.org) |
| `https://en.wikisource.org/wiki/Liber_Samekh` | HTTP 404; Wikisource search finds neither Liber Samekh nor Goodwin 1852 |
| `https://archive.org/download/b29825064/b29825064_djvu.txt` | HTTP 401 — the archive.org copy of the 1929 scan is `access-restricted-item` (Wellcome print-disabled collection) |

Used:

* **Transcription base (HTTP 200):** the archive.org e-text of _Magick in Theory and
  Practice_ ("Based on the Castle Books edition of New York", with `{page}` markers that match
  the 1929 pagination):
  <https://archive.org/download/MagickInTheoryAndPracticeAleisterCrowley/Magick%20in%20Theory%20and%20Practice%2C%20Aleister%20Crowley_djvu.txt>
  (item <https://archive.org/details/MagickInTheoryAndPracticeAleisterCrowley>). Two further
  archive.org copies of the same e-text were downloaded and agree
  (`aleister-crowley-magic-in-theory-and-practice`, `aleister-crowley-magick-in-theory-and-practice`).
* **First-edition witness (HTTP 200):** Wellcome Collection's IIIF service for its copy of the
  1929 edition (Wellcome b29825064 — the same scan that is restricted on archive.org):
  manifest <https://iiif.wellcomecollection.org/presentation/v2/b29825064>; full OCR text
  <https://api.wellcomecollection.org/text/v1/b29825064>; per-page ALTO
  `https://api.wellcomecollection.org/text/alto/b29825064/b29825064_NNNN.jp2`; page images
  `https://iiif.wellcomecollection.org/image/b29825064_NNNN.jp2/full/1100,/0/default.jpg`.
  Canvases 0302–0309 are pp. 266–273. Every page of Point I was read visually.
* **Cross-check only (HTTP 200):** <https://thelemapedia.org/index.php/Liber_Samekh>
  (a mirror of the same e-text, with its own typos, e.g. "hy Prophet"; not used as a base).

### What the first-edition check changed

* IB: the 1929 edition reads **"whose Word is Truth"**; the e-texts (and thelemapedia) have
  "whose Word in Truth". The 1929 reading is used.
* Second ThIAF: "The Beast that whirlest forth" — the e-text has the typo "Beas".
* Section H, p. 273: the 1929 edition has the printer's slip "upon the Earth **und** under
  the Earth"; the data file gives "and" (recorded here so the change is traceable).
* "thunder-|bolt" is broken at a line end in both occurrences on p. 267; the data file gives
  "thunderbolt".
* Typographic artefacts of the Paris printer are normalised: spaces before `!` and `:`
  (`Thou Air ! Breath !`), spaced hyphens inside names (`ANKH - F - N - KHONSU`,
  `PTAH - APO-PHRASZ - RA`, `AThOR-e - BAL - O`), a stray full stop after `BAS-AUMGN.`.
  The BAS-AUMGN gloss lacks its closing `)"` in the print; it is closed in the data file.
* Footnote markers and footnotes are omitted. The one that matters for pronunciation
  (p. 267, n. 1) reads: *"The letter F is used to represent the Hebrew Vau and the Greek
  Digamma; its sound lies between those of the English long o and long oo, as in Rope and
  Tooth."* Note also p. 268 n. 1: *"See, for the formula of IAF, or rather FIAOF, Book 4 Part
  III, Chapter V. The form FIAOF will be found preferable in practice."*
* The 1929 edition sets each Barbarous Name in a left column and Crowley's quoted paraphrase
  in a right column. The data file joins them as `NAME — "paraphrase"`; where a name has
  several quoted paraphrases (OOO, BABALON-BAL-BIN-ABAFT, SA-BA-FT) they follow one another.
  Crowley's parenthetical stage notes ("The conception is of Air …") are kept as lines.

## 3. Public-domain reasoning

* **Goodwin 1852.** Charles Wycliffe Goodwin died in 1878; the work was published in the
  United Kingdom in 1852. UK/EU copyright (life + 70) expired at the end of 1948; in the
  United States anything published before 1930 is in the public domain. Archive.org marks the
  digitised copy `NOT_IN_COPYRIGHT`.
* **Liber Samekh / Magick in Theory and Practice.** Aleister Crowley died on 1 December
  1947, so UK/EU copyright in his writings (life + 70) expired on 31 December 2017. In the
  United States, works first published in 1929 entered the public domain on 1 January 2025
  and works first published in 1930 on 1 January 2026; the subscribers' issue is dated
  1929 and was distributed 1929–30, so it is in the US public domain under either date as of
  the retrieval date. The project owner has additionally instructed that Liber Samekh be
  treated as public domain. Wellcome Collection attaches a generic "In copyright / it is
  possible this item is protected" rights statement to its scan; that statement is a
  blanket caution, not a claim specific to this work.
* **Not used, deliberately:** Hans Dieter Betz (ed.), _The Greek Magical Papyri in
  Translation_ (1986), and every other modern copyrighted translation of PGM V; likewise the
  editorial matter of the 1994/1997 Weiser _Magick: Book 4_ edition. The archive.org e-text is
  a transcription of Crowley's 1929 text (via the Castle Books reprint), not of a later
  edited edition, and it was corrected against the 1929 pages.

## 4. Stage ↔ section mapping

Section labels are those printed in the 1929 edition. (The brief for this file referred to
the elemental sections as "Aa/Ee/Ii/Oo/Uu"; those labels do not occur in Liber Samekh, where
"Section Aa" is the second half of the Oath. The mapping below follows the printed labels.)

| Stage id | Title | Liber Samekh 1929 | Goodwin 1852 | Quarter (Point II) |
|---|---|---|---|---|
| `opening` | The Oath | Section A "The Oath" + Section Aa (p. 266) | "I call thee, the headless one …" through "… handed down to the prophets of Israel." (p. 7) | — |
| `air` | Air — East | Section B "Air" (p. 267) | "Listen to me, . . . hear me and drive away this spirit." (p. 7) | "This Section B invokes Air in the East" |
| `fire` | Fire — South | Section C "Fire" (p. 268) | "I call thee the terrible and invisible god residing in the empty wind, . . . thou headless one, deliver such an one from the spirit that possesses him." (p. 7) | "invokes Fire in the South" |
| `water` | Water — West | Section D "Water" (pp. 268–269) | ". . . strong one, headless one, deliver such an one from the spirit that possesses him." (p. 7) | "invokes Water in the West" |
| `earth` | Earth — North | Section E "Earth" (pp. 269–270) | ". . . deliver such an one" (p. 7) | "goes to the North to invoke Earth" |
| `spirit` | Spirit | Section F "Spirit" + Section Ff + Section G "Spirit" (pp. 270–273) | ". . . This is the lord of the gods … save this soul . . . angel of God . . ." (p. 9) | "invokes spirit, facing toward Boleskine" |
| `climax` | I am He, the Bornless Spirit | Section Gg "The Attainment" (p. 273) | "I am the headless spirit … my name is the heart girt with a serpent." (p. 9) | — |
| `closing` | Such are the Words | Section H "The Charge to the Spirit" + Section J "The Proclamation of the Beast 666" (p. 273) | "Come forth and follow." + the rubric "—The celebration of the preceding ceremony.— … And all the spirits shall be obedient to you." (p. 9) | — |

Goodwin gives the "Make all the spirits subject to me" formula once, in the closing rubric
("address yourself turning towards the north to the six names, saying …"); Crowley repeats a
version of it after Sections B, C, D, E and Ff and again in Section H.

Sections Ff and G could alternatively be attached to `climax`; they are attached to
`spirit` because Crowley heads both F and G "Spirit" and Goodwin's corresponding sentence
("This is the lord of the gods … save this soul …") follows directly on the six names.

## 5. Barbarous Names, checked against both sources

`barbarousNames` uses the 1929 Samekh orthography: digraphs `Th`, `Ph`, `Ch`, and `F` for
Hebrew Vau / Greek digamma (so `ThIAF` = Thiao, `RU-ABRA-IAF` = Ru-abra-iao, `ABRAFT` =
Abraoth, `AFT` = Aoth, `SA-BA-FT` = Sabaoth, `IAF` = Iao). The brief's spellings "Thiao,
Ru-abra-iao, Abraoth, Aoth, Abaoth, Sabaoth, Iao" are those of Crowley's 1904 "Preliminary
Invocation" to the _Goetia_, not of Liber Samekh; they were not used because the _Goetia_ is
not one of the permitted sources.

| Stage | Goodwin 1852, Greek (p. 6 / p. 8), transliterated | Liber Samekh 1929 |
|---|---|---|
| air | αρ…, θιαω, ρειβετ, αθελεβερσηθ, α..βλαθα, αβευ, εβευ, φι, χιτασοη, ιβ..θιαω | AR, ThIAF, RhEIBET, A-ThELE-BER-SET, A, BELAThA, ABEU, EBEU, PhI-ThETA-SOE, IB, ThIAF |
| fire | αρογογοροβραω, σοχου, μοδοριω, φαλαρχαω, οοο, απε (then ἀκέφαλε "headless one") | AR-O-GO-GO-RU-ABRAO, SOTOU, MUDORIO, PhALARThAO, OOO, AEPE |
| water | Ρουβριαω, μαριωδαμ, βαλβναβαωθ, ασσαλωναι, αφνιαω, ι, θωληθ, αβρασαξ, αηοωυ (then ἰσχυρέ "strong one", ἀκέφαλε) | RU-ABRA-IAF, MRIODOM, BABALON-BAL-BIN-ABAFT, ASAL-ON-AI, APhEN-IAF, I, PhOTETh, ABRASAX, AEOOU, ISChURE |
| earth | Μα, βαρραιω, ιωηλ, κοθα, αθορηβαλω, αβραωθ | MA, BARRAIO, IOEL, KOThA, AThOR-e-BAL-O, ABRAFT |
| spirit | Αωθ, αβαωθ, βασυμ, ισακ, σαβαωθ, ιαω — "the six names" (Goodwin p. 9; Greek τοῖς ϛ ὀνόμασι, p. 8) | AFT, ABAFT, BAS-AUMGN, ISAK, SA-BA-FT (+ gloss "Hail, I A O!"); Section G adds IEOU, PUR, IOU, PUR, IAFTh, IAEO, IOOU, ABRASAX, SABRIAM, OO, FF, AD-ON-A-I, EDE, EDU, ANGELOS TON ThEON, ANLALA, LAI, GAIA, AEPE, DIATHARNA THORON |
| closing | (Goodwin: "Come forth and follow"; rubric) | IAF : SABAF |

Observations from the comparison:

* Goodwin's Greek reads **χιτασοη** (chi); Crowley's `PhI-ThETA-SOE` fuses Goodwin's two
  tokens `φι, χιτασοη` and reads the second with theta.
* Goodwin's `σοχου`, `μοδοριω`, `φαλαρχαω`, `απε` correspond to Crowley's `SOTOU`,
  `MUDORIO`, `PhALARThAO`, `AEPE`; his `βαλβναβαωθ` to `BABALON-BAL-BIN-ABAFT`; his `θωληθ`
  to `PhOTETh`.
* Goodwin translates ἰσχυρέ ("strong one") and ἀκέφαλε ("headless one") as words; Crowley
  keeps `ISChURE` as a name and renders ἀκέφαλε as "The Bornless One. (Vide supra)" /
  "Mighty and Bornless One!".
* **Six spirit beats.** Goodwin's Greek has six names and his rubric says "the six names".
  Crowley prints five entries in Section F and carries the sixth, ιαω, only inside the
  SA-BA-FT gloss ("Hail, I A O!"). The data file therefore lists
  `AFT, ABAFT, BAS-AUMGN, ISAK, SA-BA-FT, IAF`, using `IAF`, Crowley's spelling of the same
  word in Section J (`IAF : SABAF` = ιαω σαβαωθ). If the app would rather display the more
  familiar form, `IAO` is the spelling Crowley uses inside his glosses.

## 6. Local working copies

Downloaded sources (OCR text, page images, ALTO) were kept only in the session scratchpad,
not in the repository. The generator that produced `RitualText.json` from the verified
transcription is a throw-away script; the JSON file is the deliverable and was validated
with `python3 -c 'import json; json.load(open("BornlessRitual/Resources/RitualText.json"))'`.
