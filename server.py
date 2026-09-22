#!/usr/bin/env python3
"""
Hausmasken-Generator — Webserver + CSV-Parser + Validierung in einer Datei.

CSV-Format:
  # Kommentar (wird verworfen)
  raum
  breite,tiefe,hoehe              (genau 3 Werte)
  offset                          (optional: 1/2/4 Werte → alle / x,y (wie breite,tiefe) /
                                   vorne,rechts,hinten,links; an die Zwei- oder Vierwertform
                                   darf die Fussbodenhöhe angehängt werden (3 bzw. 5 Werte).
                                   Sie wird von jeder Fensterhöhe abgezogen, die Fenster
                                   werden dann durchgängig ab Erdboden gemessen.)
  G<n>                            (optionale eigene Zeile, Stockwerk 0–9 beim Stapeln;
                                   ungerades n → alle Platinen um 180 gedreht, Ziffer wird
                                   in die vordere rechte Ecke des Dachs graviert,
                                   Wandinnenecken bekommen Stapelaussparungen und ab
                                   n > 0 passende Zapfen. Die Anschlussart setzt G<n>
                                   nicht – "idc"/"stack" gehört in die licht-Datenzeile.
                                   Eine Rotation in der licht-Zeile hat Vorrang.)
  druck
  wand,0.8                        (Wandstärke; weitere Druckparameter als schluessel,wert)
  wand
  x1,y1,x2,y2[,...,xn,yn]        (freie Innenwand als Eckpunktzug, beliebig viele Punktpaare;
                                  jede Zeile mit >=2 Paaren ist eine eigenständige Wand)
  x,y                            (nur ein Paar → verlängert den offenen Zug um
                                  diesen Punkt)
  x1,y1,name,x2,y2               (optionaler Name → gerade "Fensterwand")
  x1,y1,name / x2,y2             (dasselbe zweizeilig; Endpunkt in der Folgezeile)
  <name>                         (Abschnitt für die benannte Wand)
  x,y,breite,hoehe               (Fenster; x = Distanz ab Wandstart, hier ohne negative Werte)
  vorne|hinten|links|rechts
  x,y,breite,hoehe                (Fenster/Tür – 4 Werte)
  pos                             (Innenwand-Ansatz – 1 Wert, auto-Länge)
  pos,laenge                      (Innenwand mit expliziter Länge – 2 Werte)
  licht
  x,y[,rotation][,weiter|ende][,idc|stack]
                                 (2–3 Werte, absolut vom Körperursprung 0,0; negativ = von rechts/hinten;
                                  "idc" als letztes Feld → IDC-Buchse mit Steckertasche,
                                  "stack" → nur Grundplatte am unteren Tunnelende)
  dach
  x,y,breite,tiefe               (4 Werte: Rechteck-Ausschnitt, Ecke x,y, absolut vom Körperursprung 0,0)
  x,y,<ledtyp>                   (3 Werte: Öffnung nach LED-Typ, Mitte x,y; ledtyp ∈ {none,3mm,5mm,plcc6,plcc2,ws2812})
  text
  Text                            (1 Wert: automatisch 3mm/3mm ab der vorderen
                                   linken Ecke des Druckkörpers)
  x,y,Text                        (3 Werte: Text an x,y)
  x,y,rotation,Text               (4 Werte: Text an x,y mit Rotation)

Lichtbox-Modus (Schlüsselwort "box", schließt "raum" aus → Renderer lightbox.scad):
  box
  breite,hoehe,tiefe              (genau 3 Werte)
  oben|links|rechts               (Fläche für LED-Öffnung: TOP / LEFT / RIGHT)
  <ledtype>                       (LED mittig auf der Fläche)
  <ledtype>[,<clip>][,offset_breite[,offset_tiefe]]
                                  (clip optional als 2. Argument; offset_breite =
                                   entlang Vorderkante, offset_tiefe = Z-Richtung)
  ledtype ∈ {none, 3mm, 5mm, plcc6, plcc2, ws2812}
  clip    ∈ {ohne, einfach, doppel}  (Standard: ohne, weglassbar)

Standalone: python3 server.py --parse sample.csv > house_data.scad
Server:     python3 server.py [--debug]
            --debug schreibt das erzeugte Datenfile jeder Anfrage auf die Konsole
"""

import csv as csv_module
import html as h
import io
import json
import logging
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

MAX_BODY = 4 * 1024  # 4 KB

DEBUG = False  # --debug: erzeugtes Datenfile auf die Konsole schreiben

_rate_lock = threading.Lock()
_rate_data: dict[str, list[float]] = defaultdict(list)
RATE_WINDOW = 60   # Sekunden
RATE_LIMIT   = 10  # POST-Anfragen pro Minute pro IP
SAMPLE_LIMIT = 60  # Abrufe einer Vorlage pro Minute pro IP


# Jeder Schlüssel zählt für sich: Vorlagen werden mit einem eigenen Schlüssel
# gezählt, damit das Blättern im Vorlagenmenü nicht die Vorschau ausbremst.
def _rate_ok(key: str, limit: int = RATE_LIMIT) -> bool:
    now = time.time()
    with _rate_lock:
        ts = [t for t in _rate_data[key] if now - t < RATE_WINDOW]
        if len(ts) >= limit:
            return False
        ts.append(now)
        _rate_data[key] = ts
        return True

BASE_DIR      = os.path.dirname(os.path.abspath(__file__))
MASK_SCAD     = os.path.join(BASE_DIR, "house_mask.scad")
LIGHTBOX_SCAD = os.path.join(BASE_DIR, "lightbox.scad")

# Vorlagen: alle CSV-Dateien unterhalb von data/, die die Weboberfläche im
# Auswahlmenü anbietet.
DATA_DIR         = os.path.join(BASE_DIR, "data")
MAX_SAMPLE_BYTES = 64 * 1024  # Schutz gegen versehentlich große Dateien
MAX_SAMPLE_PATH  = 512        # Zeichen im ?path=-Parameter

KNOWN_SECTIONS = {"raum", "wand", "vorne", "hinten", "links", "rechts", "licht", "dach", "druck", "text"}
DRUCK_KEYS     = {"wand", "aussen", "innen", "dach"}

# ── Lichtbox-Modus (Schlüsselwort "box") ────────────────────────────────────────
# Eigener Renderer (lightbox.scad). "box" und "raum" schließen sich gegenseitig aus.
BOX_FACES = {"oben": 0, "links": 1, "rechts": 2}  # → FACE_TOP / FACE_LEFT / FACE_RIGHT
BOX_SECTIONS = {"box"} | set(BOX_FACES)
# LED-Typ-Namen → LED_* Konstanten in lightbox.scad
LED_NAMES = {
    "none": 0, "keine": 0,
    "3mm": 1,
    "5mm": 2,
    "plcc6": 3,   # LED_5050
    "plcc2": 4,   # LED_3528
    "ws2812": 5
}
# Clip-Namen → CLIP_* Konstanten in lightbox.scad (optional, Standard: ohne)
CLIP_NAMES = {"ohne": 0, "einfach": 1, "doppel": 2}
_BOX_LED_MARGIN = 5  # mm Mindestabstand der LED-Mitte zur Flächenkante
_DACH_LED_R     = 5.5  # mm halbe max. LED-Öffnungsgröße (WS2812 Ø11) für Randprüfung

_RULES = {
    "raum":   {"counts": {3},       "max_rows": 2, "hint": "breite,tiefe,hoehe  [offset[,fussboden]]  [G<n>]"},
    "wand":   {"hint": "x1,y1,x2,y2[,...,xn,yn]  |  x,y (Fortsetzung)"},
    "druck":  {"hint": "schluessel,wert  (z.B. wand,0.8)"},
    "licht":  {"hint": "x,y[,rotation][,weiter|ende][,idc|stack]"},
    "dach":   {"hint": "x,y,breite,tiefe  |  x,y,<ledtyp>"},
    "text":   {"hint": "Text  |  x,y,Text  |  x,y,rotation,Text"},
    "vorne":  {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
    "hinten": {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
    "links":  {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
    "rechts": {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
}

# Stockwerks-Zeile "G<n>" im raum-Abschnitt (Vorgabe für Rotation und Gravur)
_FLOOR_RE = re.compile(r"^[gG](\d+)$")
_FLOOR_MAX = 9  # die Gravur ist auf eine Ziffer ausgelegt


# ── Validation & Parsing ──────────────────────────────────────────────────────

class ValidationError(Exception):
    pass


def _numeric(s: str) -> bool:
    try:
        return math.isfinite(float(s))
    except ValueError:
        return False


def _parse_values(row: list[str]) -> list:
    result = []
    for v in row:
        if not v:
            continue
        num = float(v) if "." in v else int(v)
        if abs(num) > 9999:
            raise ValidationError(f"Wert außerhalb des erlaubten Bereichs (0–9999): {v}")
        result.append(num)
    return result


def _clean_row(row: list[str]) -> list[str]:
    """Strippt Zellen und verwirft Inline-Kommentare ab dem ersten '#'."""
    row = [c.strip() for c in row]
    for i, c in enumerate(row):
        hpos = c.find("#")
        if hpos != -1:
            head = c[:hpos].strip()
            return row[:i] + ([head] if head else [])
    return row


def _floor_of(sections: dict) -> int | None:
    """Stockwerk aus der "G<n>"-Zeile des raum-Abschnitts; None = nicht angegeben."""
    rows = sections.get("raum_geschoss")
    return rows[0][0] if rows else None


def _detect_box_mode(text: str) -> bool:
    """True, sobald irgendwo ein Abschnitt "box" beginnt (Lichtbox-Modus)."""
    for row in csv_module.reader(io.StringIO(text)):
        row = _clean_row(row)
        if row and row[0].lower() == "box":
            return True
    return False


def _parse_box(text: str) -> dict:
    """Parst eine Lichtbox-Konfiguration (Schlüsselwort "box").

    Abschnitte:
      box                 → eine Zeile: breite,höhe,tiefe
      oben|links|rechts   → je Zeile eine LED: <typ>[, offset_breite[, offset_tiefe]]
    """
    errors: list[str] = []
    sections: dict = {}
    current: str | None = None
    row_counts: dict[str, int] = {}

    for lineno, row in enumerate(csv_module.reader(io.StringIO(text)), start=1):
        row = _clean_row(row)
        values = [c for c in row if c]
        if not values:
            continue
        first = values[0]
        low = first.lower()

        # Abschnitts-Schlüsselwort (allein in der Zeile)
        if low in BOX_SECTIONS and len(values) == 1:
            current = low
            sections.setdefault(current, [])
            row_counts.setdefault(current, 0)
            continue

        if current is None:
            errors.append(f"Zeile {lineno}: Datenwerte vor dem ersten Abschnitts-Schlüsselwort")
            continue

        if current == "box":
            if len(values) != 3 or any(not _numeric(v) for v in values):
                errors.append(
                    f'Zeile {lineno}: Abschnitt "box" erwartet 3 Werte '
                    f"(breite,höhe,tiefe), gefunden: {len(values)}"
                )
                continue
            row_counts[current] += 1
            if row_counts[current] > 1:
                errors.append(f'Zeile {lineno}: Abschnitt "box" erlaubt nur eine Datenzeile')
                continue
            try:
                sections[current].append(_parse_values(values))
            except ValidationError as e:
                errors.append(f"Zeile {lineno}: {e}")
            continue

        # current ∈ {oben, links, rechts}: LED-Spezifikation
        # Format: <typ> [, <clip>] [, offset_breite [, offset_tiefe]]
        if low not in LED_NAMES:
            errors.append(
                f'Zeile {lineno}: Unbekannter LED-Typ "{first}" - erlaubt: '
                f"{', '.join(sorted(LED_NAMES))}"
            )
            continue
        rest = values[1:]
        # Optionaler Clip als zweites Argument (Standard: ohne)
        clip = 0
        if rest and rest[0].lower() in CLIP_NAMES:
            clip = CLIP_NAMES[rest[0].lower()]
            rest = rest[1:]
        if len(rest) > 2:
            errors.append(
                f'Zeile {lineno}: Abschnitt "{current}" erwartet '
                f"<typ>[, <clip>][, offset_breite[, offset_tiefe]], zu viele Werte: {len(values)}"
            )
            continue
        bad = [v for v in rest if not _numeric(v)]
        if bad:
            errors.append(
                f'Zeile {lineno}: ungültige Offsets/Clip: {", ".join(bad)} '
                f"(Clip ∈ {{{', '.join(CLIP_NAMES)}}})"
            )
            continue
        try:
            nums = _parse_values(rest)
        except ValidationError as e:
            errors.append(f"Zeile {lineno}: {e}")
            continue
        off1 = nums[0] if len(nums) >= 1 else 0
        off2 = nums[1] if len(nums) >= 2 else 0
        sections[current].append([LED_NAMES[low], clip, off1, off2])
        row_counts[current] += 1

    if not sections.get("box"):
        errors.append('Abschnitt "box" mit "breite,höhe,tiefe" erforderlich')

    if errors:
        raise ValidationError("\n".join(errors))
    return sections


def validate_and_parse(text: str) -> dict:
    if _detect_box_mode(text):
        return _parse_box(text)

    errors = []
    sections: dict = {}
    current: str | None = None
    row_counts: dict[str, int] = {}
    wall_names: set = set()  # benannte "wand"-Fensterwände; als Section-Keyword nutzbar
    wand_open = False        # im laufenden "wand"-Abschnitt ist ein Zug offen

    for lineno, row in enumerate(csv_module.reader(io.StringIO(text)), start=1):
        row = [c.strip() for c in row]
        # Inline-Kommentare: ab dem ersten '#' bis Zeilenende verwerfen
        for i, c in enumerate(row):
            h = c.find("#")
            if h != -1:
                head = c[:h].strip()
                row = row[:i] + ([head] if head else [])
                break
        if not row or not any(row):
            continue
        first = row[0]

        if first and not _numeric(first):
            keyword = first.lower()
            # druck key-value rows start with a non-numeric key — intercept before keyword check.
            # Only intercept when a value cell is present (len >= 2); a lone keyword falls through
            # to section-switch handling so e.g. "dach" can still start the dach section.
            values_all = [c for c in row if c]
            if current == "druck" and keyword in DRUCK_KEYS and len(values_all) >= 2:
                if len(values_all) != 2 or not _numeric(values_all[1]):
                    errors.append(
                        f'Zeile {lineno}: Abschnitt "druck" erwartet "schluessel,wert", '
                        f'z.B. "wand,0.8"'
                    )
                    continue
                try:
                    parsed = _parse_values([values_all[1]])
                except ValidationError as e:
                    errors.append(f"Zeile {lineno}: {e}")
                    continue
                sections[current].append([keyword, parsed[0]])
                row_counts[current] += 1
                continue
            # Stockwerks-Zeile "G<n>" im raum-Abschnitt — ebenfalls vor der Keyword-Prüfung.
            # Sie zählt nicht als Datenzeile, "raum" bleibt bei Maßen und Offset.
            floor_match = _FLOOR_RE.match(first) if current == "raum" else None
            if floor_match and len(values_all) == 1:
                floor = int(floor_match.group(1))
                if floor > _FLOOR_MAX:
                    errors.append(
                        f'Zeile {lineno}: Stockwerk "{first}" zu groß - '
                        f"erlaubt sind einstellige Werte (G0–G{_FLOOR_MAX})"
                    )
                elif "raum_geschoss" in sections:
                    errors.append(
                        f'Zeile {lineno}: Abschnitt "raum" erlaubt nur eine Stockwerks-Zeile'
                    )
                else:
                    sections["raum_geschoss"] = [[floor]]
                continue
            # Die Stockwerkszeile stand früher im licht-Abschnitt; dort hilft ein
            # gezielter Hinweis mehr als "Unbekanntes Schlüsselwort".
            if (_FLOOR_RE.match(first) and len(values_all) == 1
                    and current not in ("raum", "text")
                    and keyword not in KNOWN_SECTIONS
                    and keyword not in wall_names):
                errors.append(
                    f'Zeile {lineno}: Stockwerkszeile "{first}" gehört in den '
                    f'Abschnitt "raum"'
                )
                continue
            if (current == "text" and keyword not in KNOWN_SECTIONS
                    and keyword not in wall_names):
                pass  # Textinhalt: nicht-numerische Zeile als Datum durchfallen lassen
            elif keyword not in KNOWN_SECTIONS and keyword not in wall_names:
                errors.append(
                    f'Zeile {lineno}: Unbekanntes Schlüsselwort "{first}" - '
                    f"erlaubt: {', '.join(sorted(KNOWN_SECTIONS))}"
                    + (f" oder Wandname: {', '.join(sorted(wall_names))}" if wall_names else "")
                )
                continue
            else:
                # Keyword ∈ KNOWN_SECTIONS oder ein zuvor definierter Wandname
                current = keyword
                sections.setdefault(current, [])
                row_counts.setdefault(current, 0)
                wand_open = False    # Abschnittswechsel beendet den offenen Zug
                continue

        if current is None:
            errors.append(f"Zeile {lineno}: Datenwerte vor dem ersten Abschnitts-Schlüsselwort")
            continue

        values = [c for c in row if c]

        # licht-Abschnitt: optionales Keyword als letztes Feld; "0" = automatisch
        if current == "licht":
            _SLOT_KW = {"weiter": 1, "ende": 2}
            _IDC_KW = {"idc": 1, "stack": 2}
            slot_mode = 0
            # None = nicht angegeben; nach der Schleife auf 0 (kein Anschluss)
            # gesetzt. Die Stockwerks-Zeile "G<n>" füllt nur die Rotation auf.
            idc = None  # Buchse nur bei angehängtem Schlüsselwort "idc"/"stack"
            vals = list(values)
            if vals and vals[-1].lower() in _IDC_KW:
                idc = _IDC_KW[vals[-1].lower()]
                vals = vals[:-1]
            if vals and vals[-1].lower() in _SLOT_KW:
                slot_mode = _SLOT_KW[vals[-1].lower()]
                vals = vals[:-1]
            # Einzelner Wert "0" → Autopositionierung für beide Achsen
            if vals == ["0"]:
                row_counts[current] += 1
                sections[current].append([0, 0, None, slot_mode, idc])
                continue
            count = len(vals)
            if count not in {2, 3}:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "licht" erwartet 2 oder 3 Werte '
                    f"(x,y[,rotation][,weiter|ende][,idc|stack]), gefunden: {count}"
                )
                continue
            bad_licht = [v for v in vals if not _numeric(v)]
            if bad_licht:
                errors.append(
                    f'Zeile {lineno}: Nicht-numerische Werte: {", ".join(bad_licht)}'
                )
                continue
            row_counts[current] += 1
            nums = _parse_values(vals)
            sections[current].append(
                [nums[0], nums[1], nums[2] if len(nums) >= 3 else None, slot_mode, idc]
            )
            continue

        # text-Abschnitt: letztes Feld ist ein String, vorherige Felder sind Zahlen
        if current == "text":
            count = len(values)
            if count not in {1, 3, 4}:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "text" erwartet 1, 3 oder 4 Werte '
                    f"(Text | x,y,Text | x,y,rotation,Text), gefunden: {count}"
                )
                continue
            text_val = values[-1]
            num_vals = values[:-1]
            bad_nums = [v for v in num_vals if not _numeric(v)]
            if bad_nums:
                errors.append(
                    f'Zeile {lineno}: Nicht-numerische Koordinaten: {", ".join(bad_nums)}'
                )
                continue
            if len(text_val) > 50:
                errors.append(f"Zeile {lineno}: Text zu lang (max 50 Zeichen)")
                continue
            row_counts[current] += 1
            nums = _parse_values(num_vals) if num_vals else []
            if len(nums) == 0:
                # Ohne Koordinaten: None → generate_scad setzt die Automatikposition
                # relativ zum Druckkörper, hier ist der Druckversatz noch unbekannt.
                entry = [text_val, None, None, 0]
            elif len(nums) == 2:
                entry = [text_val, nums[0], nums[1], 0]
            else:
                entry = [text_val, nums[0], nums[1], nums[2]]
            sections[current].append(entry)
            continue

        # dach-Abschnitt: entweder x,y,breite,tiefe (Rechteck-Ausschnitt) oder
        # x,y,<ledtyp> (Öffnung nach LED-Typ, Geometrie via led_negative_by_type)
        if current == "dach":
            count = len(values)
            if count == 3 and not _numeric(values[2]):
                led_name = values[2].lower()
                if led_name not in LED_NAMES:
                    errors.append(
                        f'Zeile {lineno}: Unbekannter LED-Typ "{values[2]}" - erlaubt: '
                        f"{', '.join(sorted(LED_NAMES))}"
                    )
                    continue
                bad_dach = [v for v in values[:2] if not _numeric(v)]
                if bad_dach:
                    errors.append(f"Zeile {lineno}: Nicht-numerische Werte: {', '.join(bad_dach)}")
                    continue
                nums = _parse_values(values[:2])
                row_counts[current] += 1
                sections[current].append([nums[0], nums[1], LED_NAMES[led_name]])
                continue
            if count != 4:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "dach" erwartet 4 Werte (x,y,breite,tiefe) '
                    f"oder 3 Werte (x,y,<ledtyp>), gefunden: {count}"
                )
                continue
            bad_dach = [v for v in values if not _numeric(v)]
            if bad_dach:
                errors.append(f"Zeile {lineno}: Nicht-numerische Werte: {', '.join(bad_dach)}")
                continue
            nums = _parse_values(values)
            row_counts[current] += 1
            sections[current].append([nums[0], nums[1], nums[2], nums[3]])
            continue

        # wand-Abschnitt: eine Zeile mit zwei oder mehr Koordinatenpaaren beginnt
        # einen eigenständigen Polygonzug; eine Zeile mit genau einem Paar
        # (optional gefolgt von einem Namen) setzt den offenen Zug fort, egal wie
        # viele Punkte dessen letzte Zeile hatte. So bleiben mehrpunktige Zeilen
        # voneinander getrennt, ein Zug lässt sich aber über Zeilen hinweg
        # verlängern. Ein Name-Token (nicht-numerisch) benennt das Segment, das am
        # unmittelbar davor genannten Punkt beginnt – dieses gerade Segment wird
        # zur "Fensterwand".
        if current == "wand":
            row_counts["wand"] += 1
            pts = []             # Punkte dieser Zeile
            line_names = {}      # Segmentindex innerhalb dieser Zeile → Name
            pend = None          # offener x-Wert eines noch unvollständigen Paares
            line_err = None
            for tok in values:
                if _numeric(tok):
                    if pend is None:
                        pend = tok
                    else:
                        try:
                            xy = _parse_values([pend, tok])
                        except ValidationError as ex:
                            line_err = str(ex); break
                        pts.append([xy[0], xy[1]])
                        pend = None
                else:  # Name-Token
                    if pend is not None:
                        line_err = f'Name "{tok}" mitten in einem Koordinatenpaar'; break
                    if not pts:
                        line_err = f'Name "{tok}" vor dem ersten Punkt der Zeile'; break
                    nm = tok.lower()
                    if nm in KNOWN_SECTIONS or nm in wall_names:
                        line_err = f'Wandname "{tok}" ist reserviert oder bereits vergeben'; break
                    seg = len(pts) - 1  # Segment ab dem zuletzt genannten Punkt
                    if seg in line_names:
                        line_err = "Segment hat bereits einen Namen"; break
                    line_names[seg] = nm
                    wall_names.add(nm)
            if line_err is None and pend is not None:
                line_err = "ungerade Anzahl an Koordinaten (x,y-Paare erwartet)"
            if line_err is None and not pts:
                line_err = "kein Koordinatenpaar in der Zeile"
            if line_err:
                errors.append(f"Zeile {lineno}: {line_err}")
                continue
            # Ein einzelnes Paar verlängert den offenen Zug, mehrere beginnen einen neuen.
            if wand_open and len(pts) == 1:
                entry = sections["wand"][-1]
            else:
                entry = {"pts": [], "names": {}, "line": lineno}
                sections["wand"].append(entry)
            base = len(entry["pts"])
            entry["pts"].extend(pts)
            for seg, nm in line_names.items():
                entry["names"][base + seg] = nm
            wand_open = True
            continue

        # Fensterwand: Abschnitt mit einem Wandnamen als Keyword; Fenster wie vorne/hinten
        if current in wall_names:
            if len(values) != 4:
                errors.append(
                    f'Zeile {lineno}: Fensterwand "{current}" erwartet 4 Werte '
                    f"(x,y,breite,hoehe), gefunden: {len(values)}"
                )
                continue
            bad = [v for v in values if not _numeric(v)]
            if bad:
                errors.append(f"Zeile {lineno}: Nicht-numerische Werte: {', '.join(bad)}")
                continue
            nums = _parse_values(values)
            sections[current].append([nums[0], nums[1], nums[2], nums[3]])
            row_counts[current] += 1
            continue

        bad = [v for v in values if not _numeric(v)]
        if bad:
            errors.append(f"Zeile {lineno}: Nicht-numerische Werte: {', '.join(bad)}")
            continue

        rule = _RULES.get(current, {})
        count = len(values)

        max_rows = rule.get("max_rows")
        row_counts[current] += 1

        # "raum": erste Zeile = 3 Werte, zweite Zeile = Offset (1/2/4 Werte),
        # optional mit angehängter Fussbodenhöhe (3 oder 5 Werte)
        if current == "raum":
            if row_counts[current] == 1 and count != 3:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "raum" Zeile 1 erwartet 3 Werte '
                    f"(breite,tiefe,hoehe), gefunden: {count}"
                )
                continue
            if row_counts[current] == 2 and count not in {1, 2, 3, 4, 5}:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "raum" Offset-Zeile erwartet 1, 2 oder 4 Werte, '
                    f"optional mit angehängter Fussbodenhöhe (3 oder 5 Werte), "
                    f"gefunden: {count}"
                )
                continue
        elif current == "druck":
            pass  # handled above in non-numeric branch; numeric rows are invalid here

        else:
            allowed_counts = rule.get("counts")
            if allowed_counts and count not in allowed_counts:
                allowed_str = " oder ".join(str(n) for n in sorted(allowed_counts))
                errors.append(
                    f'Zeile {lineno}: Abschnitt "{current}" erwartet {allowed_str} Wert(e) '
                    f"({rule['hint']}), gefunden: {count}"
                )
                continue

        if max_rows and row_counts[current] > max_rows:
            errors.append(
                f'Zeile {lineno}: Abschnitt "{current}" erlaubt maximal '
                f"{max_rows} Datenzeile(n)"
            )
            continue

        sections[current].append(_parse_values(values))

    # Eine Wand braucht zwei Punkte; ein einzelnes Paar ohne Fortsetzung in der
    # Folgezeile ergäbe kein Segment. Benannte Segmente brauchen einen Endpunkt
    # (Segment seg = Punkt[seg]→[seg+1]).
    for e in sections.get("wand", []):
        npts = len(e["pts"])
        if npts < 2:
            errors.append(
                f'Zeile {e["line"]}: einzelnes Koordinatenpaar ohne Fortsetzung '
                f"in der Folgezeile (eine Wand braucht zwei Punkte)"
            )
        for seg, nm in e["names"].items():
            if seg + 1 >= npts:
                errors.append(
                    f'Fensterwand "{nm}": Segment unvollständig (kein Endpunkt)'
                )

    # Nicht angegebene Rotation aus dem Stockwerk auffüllen: jedes ungerade
    # Stockwerk dreht die Platine um 180°. Angaben aus der Datenzeile haben
    # Vorrang. Die Anschlussart folgt nicht aus dem Stockwerk – "idc"/"stack"
    # stehen immer explizit in der Datenzeile.
    floor = _floor_of(sections) or 0
    for row in sections.get("licht", []):
        if row[2] is None:
            row[2] = 180 if floor % 2 else 0
        if row[4] is None:
            row[4] = 0

    if errors:
        raise ValidationError("\n".join(errors))

    return sections


# ── SCAD-Generierung ──────────────────────────────────────────────────────────

def _clip_segment(p1, p2, xmin, xmax, ymin, ymax):
    """Liang-Barsky clip. Returns clipped (p1, p2) or None if entirely outside."""
    x1, y1 = p1
    x2, y2 = p2
    dx, dy = x2 - x1, y2 - y1
    ps = [-dx, dx, -dy, dy]
    qs = [x1 - xmin, xmax - x1, y1 - ymin, ymax - y1]
    t0, t1 = 0.0, 1.0
    for p, q in zip(ps, qs):
        if p == 0:
            if q < 0:
                return None
        elif p < 0:
            t0 = max(t0, q / p)
        else:
            t1 = min(t1, q / p)
    if t0 > t1:
        return None
    r = 3  # decimal places
    return (
        [round(x1 + t0 * dx, r), round(y1 + t0 * dy, r)],
        [round(x1 + t1 * dx, r), round(y1 + t1 * dy, r)],
    )


def _clip_poly_wall(poly, xmin, xmax, ymin, ymax):
    """Clip each segment of every polyline; return list of clipped 2-point segments."""
    for i in range(len(poly) - 1):
        seg = _clip_segment(poly[i], poly[i + 1], xmin, xmax, ymin, ymax)
        if seg:
            return list(seg)



def _poly_walls_val(polys: list) -> str:
    def fmt_poly(pts):
        return "[" + ", ".join(f"[{p[0]},{p[1]}]" for p in pts) + "]"
    return "[" + ", ".join(fmt_poly(p) for p in polys) + "]"


def _named_walls_val(walls: list) -> str:
    """[[x1,y1],[x2,y2],[[x,z,w,h],...]] je benannter Fensterwand."""
    def fmt(wall):
        p1, p2, wins = wall
        w = ", ".join(f"[{v[0]},{v[1]},{v[2]},{v[3]}]" for v in wins)
        return f"[[{p1[0]},{p1[1]}],[{p2[0]},{p2[1]}],[{w}]]"
    return "[" + ", ".join(fmt(x) for x in walls) + "]"


def _vec(items: list) -> str:
    entries = ", ".join(f"[{','.join(str(v) for v in row)}]" for row in items)
    return f"[{entries}]"


def _list1d(values: list) -> str:
    return "[" + ", ".join(str(v) for v in values) + "]"


def _scad_str(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _vec_texts(texts: list) -> str:
    entries = [
        f'["{_scad_str(t[0])}", {t[1]}, {t[2]}, {t[3]}]'
        for t in texts
    ]
    return "[" + ", ".join(entries) + "]"


def _split_wall(entries: list) -> tuple[list, list]:
    """Trennt Öffnungen (4 Werte) von Innenwänden (1 oder 2 Werte).

    Innenwände werden als [pos, laenge] zurückgegeben; laenge=-1 bedeutet auto.
    """
    wins  = [e for e in entries if len(e) == 4]
    walls = [[e[0], e[1] if len(e) == 2 else -1] for e in entries if len(e) in {1, 2}]
    return wins, walls


def _is_null_opening(win: list) -> bool:
    """Breite 0 und Höhe 0 markieren eine massive Wand, keine echte Öffnung.

    Der Eintrag bleibt von der Fussbodenhöhe unberührt, sonst rutschte er ins
    Negative und die Höhenprüfung schlüge an.
    """
    return win[2] == 0 and win[3] == 0


def _win_z(win: list, fussboden: float) -> float:
    """Höhe der Unterkante im Koordinatensystem der Maske."""
    return win[1] if _is_null_opening(win) else win[1] - fussboden


def _normalize_wins(wins: list, wall_len: int | float, fussboden: float = 0) -> list:
    """Rechnet Öffnungen in absolute Maskenkoordinaten für die SCAD-Ausgabe um.

    Negative Offsets werden von der Gegenseite aus aufgelöst, die Höhe um die
    Fussbodenhöhe des Stockwerks verringert.
    """
    result = []
    for win in wins:
        offset, _, size, height = win
        x0, _ = _resolve_opening_x(offset, size, wall_len)
        result.append([x0, _win_z(win, fussboden), size, height])
    return result


def _normalize_walls(walls: list, wall_len: int | float) -> list:
    """Konvertiert negative Positionen von Innenwänden in absolute Werte."""
    return [[wall_len + pos if pos < 0 else pos, laenge] for pos, laenge in walls]


def _normalize_walls_inverted(walls: list, wall_len: int | float) -> list:
    """Wie _normalize_walls, aber gespiegelt (hinten/links: pos=0 = außen-linke Ecke)."""
    result = []
    for pos, laenge in walls:
        abs_pos = wall_len - pos if pos >= 0 else -pos
        result.append([abs_pos, laenge])
    return result


def _normalize_offset(offset_row: list | None) -> tuple[list, float]:
    """Zerlegt die Offset-Zeile in ([vorne, rechts, hinten, links], fussboden).

    Die Fussbodenhöhe steht als letzter Wert hinter der Zwei- oder Vierwertform
    (3 bzw. 5 Werte); ohne sie ist sie 0. Die Einwertform kann sie nicht tragen,
    "2.5,45" wäre die bestehende achsenweise Form.
    """
    if not offset_row:
        return [0, 0, 0, 0], 0
    v = offset_row
    fb = v[4] if len(v) == 5 else v[2] if len(v) == 3 else 0
    if len(v) == 1:
        return [v[0], v[0], v[0], v[0]], fb
    if len(v) in (2, 3):
        # Sonderfall: die Zweiwert-Form ist achsenweise als x,y zu lesen – wie die
        # Maßzeile breite,tiefe. x verkleinert links/rechts, y vorne/hinten.
        return [v[1], v[0], v[1], v[0]], fb
    return list(v[:4]), fb  # 4 oder 5 Werte


_LICHT_W = 41
_LICHT_D = 36

# Gravur der Stockwerksnummer: Rand zur Dachkante und Ziffernbreite bei size=5
_FLOOR_LABEL_W = 3

# Automatikposition eines text-Eintrags ohne Koordinaten: Abstand zur vorderen
# linken Ecke des Druckkörpers, also einschließlich Druckversatz.
_TEXT_AUTO_MARGIN_X = 4.5
_TEXT_AUTO_MARGIN_Y = 1.5


def _resolve_licht_coord(offset, outer_size):
    """Liefert den Mittelpunkt des Ausschnitts. Negativ = Abstand von der rechten/hinteren Kante."""
    if offset >= 0:
        return offset
    return outer_size + offset


def _resolve_poly_point(x, y, w, d):
    """Negative Koordinaten = Abstand von der rechten/hinteren Raumkante."""
    return [w + x if x < 0 else x, d + y if y < 0 else y]


def _resolve_opening_x(offset, size, wall_len):
    """Gibt (start, end) der Öffnung entlang der Wand zurück (negativ = von der anderen Seite)."""
    if offset >= 0:
        return offset, offset + size
    return (wall_len + offset - size), (wall_len + offset)


def _height_error(label, win, room_h, fussboden):
    """Meldung, wenn eine Öffnung nicht in die Wandhöhe passt; sonst None.

    Bei gesetzter Fussbodenhöhe nennt die Meldung beide Bereiche, sonst wäre
    nicht nachvollziehbar, woher die geprüften Zahlen stammen.
    """
    height = win[3]
    z0 = _win_z(win, fussboden)
    if 0 <= z0 and z0 + height <= room_h:
        return None
    herkunft = (f" (Eingabe {win[1]:.4g}–{win[1] + height:.4g} abzüglich "
                f"Fussboden {fussboden:.4g})") if fussboden and not _is_null_opening(win) else ""
    return (f"{label}: Höhe {z0:.4g}–{z0 + height:.4g}{herkunft} "
            f"außerhalb des Raums (0–{room_h})")


def _validate_geometry(sections, w, d, room_h, po_fr, po_ri, po_ba, po_le, fussboden=0):
    errors = []

    wall_dims = {"vorne": w, "hinten": w, "links": d, "rechts": d}
    for sec, horiz in wall_dims.items():
        for idx, e in enumerate(sections.get(sec, []), 1):
            if len(e) != 4:
                continue
            offset, z0, size, height = e
            x0, x1 = _resolve_opening_x(offset, size, horiz)
            if x0 < 0 or x1 > horiz:
                errors.append(
                    f'"{sec}" Öffnung {idx}: horizontale Position {x0:.4g}–{x1:.4g} '
                    f"außerhalb der Wand (0–{horiz})"
                )
            err = _height_error(f'"{sec}" Öffnung {idx}', e, room_h, fussboden)
            if err:
                errors.append(err)

    _LICHT_MARGIN = 2  # mm Mindestabstand zur Körperkante
    for idx, row in enumerate(sections.get("licht", []), 1):
        if row[0] != 0:
            cx = _resolve_licht_coord(row[0], w)
            lx = cx - _LICHT_W / 2
            if lx < _LICHT_MARGIN or lx + _LICHT_W > w - _LICHT_MARGIN:
                errors.append(
                    f'"licht" {idx}: X {lx}–{lx + _LICHT_W} muss mindestens {_LICHT_MARGIN}mm '
                    f"innerhalb des Körpers liegen ({_LICHT_MARGIN}–{w - _LICHT_MARGIN})"
                )
        if row[1] != 0:
            cy = _resolve_licht_coord(row[1], d)
            ly = cy - _LICHT_D / 2
            if ly < _LICHT_MARGIN or ly + _LICHT_D > d - _LICHT_MARGIN:
                errors.append(
                    f'"licht" {idx}: Y {ly}–{ly + _LICHT_D} muss mindestens {_LICHT_MARGIN}mm '
                    f"innerhalb des Körpers liegen ({_LICHT_MARGIN}–{d - _LICHT_MARGIN})"
                )

    for idx, row in enumerate(sections.get("dach", []), 1):
        if len(row) >= 4:
            x, y, bw, bd = row[0], row[1], row[2], row[3]
            if x < 0 or x + bw > w:
                errors.append(f'"dach" {idx}: X {x}–{x + bw} außerhalb des Raums (0–{w})')
            if y < 0 or y + bd > d:
                errors.append(f'"dach" {idx}: Y {y}–{y + bd} außerhalb des Raums (0–{d})')
        else:
            # LED-Öffnung: Mitte cx,cy; max. Öffnungsradius _DACH_LED_R
            cx, cy = row[0], row[1]
            r = _DACH_LED_R
            if cx - r < 0 or cx + r > w:
                errors.append(f'"dach" {idx}: X {cx} (±{r}) außerhalb des Raums (0–{w})')
            if cy - r < 0 or cy + r > d:
                errors.append(f'"dach" {idx}: Y {cy} (±{r}) außerhalb des Raums (0–{d})')

    return errors


def generate_box_scad(sections: dict) -> str:
    """Erzeugt die box_data.scad-Daten für den Lichtbox-Renderer (lightbox.scad).

    Diese Datei setzt box_dims/box_open/box_leds und bindet anschließend
    lightbox.scad ein, das daraus das Modell rendert.
    """
    w, h, d = sections["box"][0]

    errors: list[str] = []
    mounts: list = []
    for sec, face in BOX_FACES.items():
        for led, clip, off1, off2 in sections.get(sec, []):
            # off1 = entlang der Vorderkante, off2 = in Z-Richtung (Tiefe).
            # FACE_TOP:        u = Breite (X), v = Tiefe (Z)  → [off1, off2]
            # FACE_LEFT/RIGHT: u = Tiefe (Z),  v = Höhe  (Y)  → [off2, off1]
            if face == 0:  # FACE_TOP
                u, v = off1, off2
                lim_u, lim_v = w, d
            else:          # FACE_LEFT / FACE_RIGHT
                u, v = off2, off1
                lim_u, lim_v = d, h
            if abs(u) > lim_u / 2 - _BOX_LED_MARGIN or abs(v) > lim_v / 2 - _BOX_LED_MARGIN:
                errors.append(
                    f'Abschnitt "{sec}": LED-Offset ({off1},{off2}) liegt außerhalb der '
                    f"Fläche oder näher als {_BOX_LED_MARGIN}mm an der Kante"
                )
                continue
            mounts.append([face, led, u, v, clip])

    if errors:
        raise ValidationError("\n".join(errors))

    lines = [
        f"box_dims = [{w}, {h}, {d}];",
        "box_open = 0;",
        f"box_leds = {_vec(mounts)};",
        "include <lightbox.scad>;",
    ]
    return "\n".join(lines)


def generate_scad(sections: dict) -> str:
    if "box" in sections:
        return generate_box_scad(sections)

    raum_rows = sections.get("raum", [[100, 80, 30]])
    w, d, room_h = raum_rows[0]
    offset, fussboden = _normalize_offset(raum_rows[1] if len(raum_rows) > 1 else None)

    druck      = {row[0]: row[1] for row in sections.get("druck", [])}
    wand       = druck.get("wand",   0.8)
    aussenwand = druck.get("aussen", wand)
    innenwand  = druck.get("innen",  wand)
    dachwand   = druck.get("dach",   1.0)

    po_fr, po_ri, po_ba, po_le = offset

    geo_errors = _validate_geometry(sections, w, d, room_h, po_fr, po_ri, po_ba, po_le,
                                    fussboden)
    if geo_errors:
        raise ValidationError("\n".join(geo_errors))

    # wand-Einträge: je Polygonzug jedes Segment einzeln behandeln. Benanntes
    # Segment mit Fenster-Abschnitt → named_walls (gerade Fensterwand); alle
    # übrigen Segmente → poly_walls (freie Innenwände, geklippt).
    named_walls = []
    poly_walls = []
    geo_errors2 = []
    for e in sections.get("wand", []):
        pts = [_resolve_poly_point(p[0], p[1], w, d) for p in e["pts"]]
        names = e["names"]
        for i in range(len(pts) - 1):
            seg = [pts[i], pts[i + 1]]
            nm = names.get(i)
            wins = sections.get(nm) if nm else None
            if nm and wins:
                (x1, y1), (x2, y2) = seg
                wall_len = math.hypot(x2 - x1, y2 - y1)
                for k, win in enumerate(wins, 1):
                    wx, wz, ww, wh = win
                    if wx < 0 or wx + ww > wall_len:
                        geo_errors2.append(
                            f'Fensterwand "{nm}" Öffnung {k}: {wx:.4g}–{wx+ww:.4g} '
                            f"außerhalb der Wandlänge (0–{wall_len:.4g})"
                        )
                    err = _height_error(f'Fensterwand "{nm}" Öffnung {k}',
                                        win, room_h, fussboden)
                    if err:
                        geo_errors2.append(err)
                cords = _clip_poly_wall([seg[0], seg[1]], po_le, w - po_ri, po_fr, d - po_ba)
                if cords:
                    # Fenster der Innenwände genauso auf Maskenkoordinaten bringen
                    # wie die der Außenwände; die x-Position ist hier immer absolut.
                    cords.append([[win[0], _win_z(win, fussboden), win[2], win[3]]
                                  for win in wins])
                    named_walls.append(cords)
            else:
                # Vollständig außerhalb liegende Segmente liefern None und
                # entfallen, statt als leerer Eintrag in die SCAD-Liste zu gehen.
                cords = _clip_poly_wall(seg, po_le, w - po_ri, po_fr, d - po_ba)
                if cords:
                    poly_walls.append(cords)
    if geo_errors2:
        raise ValidationError("\n".join(geo_errors2))

    inner_w = w - po_le - po_ri
    inner_d = d - po_fr - po_ba

    # Wände zuerst normalisieren – Positionen werden für optimale licht-Platzierung benötigt
    front_wins, front_walls = _split_wall(sections.get("vorne",  []))
    back_wins,  back_walls  = _split_wall(sections.get("hinten", []))
    left_wins,  left_walls  = _split_wall(sections.get("links",  []))
    right_wins, right_walls = _split_wall(sections.get("rechts", []))

    front_wins = _normalize_wins(front_wins, w, fussboden)
    back_wins  = _normalize_wins(back_wins,  w, fussboden)
    left_wins  = _normalize_wins(left_wins,  d, fussboden)
    right_wins = _normalize_wins(right_wins, d, fussboden)

    front_walls = _normalize_walls(front_walls,          w)
    back_walls  = _normalize_walls_inverted(back_walls,  w)
    left_walls  = _normalize_walls_inverted(left_walls,  d)
    right_walls = _normalize_walls(right_walls,          d)

    # Auto-Position: geometrische Mitte des Innenraums; Fallback für "0"-Koordinaten
    lx_auto = po_le + inner_w / 2
    ly_auto = po_fr + inner_d / 2
    lx_auto = max(po_le + _LICHT_W / 2, min(lx_auto, w - po_ri - _LICHT_W / 2))
    ly_auto = max(po_fr + _LICHT_D / 2, min(ly_auto, d - po_ba - _LICHT_D / 2))

    floor = _floor_of(sections)

    licht_rows = sections.get("licht")
    if licht_rows is None:
        licht_val = "[]"
    elif len(licht_rows) == 0:
        # Abschnitt ohne Datenzeilen (ggf. nur mit "G<n>") → zentrierte Platine
        # ohne Anschluss; "idc"/"stack" braucht eine eigene Datenzeile.
        auto_rot = 180 if floor and floor % 2 else 0
        licht_val = f"[[{lx_auto},{ly_auto},{auto_rot},0,0]]"
    else:
        # Mittelpunkt des Ausschnitts; 0 = automatisch; negativ = Abstand von rechts/hinten
        entries = [
            [
                lx_auto if row[0] == 0 else _resolve_licht_coord(row[0], w),
                ly_auto if row[1] == 0 else _resolve_licht_coord(row[1], d),
                row[2],
                row[3],
                row[4],
            ]
            for row in licht_rows
        ]
        licht_val = _vec(entries)

    # dach-Eintrag: [x,y,breite,tiefe] (Rechteck) oder [cx,cy,led] (LED-Typ)
    dach_cuts = [list(row) for row in sections.get("dach", [])]

    # Ein text-Eintrag ohne Koordinaten sitzt 3x3mm von der vorderen linken Ecke
    # des Druckkörpers, wandert also mit dem Druckversatz.
    text_rows = [
        [
            t[0],
            po_le + _TEXT_AUTO_MARGIN_X if t[1] is None else t[1],
            po_fr + _TEXT_AUTO_MARGIN_Y if t[2] is None else t[2],
            t[3],
        ]
        for t in sections.get("text", [])
    ]
    if floor is not None:
        # Stockwerksnummer in die vordere rechte Ecke der Dachfläche gravieren;
        # text() setzt an der Grundlinie links an, deshalb um eine Ziffernbreite
        # von der rechten Kante einrücken.
        text_rows.append([
            str(floor),
            w - po_ri - _TEXT_AUTO_MARGIN_X - _FLOOR_LABEL_W,
            po_fr + _TEXT_AUTO_MARGIN_Y,
            0,
        ])

    lines = [
        f"room_width   = {w};",
        f"room_depth   = {d};",
        f"room_height  = {room_h};",
        f"licht_w      = {_LICHT_W};",
        f"licht_d      = {_LICHT_D};",
        f"wand         = {wand};",
        f"aussenwand   = {aussenwand};",
        f"innenwand    = {innenwand};",
        f"dachwand     = {dachwand};",
        f"poly_walls   = {_poly_walls_val(poly_walls)};",
        f"named_walls  = {_named_walls_val(named_walls)};",
        f"print_offset = {_list1d(offset)};",
        f"front_windows = {_vec(front_wins)};",
        f"back_windows  = {_vec(back_wins)};",
        f"left_windows  = {_vec(left_wins)};",
        f"right_windows = {_vec(right_wins)};",
        f"geschoss = {-1 if floor is None else floor};",
        f"licht = {licht_val};",
        f"dach_cuts = {_vec(dach_cuts)};",
        f"front_walls = {_vec(front_walls)};",
        f"back_walls  = {_vec(back_walls)};",
        f"left_walls  = {_vec(left_walls)};",
        f"right_walls = {_vec(right_walls)};",
        f"texts = {_vec_texts(text_rows)};",
    ]
    return "\n".join(lines)


def csv_to_scad(text: str) -> str:
    return generate_scad(validate_and_parse(text))


# ── Vorlagen aus dem data-Ordner ──────────────────────────────────────────────
# Die Oberfläche bietet alle CSV-Dateien unterhalb von data/ als Baum an. Die
# Liste steckt im ausgelieferten HTML, den Inhalt holt der Browser einzeln über
# GET /sample nach.

def _sample_sort_key(rel: str):
    # Komponentenweise sortieren, Groß-/Kleinschreibung egal.
    return [(part.casefold(), part) for part in rel.split("/")]


def list_samples() -> list[str]:
    """Relative Pfade aller CSV-Dateien unter data/, sortiert.

    Fehlt der Ordner, ist die Liste leer – die Oberfläche blendet das Menü dann
    aus. Versteckte Dateien und Ordner bleiben außen vor; os.walk folgt keinen
    Verzeichnis-Symlinks.
    """
    out: list[str] = []
    if not os.path.isdir(DATA_DIR):
        return out
    for root, dirs, files in os.walk(DATA_DIR):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.startswith(".") or not name.lower().endswith(".csv"):
                continue
            rel = os.path.relpath(os.path.join(root, name), DATA_DIR)
            out.append(rel.replace(os.sep, "/"))
    out.sort(key=_sample_sort_key)
    return out


def read_sample(rel: str) -> tuple[str | None, str | None]:
    """Inhalt einer Vorlage lesen. Rückgabe: (inhalt, fehler).

    Der angefragte Pfad muss exakt in der frisch gescannten Liste stehen. Damit
    kann keine Eingabe aus dem Ordner herausführen – '..', absolute Pfade oder
    kodierte Varianten sind nie Mitglied der Menge. Der Pfad wird anschließend
    aus den Komponenten neu zusammengesetzt, nicht aus dem Client-String.
    """
    if not rel or rel not in set(list_samples()):
        return None, "Unbekannte Datei."
    full = os.path.realpath(os.path.join(DATA_DIR, *rel.split("/")))
    # Ein Symlink auf eine Datei steht legitim in der Liste, darf aber nicht aus
    # dem Vorlagenordner herauszeigen.
    if not full.startswith(os.path.realpath(DATA_DIR) + os.sep) or not os.path.isfile(full):
        return None, "Unbekannte Datei."
    if os.path.getsize(full) > MAX_SAMPLE_BYTES:
        return None, "Datei zu groß."
    with open(full, encoding="utf-8", errors="replace") as f:
        return f.read(), None


# ── HTTP-Server ───────────────────────────────────────────────────────────────

def _load_template() -> str:
    with open(os.path.join(BASE_DIR, "index.html"), encoding="utf-8") as f:
        return f.read()


def _render(csv_text: str = "") -> str:
    # Erst die Vorlagenliste, dann den Definitionstext: csv_text stammt im
    # Fehlerfall aus der Eingabe des Nutzers und darf keinen Platzhalter mehr
    # auslösen. Die spitzen Klammern werden escaped, damit ein Dateiname das
    # umgebende script-Element nicht beenden kann.
    samples = (json.dumps(list_samples(), ensure_ascii=False)
               .replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026"))
    return (_load_template()
            .replace("{{samples}}", samples)
            .replace("{{csv}}", csv_text))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(fmt % args)

    def _security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")

    def _send(self, status: int, content_type: str, body):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self._security_headers()
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/sample":
            self._send_sample(parsed.query)
            return
        # Jeder andere Pfad liefert die Seite.
        self._send(200, "text/html; charset=utf-8", _render())

    def _send_sample(self, query: str):
        ip = self.client_address[0]
        if not _rate_ok(f"{ip}|sample", SAMPLE_LIMIT):
            self._send(429, "text/plain; charset=utf-8", "Zu viele Anfragen – bitte warten.")
            return
        rel = parse_qs(query).get("path", [""])[0]
        if len(rel) > MAX_SAMPLE_PATH:
            self._send(413, "text/plain; charset=utf-8", "Anfrage zu groß.")
            return
        content, error = read_sample(rel)
        if error:
            # Der angefragte Pfad steht bewusst nicht in der Antwort.
            logger.warning("Vorlage abgelehnt: %s", error)
            self._send(422, "text/plain; charset=utf-8", error)
        else:
            self._send(200, "text/plain; charset=utf-8", content)

    def _read_csv(self) -> str | None:
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            self._send(413, "text/plain; charset=utf-8", "Anfrage zu groß (max 4 KB)")
            return None
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        return parse_qs(body).get("csv", [""])[0]

    def _generate_model(self, csv_content: str, out_ext: str = "stl") -> tuple:
        try:
            sections  = validate_and_parse(csv_content)
            scad_data = generate_scad(sections)
        except ValidationError as e:
            return None, str(e)

        # "box"-Modus rendert mit lightbox.scad; box_data.scad bindet den Renderer
        # selbst ein und ist damit das OpenSCAD-Eingabefile.
        is_box = "box" in sections

        tmpdir = tempfile.mkdtemp(prefix="hausmaske_")
        try:
            stl_path = os.path.join(tmpdir, f"out.{out_ext}")
            if is_box:
                data_scad   = os.path.join(tmpdir, "box_data.scad")
                renderer    = os.path.join(tmpdir, "lightbox.scad")
                render_main = data_scad
                renderer_src = LIGHTBOX_SCAD
            else:
                data_scad   = os.path.join(tmpdir, "house_data.scad")
                renderer    = os.path.join(tmpdir, "house_mask.scad")
                render_main = renderer
                renderer_src = MASK_SCAD

            with open(data_scad, "w", encoding="utf-8") as f:
                f.write(scad_data)
            if DEBUG:
                name = os.path.basename(data_scad)
                print(f"── {name} ──\n{scad_data}\n── Ende {name} ──", flush=True)
            shutil.copy(renderer_src, renderer)

            try:
                r = subprocess.run(
                    ["openscad", "-o", stl_path, render_main],
                    capture_output=True, text=True, cwd=tmpdir,
                    timeout=60,
                )
            except subprocess.TimeoutExpired:
                logger.error("OpenSCAD timeout nach 60s")
                return None, "STL-Generierung abgebrochen (Timeout)."
            if r.returncode != 0 or not os.path.exists(stl_path):
                logger.error("OpenSCAD Fehler: %s", r.stderr)
                return None, "STL-Generierung fehlgeschlagen. Bitte Eingabe prüfen."

            with open(stl_path, "rb") as f:
                return f.read(), None
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def do_POST(self):
        ip = self.client_address[0]
        if not _rate_ok(ip):
            self._send(429, "text/plain; charset=utf-8", "Zu viele Anfragen – bitte warten.")
            return

        csv_content = self._read_csv()
        if csv_content is None:
            return

        if self.path == "/export3mf":
            data, error = self._generate_model(csv_content, "3mf")
            if error:
                self._send(422, "text/plain; charset=utf-8", error)
            else:
                self.send_response(200)
                self.send_header("Content-Type", "model/3mf")
                self.send_header("Content-Disposition", 'attachment; filename="house_mask.3mf"')
                self.send_header("Content-Length", str(len(data)))
                self._security_headers()
                self.end_headers()
                self.wfile.write(data)
            return

        stl_data, error = self._generate_model(csv_content, "stl")

        if self.path == "/preview":
            if error:
                self._send(422, "text/plain; charset=utf-8", error)
            else:
                self._send(200, "model/stl", stl_data)
        else:
            if error:
                block = f'<div class="error">{h.escape(error)}</div>'
                page = _render(h.escape(csv_content)).replace("{{error}}", block)
                self._send(422, "text/html; charset=utf-8", page)
            else:
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", 'attachment; filename="house_mask.stl"')
                self.send_header("Content-Length", str(len(stl_data)))
                self._security_headers()
                self.end_headers()
                self.wfile.write(stl_data)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    DEBUG = "--debug" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--debug"]

    if len(args) >= 2 and args[0] == "--parse":
        with open(args[1], encoding="utf-8") as f:
            text = f.read()
        try:
            print(csv_to_scad(text))
        except ValidationError as e:
            print(f"Fehler:\n{e}", file=sys.stderr)
            sys.exit(1)
    else:
        addr = ("", 8080)
        httpd = HTTPServer(addr, Handler)
        print("Hausmasken-Generator läuft auf http://localhost:8080"
              + (" (debug)" if DEBUG else ""))
        httpd.serve_forever()
