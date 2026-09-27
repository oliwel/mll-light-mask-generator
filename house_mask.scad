// Hausmaske mit Fenster- und Türöffnungen aus CSV-Daten
// Aufruf: python3 server.py --parse sample.csv > house_data.scad
// Dann diese Datei in OpenSCAD öffnen.

include <house_data.scad>

// ── Konstanten ────────────────────────────────────────────────────────────────
licht_h = 1.2; // Einstecktiefe Lichtausschnitt von Dachoberkante [mm]
tunnel_w   = 15;   // Tunnel Innenbreite (X) [mm]
tunnel_d   = 9;    // Tunnel Innentiefe  (Y) [mm]
tunnel_wall = 1.2; // Tunnel Wandstärke

// ── LED-Öffnungen im Dach (portiert aus lightbox.scad) ──────────────────────────
// Öffnungstyp (dach_cuts-Eintrag [cx, cy, led]). Bestimmt die komplette
// Öffnungsgeometrie; wird anstelle der Ausschnitt-Masse (breite,tiefe) übergeben.
// Zweiteilige Öffnungen sind durchgehend: das größere Feature (LED-Tasche) sitzt auf
// der Dachoberseite, das kleine Feature (Lichtaustritt) liegt led_membrane (0.4mm)
// tief auf der Rauminnenseite (Platzierung dreht die kanonische Lage um 180°).
LED_NONE   = 0; // keine Öffnung
LED_3MM    = 1; // durchgehender Zylinder 3mm
LED_5MM    = 2; // durchgehender Zylinder 5mm
LED_5050   = 3; // Licht Zylinder 4mm, Tasche 6x6mm
LED_3528   = 4; // Licht Zylinder 3mm, Tasche 4x3mm
LED_WS2812 = 5; // Licht Ausschnitt 6x6mm, Tasche Zylinder 11mm

led_membrane = 0.4; // verbleibende Materialdicke auf der Lichtaustrittsseite [mm]

/*
 * Einzelnes Feature einer Öffnung, zentriert um z = 0, Höhe h.
 *   shape als Vektor [x,y]  -> quadratischer Ausschnitt
 *   shape als Zahl d        -> Zylinder mit Durchmesser d
 */
module led_feature( shape, h ) {
    if (is_list(shape))
        cube([shape[0], shape[1], h], true);
    else
        cylinder(d = shape, h = h, center = true, $fn = 48);
}

/*
 * Negativform der LED-Öffnung in kanonischer Lage:
 *   Wandmitte liegt bei z = 0, die Wand (Dicke wall) reicht von -wall/2 bis +wall/2;
 *   +z zeigt zur Lichtaustrittsseite (Dachoberseite).
 *   through  = durchgehender Zylinder (Durchmesser) über die ganze Dachdicke
 *   inner    = kleines Feature an der Lichtaustrittsseite, led_membrane (0.4mm) tief
 *   outer    = LED-Tasche auf der Rauminnenseite, restliche Dachdicke
 */
module led_negative( wall, inner = undef, outer = undef, through = undef ) {
    eps = 0.1 * wall; // Überstand gegen Rendering-Fehler an den Flächen
    if (!is_undef(through))
        cylinder(d = through, h = wall + 2*eps, center = true, $fn = 48);
    if (!is_undef(inner))
        translate([0, 0, (wall - led_membrane + eps)/2])
            led_feature(inner, led_membrane + eps);
    if (!is_undef(outer))
        translate([0, 0, -led_membrane/2])
            led_feature(outer, wall - led_membrane + 2*eps);
}

/*
 * Negativform der LED-Öffnung nach Öffnungstyp (kanonische Lage, +z = Oberseite).
 * wall = Dachdicke.
 */
module led_negative_by_type( led, wall ) {
    if (led == LED_3MM)         led_negative(wall, through = 3);
    else if (led == LED_5MM)    led_negative(wall, through = 5);
    else if (led == LED_5050)   led_negative(wall, inner = 4,     outer = [6,6]);
    else if (led == LED_3528)   led_negative(wall, inner = 3,     outer = [4,3]);
    else if (led == LED_WS2812) led_negative(wall, inner = [6,6], outer = 11);
}


// ── 6-polige IDC-Buchse (2×3, 2,54 mm Raster) ───────────────────────────────────
// Aufnahmetasche für eine weibliche IDC-Pfostenbuchse (Flachbandkabel-Stecker,
// FC-6P). Die Tasche öffnet nach z = 0, sitzt im rechten Tunnelabschnitt und ist
// so gesetzt, dass die linke Kontaktspalte auf der Mittelachse des Dachausschnitts
// liegt; dafür wird die Tunnelwand rechts um idc_ext verbreitert. Diese linke
// Spalte wird nicht kontaktiert und bleibt daher geschlossen.
// Der Sockel füllt den Tunnelquerschnitt vom Tunnelboden bis zur Oberkante der
// Grundplatte.
//   Lokales System: Ursprung = Tunnelmitte in X/Y, z = 0 am Tunnelboden.
//
// Anschlussart (licht-Eintrag l[4]):
IDC_NONE  = 0; // kein Anschluss im Tunnel
IDC_PLUG  = 1; // Buchse mit Steckertasche für das Flachbandkabel
IDC_STACK = 2; // nur die Grundplatte als Führung für die Platinenverbinder;
               // ohne Steckertasche, damit gestapelte Räume aufeinander passen
idc_pitch = 2.54; // Rastermaß IDC [mm]
idc_cols  = 3;    // Kontakte in X
idc_rows  = 2;    // Kontakte in Y
idc_in_w  = 12.4; // Innenmaß der Tasche in X, lt. Standard 12.19 [mm]
idc_in_d  = 7;    // Innenmaß der Tasche in Y, lt. Standard 6.8 [mm]
idc_gap   = 6;    // Oberkante der Grundplatte über dem Tunnelboden [mm]
idc_base  = 1;  // Dicke der Grundplatte mit den Kontaktlöchern [mm]
idc_hole  = 1.4;  // Öffnung je Kontaktkammer [mm]

// Taschenmitte rechts der Mittelachse: die Kontakte sind in der Tasche zentriert,
// die linke Kontaktreihe liegt auf x = 0.
idc_off_x = (idc_cols - 1)/2 * idc_pitch;
// Verbreiterung der rechten Tunnelwand, damit die Tasche eine volle Wandstärke
// behält. Gilt über die gesamte Tunnelhöhe, sonst entstünde eine Auskragung.
idc_ext   = max(0, idc_off_x + idc_in_w/2 + tunnel_wall - (tunnel_w/2 + tunnel_wall));

// Oberkante der Grundplatte: die Buchse braucht darunter die Steckertasche, die
// Führung besteht nur aus der Grundplatte selbst.
function idc_base_z(idc_mode) = idc_mode == IDC_STACK ? idc_base : idc_gap;
// Verbreiterung nur für die Steckertasche; die Führung bleibt im Tunnelquerschnitt,
// damit gestapelte Räume dieselbe Außenkontur behalten.
function idc_mode_ext(idc_mode) = idc_mode == IDC_STACK ? 0 : idc_ext;

// Positivteil: Sockel bis zur Grundplatten-Oberkante plus Fase darüber.
module idc_socket_body(idc_mode, wall = tunnel_wall) {
    eps    = 0.01;                 // Überlappung der beiden Fasenhälften
    base_z = idc_base_z(idc_mode); // Oberkante der Grundplatte
    ramp   = tunnel_d/2;           // 45°-Fase von der Tunnelwand bis zur Mitte
    body_w = tunnel_w + 2*wall + idc_mode_ext(idc_mode);

    translate([-(tunnel_w/2 + wall), 0, 0]) {
        // Sockel über den gesamten Tunnelquerschnitt
        translate([0, -(tunnel_d/2 + wall), 0])
            cube([body_w, tunnel_d + 2*wall, base_z]);

        // Fase als Stützstruktur über der Grundplatte, aufgespannt zwischen den
        // Tunnel-Längswänden bei y = ±ramp. Beim Druck liegt die Dachfläche
        // unten, +z zeigt also nach unten: die Grundplatte wäre sonst eine frei
        // hängende Fläche. Beide Hälften setzen an den Wänden an und wachsen
        // unter 45° bis zur Mitte zusammen, sodass jede Schicht nur um eine
        // Schichthöhe auskragt. Die Fase läuft über die gesamte Tunnelbreite.
        for (s = [-1, 1])
            rotate([90, 0, 90])
                linear_extrude(height = body_w)
                    polygon([[-s * eps,  base_z],
                             [s * ramp,  base_z],
                             [s * ramp,  base_z + ramp]]);
    }
}

// Negativteil: Steckertasche, Kodiernase und Kontaktkammern. Die Führung
// (IDC_STACK) hat keine Tasche, die Grundplatte liegt dort direkt am Tunnelboden.
module idc_socket_cavity(tunnel_h, idc_mode, wall = tunnel_wall) {
    pocket_z = idc_base_z(idc_mode) - idc_base; // Taschendecke = Unterseite Grundplatte

    if (idc_mode != IDC_STACK) {
        // Steckertasche, nach z = 0 offen
        translate([idc_off_x, 0, pocket_z/2 - 0.05])
            cube([idc_in_w, idc_in_d, pocket_z + 0.1], true);

        // Kodiernase des Steckers in der Vorderwand
        translate([idc_off_x, -idc_in_d/2 - wall/2, pocket_z/2 - 0.05])
            cube([4, wall + 0.1, pocket_z + 0.1], true);
    }

    // Kontaktkammern durch Grundplatte und Fase bis über die Tunneloberkante,
    // damit die Kontakte frei liegen. Die linke Spalte auf der Mittelachse wird
    // nicht kontaktiert und entfällt in beiden Betriebsarten.
    for (ix = [1 : idc_cols - 1], iy = [0 : idc_rows - 1])
        translate([ix * idc_pitch,
                   (iy - (idc_rows - 1)/2) * idc_pitch,
                   (pocket_z + tunnel_h)/2])
            cube([idc_hole, idc_hole, tunnel_h - pocket_z + 0.2], true);
}

// ── Print-Offset ──────────────────────────────────────────────────────────────
// print_offset = [vorne, rechts, hinten, links]
po_fr = print_offset[0];   // Vorderwand-Versatz
po_ri = print_offset[1];   // Rechte-Wand-Versatz
po_ba = print_offset[2];   // Hinterwand-Versatz
po_le = print_offset[3];   // Linke-Wand-Versatz

// Innenflächen der Außenwände (virtuelle Koordinaten)
wall_front_inner = po_fr + aussenwand;
wall_back_inner  = room_depth  - po_ba - aussenwand;
wall_left_inner  = po_le + aussenwand;
wall_right_inner = room_width  - po_ri - aussenwand;

// ── Nut/Feder an der Innenwand-Anschlussstelle ─────────────────────────────────
// Ermöglicht getrennten Druck von Außen- (aussen) und Innen-Teil (innen): die
// Innenwand ragt (unverändert in ihrer eigenen Wandstärke innenwand/tunnel_wall)
// als Zapfen in die Außenwand bzw. das Dach hinein. An jeder Nut bleiben dabei
// immer wand_nut_min_rest (0.8mm) Wand zur sichtbaren Außenfläche stehen — die
// Nut füllt jeweils den kompletten Rest der Wandstärke aus. Bei einer Wand, die
// nirgends dicker als 0.8mm ist, entfällt die Nut automatisch (reiner
// Stumpfstoß), die sichtbare Außenfläche wird nie durchbrochen.
wand_nut_min_rest = 0.8;  // bleibt an jeder Nut zur sichtbaren Außenfläche stehen [mm]
wand_nut_spiel    = 0.15; // Spiel je Seite zwischen Zapfen und Nut (analog ecke_spiel)
// wand_nut_depth/dach_nut_depth sind die REALE (gedruckte) Zapfenlänge — bereits
// um wand_nut_spiel verkürzt, damit am Taschenboden Spiel bleibt und die
// sichtbaren Flächen (Wandanschluss bzw. Dachunterseite) plan aufeinander
// sitzen. Die Aussparung selbst (model_innen_grown(), grow=wand_nut_spiel)
// erreicht dadurch wieder die volle Tiefe bis genau wand_nut_min_rest
// Restwand — das Spiel steckt so ausschließlich am (unsichtbaren)
// Taschenboden, nicht in der Restwandstärke.
wand_nut_depth = max(0, aussenwand - wand_nut_min_rest - wand_nut_spiel);
dach_nut_depth = max(0, dachwand  - wand_nut_min_rest - wand_nut_spiel);
// Höhe, bis zu der Innenwände (front/back/left/right, poly_walls, named_walls)
// gebaut werden: Dachunterseite plus Zapfenlänge in die Dach-Nut hinein.
innen_top_z = (room_height - dachwand) + dach_nut_depth;

// Gemeinsame Formeln für den "wall_t/grow"-Mechanismus (Innenwände, Tunnel):
// jede Querschnittsseite wächst um grow, symmetrisch um dieselbe Mittelachse
// wie ohne Wachstum — grow_off() ist der Versatz für translate(), grow_span()
// die zugehörige (gewachsene) Kantenlänge. Bei grow=0 (reale Geometrie) sind
// beide identisch zur ungewachsenen Form.
function grow_off(t, grow)  = -t/2 - grow;
function grow_span(t, grow) = t + 2*grow;

// ── Lichtöffnung ──────────────────────────────────────────────────────────────
// licht = [[cx, cy, rotation, slot_mode, idc], ...]
// cx/cy = Mittelpunkt des Ausschnitts, absolute SCAD-Koordinaten vom Körperursprung (0,0).
// Ohne Datenwerte im licht-Abschnitt → automatisch zentriert (server.py).

// Referenz-Eintrag für die Innenwand-Logik: eine Auto-Innenwand läuft zu dem
// Ausschnitt, dessen Mitte dem Ansatzpunkt der Wand an der Außenwand am
// nächsten liegt. Bei nur einer Platine ist das immer diese eine.
function licht_dist2(i, px, py) = pow(licht[i][0] - px, 2) + pow(licht[i][1] - py, 2);
function licht_nearest(px, py, i = 1, best = 0) =
    i >= len(licht) ? best
  : licht_nearest(px, py, i + 1,
                  licht_dist2(i, px, py) < licht_dist2(best, px, py) ? i : best);
// Mittelpunkt des zuständigen Ausschnitts; ohne licht-Eintrag der Ursprung.
function licht_ref(px, py) = len(licht) > 0 ? licht[licht_nearest(px, py)] : [0, 0];

// Voller Ausschnitt-Fußabdruck (licht_w × licht_d) an der Lichtposition l,
// Dicke h ab Höhe z0 — gemeinsame Geometrie für Dachausschnitt, Randrahmen-
// Innenkante und den Freischnitt der Innenwände (innen_walls_all()).
module licht_hole(l, z0, h) {
    translate([l[0] - licht_w/2, l[1] - licht_d/2, z0])
        cube([licht_w, licht_d, h]);
}

module licht_transform(l) {
    cx = l[0];
    cy = l[1];
    translate([cx, cy, 0])
        rotate([0, 0, l[2]])
            translate([-cx, -cy, 0])
                children();
}

// ── Außenwand mit Fensteröffnungen ─────────────────────────────────────────────
// Eine einzige Funktion für alle vier Wände. Sie baut die Wand im lokalen
// Wandkoordinatensystem und schneidet die Fenster relativ zum Wandursprung
// (linke untere Ecke von außen). Der Aufrufer dreht die fertige Wand danach in
// die globale Lage – die frühere fallweise Spiegelung entfällt dadurch.
//
// Lokales System:
//   x = entlang der Wandlänge, x=0 an der Außen-Links-Ecke
//   y = Wanddicke, y=0 = Außenfläche, +y ins Gebäudeinnere
//   z = Höhe über Boden
//   length          = Referenzlänge der Wand (volle Raumkante)
//   inset_l/inset_r = Druckversatz an linker/rechter Wandkante (Panel-Verkürzung)
//   windows         = [[x_von_links, y_ab_boden, breite, hoehe], ...]
//   height          = Wandhöhe (Default room_height für Außenwände; benannte
//                     Fensterwände (named_walls) sind Innenwände und übergeben
//                     dafür innen_top_z, damit sie ebenfalls an der Dach-Nut
//                     enden statt durchzuragen).
//   thickness       = Wanddicke in Y-Richtung (Default aussenwand für
//                     Außenwände; named_wall() übergibt hier innenwand, s.u.).
module wall_with_windows(length, inset_l, inset_r, windows, height = room_height, thickness = aussenwand) {
    if (len(windows) == 0) {
        translate([inset_l, 0, 0])
            cube([length - inset_l - inset_r, thickness, height]);
    } else {
        difference() {
            translate([inset_l, 0, 0])
                cube([length - inset_l - inset_r, thickness, height]);
            for (w = windows)
                translate([w[0], -0.1, w[1]])
                    cube([w[2], thickness + 0.2, w[3]]);
        }
    }
}

// ── Tunnel-Struktur ───────────────────────────────────────────────────────────
// Zentriert im Dachausschnitt; Innenmasse tunnel_w × tunnel_d.
// Aufbau: Vorder-/Hinterwand (15mm in X), center_fins (bei cx in Y),
// Würfel 5×5×5mm außen links und rechts (ab Innenmass).

// grow (>0, siehe grow_off()/grow_span() oben) wächst die beiden Kreuzwände
// symmetrisch in der Dicke UND bringt (nur beim Freischnitt, grow=
// wand_nut_spiel) die Einstecktiefe wieder auf die volle Tiefe zurück
// (dach_nut_depth ist bereits um wand_nut_spiel verkürzt, s. Konstanten oben).
// Standfuß, Tunnelbohrung und IDC-Buchse grenzen nicht an die Außen-/
// Dachgruppe (liegen vollständig im Dachausschnitt, nicht im Randrahmen) —
// beim Freischnitt (grow>0) werden sie deshalb ausgelassen, das spart unnötige
// CGAL-Arbeit, ohne das Ergebnis zu ändern (dort ist ohnehin kein
// Außenkörper-Material vorhanden).
module tunnel(l, grow = 0) {
    cx  = l[0];   cy  = l[1];
    tw  = tunnel_w / 2;
    td  = tunnel_d / 2;
    tw_g = tunnel_w + 2* tunnel_wall;
    td_g = tunnel_d + 2* tunnel_wall;
    // 1mm Abstand für Platinenauflage
    h   = room_height - licht_h;
    h_top = h + dach_nut_depth + grow;
    // Anschlussart aus der Datenzeile: "idc" → IDC_PLUG, "stack" → IDC_STACK
    idc = is_undef(l[4]) ? IDC_NONE : l[4];
    ext = idc_mode_ext(idc);   // Verbreiterung der rechten Wand für die Buchse

    // Kreuzwände: Länge wächst um innenwand+grow über licht_w/licht_d hinaus
    // (Padding je Seite), Dicke wächst um grow (siehe grow_off()/grow_span()).
    module kreuzwaende() {
        translate([cx + grow_off(licht_w, innenwand + grow), cy + grow_off(innenwand, grow), 0])
            cube([grow_span(licht_w, innenwand + grow), grow_span(innenwand, grow), h_top]);
        translate([cx + grow_off(innenwand, grow), cy + grow_off(licht_d, innenwand + grow), 0])
            cube([grow_span(innenwand, grow), grow_span(licht_d, innenwand + grow), h_top]);
    }

    if (grow > 0) {
        // Nur die Kreuzwände — Standfuß/Bohrung/IDC-Buchse berühren die
        // Außen-/Dachgruppe nie und werden für den Freischnitt nicht gebraucht
        // (spart unnötige CGAL-Arbeit, ohne das Ergebnis zu ändern).
        difference() {
            kreuzwaende();
            translate([cx - tw, cy - td, -0.1])
                cube([tunnel_w, tunnel_d, h_top + 0.2]);
        }
    } else {
        difference() {
            union() {
                difference() {
                    union() {
                        // Standfuss - solider Würfel bildet Pfeiler + X-Wände
                        translate([cx - tw_g/2, cy - td_g/2, 0])
                            cube([tw_g + ext, td_g, h]);
                        kreuzwaende();
                    }

                    translate([cx - tw, cy - td, -0.1])
                        cube([tunnel_w, tunnel_d, h_top + 0.2]);

                }

                // Sockel der IDC-Buchse füllt die Tunnelbohrung von unten auf
                if (idc != IDC_NONE)
                    translate([cx, cy, 0])
                        idc_socket_body(idc);
            }

            // Tasche der IDC-Buchse; greift bis in die verbreiterte rechte Wand
            if (idc != IDC_NONE)
                translate([cx, cy, 0])
                    idc_socket_cavity(h, idc);
        }
    }
}

// Ausrichtungshilfe (Zentrierzapfen für die Platine) und Schalterhalterung:
// beide sitzen im Randrahmen-/Dachbereich (voll im Z-Bereich des Randrahmens
// enthalten) und gehören daher zur Außen-/Dachgruppe, nicht zum Tunnel.
module dach_feature(l) {
    cx = l[0]; cy = l[1];
    lx = cx - licht_w / 2;
    ly = cy - licht_d / 2;
    h  = room_height - licht_h;

    // Ausrichtungshilfe
    translate([lx + licht_w, ly + 21.4, h])
        cylinder(h = licht_h, d = 6.8, $fn = 32);

    // Halterung Schalter (Ausschnitt erfolgt später via mode_switch())
    translate([cx - 3, ly - 4, room_height - 3])
        cube([6, 4, 3.0]);
}

// ── Stapelecken ───────────────────────────────────────────────────────────────
// Bei gesetztem Stockwerk bekommt jede der vier Wandinnenecken eine Aussparung
// im Dach; ab dem ersten Obergeschoss sitzt an den unteren Ecken ein passender
// Zapfen. Gestapelt greift der Zapfen des oberen Raums in die Aussparung des
// darunterliegenden Dachs und fixiert die Räume zueinander. Zapfen und
// Aussparung liegen auf der Innenseite der Außenwände, damit die Außenkontur
// der Maske unverändert bleibt und beim Einschieben nichts aufsetzt.
ecke_kante = 2;     // Kantenlänge der quadratischen Ecken [mm]
ecke_r     = 3;     // Radius des Viertelkreises vorne links [mm]
ecke_tief  = 2;     // Eingriffstiefe von Zapfen und Aussparung [mm]
ecke_spiel = 0.15;  // Spiel je Seite zwischen Zapfen und Aussparung [mm]

geschoss_nr = is_undef(geschoss) ? -1 : geschoss;

// Eine Außenwand ohne Öffnungen wird nicht erzeugt. Fehlen an einer Ecke beide
// angrenzenden Wände, hätte ein Zapfen dort keine Anbindung an den Körper.
function ecke_hat_wand(sx, sy) =
    len(sy ? back_windows : front_windows) > 0 ||
    len(sx ? right_windows : left_windows) > 0;

// Innere Ecken der Außenwände (Druckversatz und Wandstärke berücksichtigt).
function ecke_pos(sx, sy) = [sx ? wall_right_inner : wall_left_inner,
                             sy ? wall_back_inner  : wall_front_inner];

// Grundriss einer Stapelecke. Lokaler Ursprung = innere Wandecke, +X/+Y zeigen
// nach innen; die Spiegelung im Aufrufer dreht den Grundriss in die jeweilige
// Ecke. Vorne links ein Viertelkreis, sonst ein Quadrat – die abweichende Form
// macht die Stapellage eindeutig, gestapelt passt nur eine Drehung.
//   spiel = Untermaß je Seite (Zapfen); die beiden Kanten an den Wänden bleiben
//           bündig, das Spiel liegt auf der Innenseite.
module ecke_profil(sx, sy, spiel = 0) {
    if (!sx && !sy)
        intersection() {
            circle(r = ecke_r - spiel, $fn = 64);
            square(ecke_r);
        }
    else
        square(ecke_kante - spiel);
}

// Aussparung: von der Dachunterseite ecke_tief nach oben durch das Dach.
module ecken_cut() {
    for (sx = [0, 1], sy = [0, 1]) {
        p = ecke_pos(sx, sy);
        translate([p[0], p[1], room_height - ecke_tief])
            scale([sx ? -1 : 1, sy ? -1 : 1, 1])
                linear_extrude(height = ecke_tief + 0.1)
                    ecke_profil(sx, sy);
    }
}

// Zapfen: an den beiden Wandinnenflächen, nach innen um ecke_spiel schlanker
// als die Aussparung. Er ragt um ecke_tief unter die Raumunterkante und läuft
// ebenso weit nach oben in den Körper.
// An der Wandinnenfläche liegt der Zapfen nur an, ohne Überlappung wäre er ein
// eigener Körper. Der Fuß ist deshalb derselbe Grundriss, um die Wandstärke
// nach außen versetzt: er endet genau an den Wandaußenflächen und verschmilzt
// auf diesem Weg mit beiden Wänden.
module ecken_pin() {
    for (sx = [0, 1], sy = [0, 1])
        if (ecke_hat_wand(sx, sy)) {
            p = ecke_pos(sx, sy);
            translate([p[0], p[1], 0])
                scale([sx ? -1 : 1, sy ? -1 : 1, 1]) {
                    translate([0, 0, -ecke_tief])
                        linear_extrude(height = 2*ecke_tief)
                            ecke_profil(sx, sy, ecke_spiel);
                    translate([-aussenwand, -aussenwand, 0])
                        linear_extrude(height = ecke_tief)
                            ecke_profil(sx, sy);
                }
        }
}

// ── Randrahmen um Dachausschnitt ──────────────────────────────────────────────
// 2mm hoch, innenwand breit. Kabelschlitz wird global geschnitten (mode_switch).

module licht_border(l) {
    lx = l[0] - licht_w / 2; ly = l[1] - licht_d / 2;
    difference() {
        translate([lx - innenwand, ly - innenwand, room_height - 3])
            cube([licht_w + 2*innenwand, licht_d + 2*innenwand, 3]);
        licht_hole(l, room_height - 3 - 0.1, 3 + 0.2);
    }
}

// ── Kabelschlitz ──────────────────────────────────────────────────────────────
// 5mm breit, innenwand tief, schneidet alle Elemente an der Vorderkante des Ausschnitts.
// Z: 2mm unter Rahmenboden bis durch die Decke (globale difference).

module mode_switch(l) {
    cx   = l[0];
    ly   = l[1] - licht_d / 2;
    mode = l[3];  // 0 = Quader, 1 = weiter (rechts Keil), 2 = ende (links Keil)
    z0   = room_height - 2.5;
    // Wandbereich hinter Ausschnitt immer öffnen
    translate([cx - 2, ly, z0])
        cube([4, 3, 3]);
    if (mode == 1) {
        // Trapez: links voll offen, rechts nach oben auslaufend
        translate([cx, ly + 0.1, z0])
            rotate([90, 0, 0])
                linear_extrude(height = 3.1)
                    polygon([[-2, 0], [0, 0], [2, 3.1], [-2, 3.1]]);
    } else if (mode == 2) {
        // Trapez gespiegelt: rechts voll offen, links nach oben auslaufend
        translate([cx, ly + 0.1, z0])
            rotate([90, 0, 0])
                linear_extrude(height = 3.1)
                    polygon([[0, 0], [2, 0], [2, 3.1], [-2, 3.1]]);
    } else {
        // mode == 0: kompletter Quader
        translate([cx - 2, ly - 2.9, z0])
            cube([4, 3, 3.1]);
    }
}

// ── Freie Innenwände (Polygonzug/benannt) ─────────────────────────────────────
// poly_walls    = [[[x1,y1],[x2,y2],...], ...]
// named_walls   = [[[x1,y1],[x2,y2],[[x,z0,b,h],...]], ...]
//
// Ein Wandende kann an einer Außenwand enden — üblicherweise wird es dabei bis
// auf/über deren Außenfläche gezeichnet (einfachste Eingabe in der "wand"-
// Sektion, ohne aussenwand kennen zu müssen). Damit die Außenwand eine
// vollständig geschlossene, einfarbige Fläche bleibt, wird ein solcher Endpunkt
// exakt auf die Innenfläche der betroffenen Außenwand gekappt und bekommt
// dieselbe Nut/Feder wie die übrigen Innenwände (wand_nut_depth/-spiel).
_pw_eps = 0.05; // Toleranz gegen Rundungsfehler beim Kantenvergleich
function poly_wall_end_face(pt) =
      pt[1] <= wall_front_inner + _pw_eps
          && pt[0] >= wall_left_inner - _pw_eps && pt[0] <= wall_right_inner + _pw_eps ? 0
    : pt[1] >= wall_back_inner  - _pw_eps
          && pt[0] >= wall_left_inner - _pw_eps && pt[0] <= wall_right_inner + _pw_eps ? 1
    : pt[0] <= wall_left_inner  + _pw_eps
          && pt[1] >= wall_front_inner - _pw_eps && pt[1] <= wall_back_inner + _pw_eps ? 2
    : pt[0] >= wall_right_inner - _pw_eps
          && pt[1] >= wall_front_inner - _pw_eps && pt[1] <= wall_back_inner + _pw_eps ? 3
    : -1;

// Punkt, auf die Innenfläche der betroffenen Außenwand gekappt (nur die
// betroffene Achse geändert).
function poly_wall_clip(pt, face) =
      face == 0 ? [pt[0], wall_front_inner]
    : face == 1 ? [pt[0], wall_back_inner]
    : face == 2 ? [wall_left_inner, pt[1]]
    : [wall_right_inner, pt[1]];

// Freistehende gerade Wand p1→p2 mit optionalen Fensteröffnungen (Dicke
// wall_t, volle Höhe). poly_walls sind der Sonderfall ohne Fenster
// (windows=[], siehe poly_walls_draw()). Fenster: [x, z0, breite, hoehe] –
// x = Distanz entlang der Wand ab p1, z0 = Höhe ab Boden; wie bei den
// Außenwänden vorne/hinten.
// wall_t/grow: siehe grow_off()/grow_span() weiter oben — nur für den
// Freischnitt im Außenkörper ungleich 0 (siehe model_innen_grown()).
module named_wall(p1, p2, windows = [], wall_t = innenwand, grow = 0) {
    f1 = poly_wall_end_face(p1);
    f2 = poly_wall_end_face(p2);
    q1 = f1 >= 0 ? poly_wall_clip(p1, f1) : p1;
    q2 = f2 >= 0 ? poly_wall_clip(p2, f2) : p2;
    // Versatz durch die Kappung an p1 (0, wenn dieses Ende nicht andockt).
    // Fenster sind laut Doku "Distanz ab p1" — bleiben deshalb auf den
    // ORIGINAL deklarierten Punkt p1 bezogen, nicht auf den gekappten q1.
    clip1 = f1 >= 0 ? sqrt(pow(q1[0]-p1[0], 2) + pow(q1[1]-p1[1], 2)) : 0;
    dx = q2[0] - q1[0];
    dy = q2[1] - q1[1];
    len = sqrt(dx*dx + dy*dy);
    // Zapfen über den gekappten Endpunkt hinaus, nur wo tatsächlich eine
    // Außenwand anliegt (sonst schlichter Stumpfstoß). +grow bringt beim
    // Freischnitt die Einstecktiefe auf die volle Tiefe zurück (wand_nut_depth
    // ist bereits um wand_nut_spiel verkürzt). clip2 wird nicht gebraucht:
    // ext2 hängt nur von wand_nut_depth/grow ab, Fenster sind nie an p2
    // verankert.
    ext1 = f1 >= 0 ? wand_nut_depth + grow : 0;
    ext2 = f2 >= 0 ? wand_nut_depth + grow : 0;
    // wall_with_windows() erhält als Länge (len+ext1+ext2) und beginnt bei
    // lokal x=0 — durch das anschließende translate([-ext1,...]) sitzt dieses
    // lokale x=0 bei U=-ext1 (U = Distanz ab q1 entlang der Wand). +ext1
    // gleicht das aus, damit "w[0]-clip1" (Distanz ab p1, s.o.) tatsächlich
    // bei U=w[0]-clip1 landet statt fälschlich bei U=w[0]-clip1-ext1.
    win = [for (w = windows) [w[0] - clip1 + ext1, w[1], w[2], w[3]]];
    translate([q1[0], q1[1], 0])
        rotate([0, 0, atan2(dy, dx)])
            translate([-ext1, grow_off(wall_t, grow), 0])
                wall_with_windows(len + ext1 + ext2, 0, 0, win, innen_top_z + grow, grow_span(wall_t, grow));
}

module poly_walls_draw(polys, wall_t = innenwand, grow = 0) {
    for (poly = polys)
        for (i = [0 : len(poly) - 2])
            named_wall(poly[i], poly[i+1], [], wall_t, grow);
}

module named_walls_draw(walls, wall_t = innenwand, grow = 0) {
    for (nw = walls)
        named_wall(nw[0], nw[1], nw[2], wall_t, grow);
}

// ── Innenwände ────────────────────────────────────────────────────────────────
// walls = [[pos, laenge], ...] — laenge=-1 → auto (Wand bis zum Dach-Randrahmen
// + Querelement zur Lichtmitte).
//
// Eine einzige kanonische Innenwand im lokalen System, analog zu den Außenwänden;
// der Aufrufer platziert (dreht/spiegelt) sie pro Seite.
//   X = Position entlang der Seite (Wanddicke innenwand um p)
//   Y = Länge nach innen ab der Innenfläche der Außenwand (Y=0)
//   Z = Höhe
//   v_edge = Y-Abstand Innenfläche → naher Rand des Dachausschnitts (Auto-Modus)
//   u_c    = Position der Lichtmitte entlang X (Auto-Querelement)
// wall_t/grow: siehe grow_off()/grow_span() weiter oben — nur für den
// Freischnitt im Außenkörper ungleich 0 (siehe model_innen_grown()). +grow
// bringt beim Freischnitt zugleich die Einstecktiefe auf die volle Tiefe
// zurück (wand_nut_depth/innen_top_z sind bereits um wand_nut_spiel verkürzt).
// Zapfen Richtung Außenwand direkt in die Hauptwand eingerechnet (kein eigenes
// Tenon-Modul mehr): die Hauptwand beginnt bereits bei y = -(wand_nut_depth+grow)
// statt bei y=0 und ist entsprechend länger.
module inner_wall(p, len, v_edge, u_c, wall_t = innenwand, grow = 0) {
    ext = wand_nut_depth + grow;
    if (len != -1) {
        translate([p + grow_off(wall_t, grow), -ext, 0])
            cube([grow_span(wall_t, grow), len + ext, innen_top_z + grow]);
    } else {
        // Hauptwand: von der Innenfläche (v=0, bündig/verschmelzend) bis zum
        // Randrahmen. Kein Überstand in die Außenwand → ragt nie in ein Fenster.
        translate([p + grow_off(wall_t, grow), -ext, 0])
            cube([grow_span(wall_t, grow), v_edge + ext, innen_top_z + grow]);
        // Querelement im Randrahmen-Streifen von p bis zur Lichtmitte (an
        // min(p,u_c) verankert statt zentriert, deshalb hier nicht über
        // grow_off()/grow_span() ausgedrückt).
        translate([min(p, u_c) - wall_t/2 - grow, v_edge - wall_t - grow, 0])
            cube([abs(p - u_c) + wall_t + 2*grow, wall_t + 2*grow, innen_top_z + grow]);
    }
}

// Platziert alle Innenwände einer Seite. face: 0=vorne,1=hinten,2=links,3=rechts.
// vorne/rechts sind Rotationen, hinten/links Spiegelungen – die Position p wird
// serverseitig bereits passend (invertiert) geliefert.
// Der Ansatzpunkt einer Wand liegt auf der Innenfläche ihrer Außenwand bei der
// Position w[0]; er bestimmt, welcher Ausschnitt angefahren wird.
module inner_walls_place(face, walls, wall_t = innenwand, grow = 0) {
    if (face == 0)          // vorne: keine Drehung, nach innen = +Y
        translate([0, wall_front_inner, 0])
            for (w = walls) {
                ref = licht_ref(w[0], wall_front_inner);
                inner_wall(w[0], w[1],
                           ref[1] - licht_d/2 - wall_front_inner, ref[0], wall_t, grow);
            }
    else if (face == 1)     // hinten: an Y gespiegelt
        translate([0, wall_back_inner, 0]) mirror([0, 1, 0])
            for (w = walls) {
                ref = licht_ref(w[0], wall_back_inner);
                inner_wall(w[0], w[1],
                           wall_back_inner - (ref[1] + licht_d/2), ref[0], wall_t, grow);
            }
    else if (face == 2)     // links: X↔Y getauscht (Spiegelung)
        translate([wall_left_inner, 0, 0]) mirror([1, 0, 0]) rotate([0, 0, 90])
            for (w = walls) {
                ref = licht_ref(wall_left_inner, w[0]);
                inner_wall(w[0], w[1],
                           ref[0] - licht_w/2 - wall_left_inner, ref[1], wall_t, grow);
            }
    else if (face == 3)     // rechts: 90°-Drehung
        translate([wall_right_inner, 0, 0]) rotate([0, 0, 90])
            for (w = walls) {
                ref = licht_ref(wall_right_inner, w[0]);
                inner_wall(w[0], w[1],
                           wall_right_inner - (ref[0] + licht_w/2), ref[1], wall_t, grow);
            }
}

// ── Farbgruppen / Maske ───────────────────────────────────────────────────────
// Zwei Modelle für den Multi-Material-/Mehrteil-Druck:
//   model_aussen() = Außenwände + Dach + Randrahmen + Stapelzapfen + Gravur
//   model_innen()  = Innenwände + Tunnel-Struktur (Platinenhalter)
// Beide wenden dieselben globalen Schnitte (ecken_cut, mode_switch) einzeln an;
// den Freischnitt für die Nut/Feder übernimmt model_innen_grown() (s.u.).
// Gesteuert über den CSV-Parameter "maske" (druck-Abschnitt: innen/aussen/beide,
// Default "beide" für alte Datensätze).
maske_mode = is_undef(maske) ? "beide" : maske;

// Alle Innenwände (ohne Tunnel) — geteilt zwischen model_innen() (Aufbau) und
// model_innen_grown() (aufgeweiteter Freischnitt für den Außenkörper, s.u.).
module innen_walls_all(wall_t = innenwand, grow = 0) {
    difference() {
        union() {
            inner_walls_place(0, front_walls, wall_t, grow);
            inner_walls_place(1, back_walls,  wall_t, grow);
            inner_walls_place(2, left_walls,  wall_t, grow);
            inner_walls_place(3, right_walls, wall_t, grow);
            poly_walls_draw(poly_walls, wall_t, grow);
            named_walls_draw(is_undef(named_walls) ? [] : named_walls, wall_t, grow);
        }
        // Dachausschnitt bleibt frei: Wände wachsen einheitlich bis innen_top_z
        // (auch im Randrahmen-Streifen), das darf aber nie in die eigentliche
        // Lichtöffnung hineinragen — deshalb hier pauschal wieder freischneiden.
        for (l = licht)
            licht_transform(l)
                licht_hole(l, -0.1, room_height + 0.2);
    }
}

module model_aussen() {
    difference() {
        union() {
            // Außenwände – je eine gedrehte Instanz der kanonischen Wand.
            // Nur wenn Fenster/Türen vorhanden, sonst weggelassen.
            // Vorne: Außen-Links-Ecke = Raumursprung, keine Drehung.
            if (len(front_windows) > 0)
                translate([0, po_fr, 0])
                    wall_with_windows(room_width, po_le, po_ri, front_windows);
            // Hinten: um 180° gedreht (Außen-Links liegt bei +X/+Y).
            if (len(back_windows) > 0)
                translate([room_width, room_depth - po_ba, 0]) rotate([0, 0, 180])
                    wall_with_windows(room_width, po_ri, po_le, back_windows);
            // Links: um -90° gedreht (Außen-Links liegt bei +Y).
            if (len(left_windows) > 0)
                translate([po_le, room_depth, 0]) rotate([0, 0, -90])
                    wall_with_windows(room_depth, po_ba, po_fr, left_windows);
            // Rechts: um +90° gedreht (Außen-Links liegt bei -Y).
            if (len(right_windows) > 0)
                translate([room_width - po_ri, 0, 0]) rotate([0, 0, 90])
                    wall_with_windows(room_depth, po_fr, po_ba, right_windows);

            // Dach mit Lichtöffnungen und Dachausschnitten
            difference() {
                translate([po_le, po_fr, room_height - dachwand])
                    cube([room_width - po_le - po_ri, room_depth - po_fr - po_ba, dachwand]);
                for (l = licht)
                    licht_transform(l)
                        licht_hole(l, room_height - dachwand - 0.1, dachwand + 0.2);
                // dach_cuts-Eintrag: [x, y, breite, tiefe] = Rechteck-Ausschnitt (Ecke x,y),
                //                    [cx, cy, led]         = Öffnung nach LED-Typ (Mitte cx,cy)
                for (c = dach_cuts)
                    if (len(c) >= 4)
                        translate([c[0], c[1], room_height - dachwand - 0.1])
                            cube([c[2], c[3], dachwand + 0.2]);
                    else
                        translate([c[0], c[1], room_height - dachwand/2])
                            rotate([180, 0, 0])
                                led_negative_by_type(c[2], dachwand);
            }

            // Randrahmen für jeden Dachausschnitt (fest mit dem Dach verschmolzen)
            for (l = licht)
                licht_transform(l)
                    licht_border(l);

            // Ausrichtungshilfe + Schalterhalterung (gehören zum Dach, nicht zum Tunnel)
            for (l = licht)
                licht_transform(l)
                    dach_feature(l);

            // Zapfen der Stapelecken ab dem ersten Obergeschoss
            if (geschoss_nr > 0)
                ecken_pin();

            for (t = texts)
                translate([t[1], t[2], room_height - dachwand + 0.4])
                    rotate([0, 0, t[3]])
                        linear_extrude(height = dachwand)
                            text(t[0], size = 5);
        } // union

        // Aussparungen der Stapelecken, sobald ein Stockwerk angegeben ist
        if (geschoss_nr >= 0)
            ecken_cut();

        // Kabelschlitz global schneiden
        for (l = licht)
            licht_transform(l) mode_switch(l);

        // Freischnitt für die Nut/Feder: dieselbe Innenkörper-Geometrie, aber
        // um wand_nut_spiel aufgeweitet (model_innen_grown(), s.u.) — überall
        // dort, wo der aufgeweitete Innenkörper den Außenkörper berührt
        // (Wände, Randrahmen, Schalterhalterung, Ausrichtungshilfe, Dach),
        // entsteht automatisch eine passende Aussparung.
        model_innen_grown();
    }
}

module model_innen() {
    innen_walls_all();
    for (l = licht) licht_transform(l) tunnel(l);
}

// Nur zum Freischneiden im Außenkörper (siehe model_aussen()) — keine eigene
// Druckgeometrie. Dieselbe Geometrie wie model_innen(), aber mit um
// wand_nut_spiel größeren Wandstärken/Tiefen, symmetrisch um dieselben
// Mittelachsen/Ursprungspunkte gewachsen (kein Minkowski nötig).
module model_innen_grown() {
    innen_walls_all(innenwand, wand_nut_spiel);
    for (l = licht) licht_transform(l) tunnel(l, wand_nut_spiel);
}

// ── Hauptgeometrie ────────────────────────────────────────────────────────────
// Druckorientierung: Modell um die X-Achse kippen, so dass die Dachfläche
// (ursprünglich Oberkante bei z=room_height) flach auf dem Druckbett (z=0) liegt.

translate([0, room_depth, 0]) rotate([180, 0, 0]) {
    if (maske_mode == "aussen" || maske_mode == "beide")
        color([1, 0, 0]) model_aussen();
    if (maske_mode == "innen" || maske_mode == "beide")
        color([1, 1, 0]) model_innen();
}
