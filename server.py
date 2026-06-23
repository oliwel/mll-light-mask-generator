#!/usr/bin/env python3
"""
Hausmasken-Generator — Webserver + CSV-Parser + Validierung in einer Datei.

CSV-Format:
  # Kommentar (wird verworfen)
  raum
  breite,tiefe,hoehe              (genau 3 Werte)
  offset                          (optional: 1/2/4 Werte → alle/x+y/vorne,rechts,hinten,links)
  druck
  wand,0.8                        (Wandstärke; weitere Druckparameter als schluessel,wert)
  wand
  x1,y1,x2,y2[,...,xn,yn]        (4–12 Werte: freie Innenwand als Eckpunktzug)
  vorne|hinten|links|rechts
  x,y,breite,hoehe                (Fenster/Tür – 4 Werte)
  pos                             (Innenwand-Ansatz – 1 Wert, auto-Länge)
  pos,laenge                      (Innenwand mit expliziter Länge – 2 Werte)
  licht
  x,y[,rotation][,weiter|ende]   (2–3 Werte, absolut vom Körperursprung 0,0; negativ = von rechts/hinten)
  dach
  x,y,breite,tiefe               (4 Werte, absolut vom Körperursprung 0,0)
  text
  Text                            (1 Wert: Text an Position 5,5)
  x,y,Text                        (3 Werte: Text an x,y)
  x,y,rotation,Text               (4 Werte: Text an x,y mit Rotation)

Standalone: python3 server.py --parse sample.csv > house_data.scad
Server:     python3 server.py
"""

import csv as csv_module
import html as h
import io
import logging
import math
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

MAX_BODY = 4 * 1024  # 4 KB

_rate_lock = threading.Lock()
_rate_data: dict[str, list[float]] = defaultdict(list)
RATE_WINDOW = 60   # Sekunden
RATE_LIMIT   = 10  # POST-Anfragen pro Minute pro IP


def _rate_ok(ip: str) -> bool:
    now = time.time()
    with _rate_lock:
        ts = [t for t in _rate_data[ip] if now - t < RATE_WINDOW]
        if len(ts) >= RATE_LIMIT:
            return False
        ts.append(now)
        _rate_data[ip] = ts
        return True

BASE_DIR  = os.path.dirname(os.path.abspath(__file__))
MASK_SCAD = os.path.join(BASE_DIR, "house_mask.scad")

KNOWN_SECTIONS = {"raum", "wand", "vorne", "hinten", "links", "rechts", "licht", "dach", "druck", "text"}
DRUCK_KEYS     = {"wand", "aussen", "innen", "dach"}

_RULES = {
    "raum":   {"counts": {3},       "max_rows": 2, "hint": "breite,tiefe,hoehe  [offset]"},
    "wand":   {"hint": "x1,y1,x2,y2[,...,xn,yn]"},
    "druck":  {"hint": "schluessel,wert  (z.B. wand,0.8)"},
    "licht":  {"hint": "x,y[,rotation][,weiter|ende]"},
    "dach":   {"counts": {4},       "hint": "x,y,breite,tiefe"},
    "text":   {"hint": "Text  |  x,y,Text  |  x,y,rotation,Text"},
    "vorne":  {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
    "hinten": {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
    "links":  {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
    "rechts": {"counts": {1, 2, 4}, "hint": "x,y,breite,hoehe  |  pos  |  pos,laenge"},
}


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


def validate_and_parse(text: str) -> dict:
    errors = []
    sections: dict = {}
    current: str | None = None
    row_counts: dict[str, int] = {}

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
            if current == "text" and keyword not in KNOWN_SECTIONS:
                pass  # Textinhalt: nicht-numerische Zeile als Datum durchfallen lassen
            elif keyword not in KNOWN_SECTIONS:
                errors.append(
                    f'Zeile {lineno}: Unbekanntes Schlüsselwort "{first}" - '
                    f"erlaubt: {', '.join(sorted(KNOWN_SECTIONS))}"
                )
                continue
            else:
                current = keyword
                sections.setdefault(current, [])
                row_counts.setdefault(current, 0)
                continue

        if current is None:
            errors.append(f"Zeile {lineno}: Datenwerte vor dem ersten Abschnitts-Schlüsselwort")
            continue

        values = [c for c in row if c]

        # licht-Abschnitt: optionales Keyword als letztes Feld; "0" = automatisch
        if current == "licht":
            _SLOT_KW = {"weiter": 1, "ende": 2}
            slot_mode = 0
            vals = list(values)
            if vals and vals[-1].lower() in _SLOT_KW:
                slot_mode = _SLOT_KW[vals[-1].lower()]
                vals = vals[:-1]
            # Einzelner Wert "0" → Autopositionierung für beide Achsen
            if vals == ["0"]:
                row_counts[current] += 1
                sections[current].append([0, 0, 0, slot_mode])
                continue
            count = len(vals)
            if count not in {2, 3}:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "licht" erwartet 2 oder 3 Werte '
                    f"(x,y[,rotation][,weiter|ende]), gefunden: {count}"
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
                [nums[0], nums[1], nums[2] if len(nums) >= 3 else 0, slot_mode]
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
                entry = [text_val, 5, 5, 0]
            elif len(nums) == 2:
                entry = [text_val, nums[0], nums[1], 0]
            else:
                entry = [text_val, nums[0], nums[1], nums[2]]
            sections[current].append(entry)
            continue

        bad = [v for v in values if not _numeric(v)]
        if bad:
            errors.append(f"Zeile {lineno}: Nicht-numerische Werte: {', '.join(bad)}")
            continue

        rule = _RULES.get(current, {})
        count = len(values)

        max_rows = rule.get("max_rows")
        row_counts[current] += 1

        # "raum": erste Zeile = 3 Werte, zweite Zeile = Offset (1/2/4 Werte)
        if current == "raum":
            if row_counts[current] == 1 and count != 3:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "raum" Zeile 1 erwartet 3 Werte '
                    f"(breite,tiefe,hoehe), gefunden: {count}"
                )
                continue
            if row_counts[current] == 2 and count not in {1, 2, 4}:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "raum" Offset-Zeile erwartet 1, 2 oder 4 Werte, '
                    f"gefunden: {count}"
                )
                continue
        elif current == "wand":
            if count % 2 != 0 or count < 4 or count > 20:
                errors.append(
                    f'Zeile {lineno}: Abschnitt "wand" erwartet 2 bis 10 Punktpaare'
                    f"(x1,y1,x2,y2,...), gefunden: {count}"
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


def _clip_poly_walls(polys, xmin, xmax, ymin, ymax):
    """Clip each segment of every polyline; return list of clipped 2-point segments."""
    out = []
    for poly in polys:
        for i in range(len(poly) - 1):
            seg = _clip_segment(poly[i], poly[i + 1], xmin, xmax, ymin, ymax)
            if seg:
                out.append(list(seg))
    return out


def _poly_walls_val(polys: list) -> str:
    def fmt_poly(pts):
        return "[" + ", ".join(f"[{p[0]},{p[1]}]" for p in pts) + "]"
    return "[" + ", ".join(fmt_poly(p) for p in polys) + "]"


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


def _normalize_wins(wins: list, wall_len: int | float) -> list:
    """Konvertiert negative Offsets in absolute Positionen für die SCAD-Ausgabe."""
    result = []
    for offset, z0, size, height in wins:
        x0, _ = _resolve_opening_x(offset, size, wall_len)
        result.append([x0, z0, size, height])
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


def _normalize_offset(offset_row: list | None) -> list:
    """Normalisiert print_offset auf [vorne, rechts, hinten, links]."""
    if not offset_row:
        return [0, 0, 0, 0]
    v = offset_row
    if len(v) == 1:
        return [v[0], v[0], v[0], v[0]]
    if len(v) == 2:
        return [v[0], v[1], v[0], v[1]]
    return list(v)  # already 4


_LICHT_W = 41
_LICHT_D = 36


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


def _validate_geometry(sections, w, d, room_h, po_fr, po_ri, po_ba, po_le):
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
            if z0 < 0 or z0 + height > room_h:
                errors.append(
                    f'"{sec}" Öffnung {idx}: Höhe {z0}–{z0 + height} '
                    f"außerhalb des Raums (0–{room_h})"
                )

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
        x, y, bw, bd = row[0], row[1], row[2], row[3]
        if x < 0 or x + bw > w:
            errors.append(f'"dach" {idx}: X {x}–{x + bw} außerhalb des Raums (0–{w})')
        if y < 0 or y + bd > d:
            errors.append(f'"dach" {idx}: Y {y}–{y + bd} außerhalb des Raums (0–{d})')

    return errors


def generate_scad(sections: dict) -> str:
    raum_rows = sections.get("raum", [[100, 80, 30]])
    w, d, room_h = raum_rows[0]
    offset = _normalize_offset(raum_rows[1] if len(raum_rows) > 1 else None)

    druck      = {row[0]: row[1] for row in sections.get("druck", [])}
    wand       = druck.get("wand",   0.8)
    aussenwand = druck.get("aussen", wand)
    innenwand  = druck.get("innen",  wand)
    dachwand   = druck.get("dach",   1.0)

    po_fr, po_ri, po_ba, po_le = offset

    geo_errors = _validate_geometry(sections, w, d, room_h, po_fr, po_ri, po_ba, po_le)
    if geo_errors:
        raise ValidationError("\n".join(geo_errors))

    poly_wall_rows = sections.get("wand", [])
    poly_walls_raw = [
        [_resolve_poly_point(row[i], row[i+1], w, d) for i in range(0, len(row), 2)]
        for row in poly_wall_rows
    ]
    poly_walls = _clip_poly_walls(poly_walls_raw, po_le, w - po_ri, po_fr, d - po_ba)

    inner_w = w - po_le - po_ri
    inner_d = d - po_fr - po_ba

    # Wände zuerst normalisieren – Positionen werden für optimale licht-Platzierung benötigt
    front_wins, front_walls = _split_wall(sections.get("vorne",  []))
    back_wins,  back_walls  = _split_wall(sections.get("hinten", []))
    left_wins,  left_walls  = _split_wall(sections.get("links",  []))
    right_wins, right_walls = _split_wall(sections.get("rechts", []))

    front_wins = _normalize_wins(front_wins, w)
    back_wins  = _normalize_wins(back_wins,  w)
    left_wins  = _normalize_wins(left_wins,  d)
    right_wins = _normalize_wins(right_wins, d)

    front_walls = _normalize_walls(front_walls,          w)
    back_walls  = _normalize_walls_inverted(back_walls,  w)
    left_walls  = _normalize_walls_inverted(left_walls,  d)
    right_walls = _normalize_walls(right_walls,          d)

    # Auto-Position: geometrische Mitte des Innenraums; Fallback für "0"-Koordinaten
    lx_auto = po_le + inner_w / 2
    ly_auto = po_fr + inner_d / 2
    lx_auto = max(po_le + _LICHT_W / 2, min(lx_auto, w - po_ri - _LICHT_W / 2))
    ly_auto = max(po_fr + _LICHT_D / 2, min(ly_auto, d - po_ba - _LICHT_D / 2))

    licht_rows = sections.get("licht")
    if licht_rows is None:
        licht_val = "[]"
    elif len(licht_rows) == 0:
        licht_val = f"[[{lx_auto},{ly_auto},0,0]]"
    else:
        # Mittelpunkt des Ausschnitts; 0 = automatisch; negativ = Abstand von rechts/hinten
        entries = [
            [
                lx_auto if row[0] == 0 else _resolve_licht_coord(row[0], w),
                ly_auto if row[1] == 0 else _resolve_licht_coord(row[1], d),
                row[2],
                row[3],
            ]
            for row in licht_rows
        ]
        licht_val = _vec(entries)

    dach_rows = sections.get("dach", [])
    dach_cuts = [[row[0], row[1], row[2], row[3]] for row in dach_rows]

    text_rows = sections.get("text", [])

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
        f"print_offset = {_list1d(offset)};",
        f"front_windows = {_vec(front_wins)};",
        f"back_windows  = {_vec(back_wins)};",
        f"left_windows  = {_vec(left_wins)};",
        f"right_windows = {_vec(right_wins)};",
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


# ── HTTP-Server ───────────────────────────────────────────────────────────────

def _load_template() -> str:
    with open(os.path.join(BASE_DIR, "index.html"), encoding="utf-8") as f:
        return f.read()


def _render(csv_text: str = "") -> str:
    return _load_template().replace("{{csv}}", csv_text)


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
        self._send(200, "text/html; charset=utf-8", _render())

    def _read_csv(self) -> str | None:
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            self._send(413, "text/plain; charset=utf-8", "Anfrage zu groß (max 4 KB)")
            return None
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        return parse_qs(body).get("csv", [""])[0]

    def _generate_stl(self, csv_content: str) -> tuple:
        try:
            scad_data = csv_to_scad(csv_content)
        except ValidationError as e:
            return None, str(e)

        tmpdir = tempfile.mkdtemp(prefix="hausmaske_")
        try:
            data_scad = os.path.join(tmpdir, "house_data.scad")
            mask_scad = os.path.join(tmpdir, "house_mask.scad")
            stl_path  = os.path.join(tmpdir, "house_mask.stl")

            with open(data_scad, "w", encoding="utf-8") as f:
                f.write(scad_data)
            shutil.copy(MASK_SCAD, mask_scad)

            try:
                r = subprocess.run(
                    ["openscad", "-o", stl_path, mask_scad],
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

        stl_data, error = self._generate_stl(csv_content)

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
    if len(sys.argv) >= 3 and sys.argv[1] == "--parse":
        with open(sys.argv[2], encoding="utf-8") as f:
            text = f.read()
        try:
            print(csv_to_scad(text))
        except ValidationError as e:
            print(f"Fehler:\n{e}", file=sys.stderr)
            sys.exit(1)
    else:
        addr = ("", 8080)
        httpd = HTTPServer(addr, Handler)
        print("Hausmasken-Generator läuft auf http://localhost:8080")
        httpd.serve_forever()
