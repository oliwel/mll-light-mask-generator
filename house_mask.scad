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
idc_in_w  = 12;   // Innenmaß der Tasche in X [mm]
idc_in_d  = 7;    // Innenmaß der Tasche in Y [mm]
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
function idc_base_z(mode) = mode == IDC_STACK ? idc_base : idc_gap;
// Verbreiterung nur für die Steckertasche; die Führung bleibt im Tunnelquerschnitt,
// damit gestapelte Räume dieselbe Außenkontur behalten.
function idc_mode_ext(mode) = mode == IDC_STACK ? 0 : idc_ext;

// Positivteil: Sockel bis zur Grundplatten-Oberkante plus Fase darüber.
module idc_socket_body(mode, wall = tunnel_wall) {
    eps    = 0.01;             // Überlappung der beiden Fasenhälften
    base_z = idc_base_z(mode); // Oberkante der Grundplatte
    ramp   = tunnel_d/2;       // 45°-Fase von der Tunnelwand bis zur Mitte
    body_w = tunnel_w + 2*wall + idc_mode_ext(mode);

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
module idc_socket_cavity(tunnel_h, mode, wall = tunnel_wall) {
    pocket_z = idc_base_z(mode) - idc_base;   // Taschendecke = Unterseite Grundplatte

    if (mode != IDC_STACK) {
        // Steckertasche, nach z = 0 offen
        translate([idc_off_x, 0, pocket_z/2 - 0.05])
            cube([idc_in_w, idc_in_d, pocket_z + 0.1], true);

        // Kodiernase des Steckers in der Vorderwand
        translate([idc_off_x, -idc_in_d/2 - wall/2, pocket_z/2 - 0.05])
            cube([idc_pitch, wall + 0.1, pocket_z + 0.1], true);
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
module wall_with_windows(length, inset_l, inset_r, windows) {
    difference() {
        translate([inset_l, 0, 0])
            color([0,0,0.5])
                cube([length - inset_l - inset_r, aussenwand, room_height]);
        for (w = windows)
            translate([w[0], -0.1, w[1]])
                cube([w[2], aussenwand + 0.2, w[3]]);
    }
}

// ── Tunnel-Struktur ───────────────────────────────────────────────────────────
// Zentriert im Dachausschnitt; Innenmasse tunnel_w × tunnel_d.
// Aufbau: Vorder-/Hinterwand (15mm in X), center_fins (bei cx in Y),
// Würfel 5×5×5mm außen links und rechts (ab Innenmass).

module tunnel(l) {
    cx  = l[0];   cy  = l[1];
    lx  = cx - licht_w / 2;
    ly  = cy - licht_d / 2;
    tw  = tunnel_w / 2;
    td  = tunnel_d / 2;
    tw_g = tunnel_w + 2* tunnel_wall;
    td_g = tunnel_d + 2* tunnel_wall;
    // 1mm Abstand für Platinenauflage
    h   = room_height - licht_h;
    // Anschlussart aus der Datenzeile: "idc" → IDC_PLUG, "stack" → IDC_STACK
    idc = is_undef(l[4]) ? IDC_NONE : l[4];
    ext = idc_mode_ext(idc);   // Verbreiterung der rechten Wand für die Buchse

    difference() {
        union() {
            difference() {
                union() {
                    // Standfuss - solider Würfel bildet Pfeiler + X-Wände
                    translate([cx - tw_g/2, cy - td_g/2, 0])
                        cube([tw_g + ext, td_g, h]);

                    // Kreuzwand in Y-Richtung
                    translate([lx - innenwand , cy - innenwand/2, 0])
                        cube([ licht_w + 2 * innenwand, innenwand, h]);

                    // Kreuzwand in X-Richtung
                    translate([cx - innenwand/2, ly - innenwand, 0])
                        cube([innenwand, licht_d + 2* innenwand, h]);

                    // Ausrichtungshilfe
                    translate([lx + licht_w, ly + 21.4, h])
                        cylinder( h = licht_h, d = 6.8, $fn=32 );

                    // Halterung Schalter (Ausschnitt erfolgt später)
                    translate([cx - 3, ly - 4, room_height - 3 ])
                        cube([ 6, 4, 3.0]);

                }

                translate([cx - tw, cy - td, -0.1])
                    cube([tunnel_w, tunnel_d, h + 0.2]);

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

// ── Stapelecken ───────────────────────────────────────────────────────────────
// Bei gesetztem Stockwerk bekommt jede der vier Dachecken eine quadratische
// Aussparung; ab dem ersten Obergeschoss sitzt an den unteren Ecken ein
// passender Zapfen. Gestapelt greift der Zapfen des oberen Raums in die
// Aussparung des darunterliegenden Dachs und fixiert die Räume zueinander.
ecke_kante = 2;     // Kantenlänge der Aussparung [mm]
ecke_spiel = 0.15;  // Spiel je Seite zwischen Zapfen und Aussparung [mm]

geschoss_nr = is_undef(geschoss) ? -1 : geschoss;

// Eine Außenwand ohne Öffnungen wird nicht erzeugt. Fehlen an einer Ecke beide
// angrenzenden Wände, hätte ein Zapfen dort keine Anbindung an den Körper.
function ecke_hat_wand(sx, sy) =
    len(sy ? back_windows : front_windows) > 0 ||
    len(sx ? right_windows : left_windows) > 0;

// Setzt die Kinder in die vier Ecken der Dachfläche (Druckversatz berücksichtigt).
// Lokaler Ursprung = äußere Ecke, +X/+Y zeigen nach innen; die Spiegelung macht
// die Kinder für alle vier Ecken identisch.
//   nur_mit_wand = Ecken ohne angrenzende Außenwand auslassen
module ecken_place(nur_mit_wand = false) {
    for (sx = [0, 1], sy = [0, 1])
        if (!nur_mit_wand || ecke_hat_wand(sx, sy))
            translate([sx ? room_width - po_ri : po_le,
                       sy ? room_depth - po_ba : po_fr,
                       0])
                scale([sx ? -1 : 1, sy ? -1 : 1, 1])
                    children();
}

// Aussparung: vom Dachaußenrand ecke_kante tief nach innen.
module ecken_cut() {
    ecken_place()
        translate([0, 0, room_height - ecke_kante])
            cube([ecke_kante, ecke_kante, ecke_kante + 0.1]);
}

// Zapfen: an den beiden Außenflächen bündig mit der Wand, nach innen um
// ecke_spiel schlanker als die Aussparung. Er ragt um ecke_kante unter die
// Raumunterkante und läuft ebenso weit nach oben in den Körper hinein, damit er
// an der Ecke fest angebunden ist.
module ecken_pin() {
    ecken_place(nur_mit_wand = true)
        translate([0, 0, -ecke_kante])
            cube([ecke_kante - ecke_spiel, ecke_kante - ecke_spiel, 2*ecke_kante]);
}

// ── Randrahmen um Dachausschnitt ──────────────────────────────────────────────
// 2mm hoch, innenwand breit. Kabelschlitz wird global geschnitten (mode_switch).

module licht_border(l) {
    lx = l[0] - licht_w / 2; ly = l[1] - licht_d / 2;
    translate([lx - innenwand, ly - innenwand, room_height - 3])
        difference() {
            cube([licht_w + 2*innenwand, licht_d + 2*innenwand, 3]);
            translate([innenwand, innenwand, - 0.1])
                cube([licht_w, licht_d, 3 + 0.2]);
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

// ── Freie Innenwände (Polygonzug) ─────────────────────────────────────────────
// poly_walls = [[[x1,y1],[x2,y2],...], ...]

module wall_seg(p1, p2) {
    dx = p2[0] - p1[0];
    dy = p2[1] - p1[1];
    len = sqrt(dx*dx + dy*dy);
    translate([p1[0], p1[1], 0])
        rotate([0, 0, atan2(dy, dx)])
            translate([0, -innenwand/2, 0])
                cube([len, innenwand, room_height]);
}

module poly_walls_draw(polys) {
    for (poly = polys)
        for (i = [0 : len(poly) - 2])
            wall_seg(poly[i], poly[i+1]);
}

// ── Benannte Fensterwände ───────────────────────────────────────────────────────
// Freistehende gerade Wand p1→p2 (Dicke innenwand, volle Höhe) mit Fenstern.
// Fenster: [x, z0, breite, hoehe] – x = Distanz entlang der Wand ab p1,
// z0 = Höhe ab Boden; wie bei den Außenwänden vorne/hinten.
// named_walls = [[[x1,y1],[x2,y2],[[x,z0,b,h],...]], ...]
module named_wall(p1, p2, windows) {
    dx = p2[0] - p1[0];
    dy = p2[1] - p1[1];
    len = sqrt(dx*dx + dy*dy);
    translate([p1[0], p1[1], 0])
        rotate([0, 0, atan2(dy, dx)])
            translate([0, -innenwand/2, 0])
                wall_with_windows(len, 0, 0, windows);
}

module named_walls_draw(walls) {
    for (nw = walls)
        named_wall(nw[0], nw[1], nw[2]);
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
module inner_wall(p, len, v_edge, u_c) {
    if (len != -1) {
        translate([p - innenwand/2, 0, 0])
            cube([innenwand, len, room_height]);
    } else {
        // Hauptwand: von der Innenfläche (v=0, bündig/verschmelzend) bis zum
        // Randrahmen. Kein Überstand in die Außenwand → ragt nie in ein Fenster.
        translate([p - innenwand/2, 0, 0])
            cube([innenwand, v_edge, room_height]);
        // Querelement im Randrahmen-Streifen von p bis zur Lichtmitte
        translate([min(p, u_c) - innenwand/2, v_edge - innenwand, 0])
            cube([abs(p - u_c) + innenwand, innenwand, room_height]);
    }
}

// Platziert alle Innenwände einer Seite. face: 0=vorne,1=hinten,2=links,3=rechts.
// vorne/rechts sind Rotationen, hinten/links Spiegelungen – die Position p wird
// serverseitig bereits passend (invertiert) geliefert.
// Der Ansatzpunkt einer Wand liegt auf der Innenfläche ihrer Außenwand bei der
// Position w[0]; er bestimmt, welcher Ausschnitt angefahren wird.
module inner_walls_place(face, walls) {
    if (face == 0)          // vorne: keine Drehung, nach innen = +Y
        translate([0, wall_front_inner, 0])
            for (w = walls) {
                ref = licht_ref(w[0], wall_front_inner);
                inner_wall(w[0], w[1],
                           ref[1] - licht_d/2 - wall_front_inner, ref[0]);
            }
    else if (face == 1)     // hinten: an Y gespiegelt
        translate([0, wall_back_inner, 0]) mirror([0, 1, 0])
            for (w = walls) {
                ref = licht_ref(w[0], wall_back_inner);
                inner_wall(w[0], w[1],
                           wall_back_inner - (ref[1] + licht_d/2), ref[0]);
            }
    else if (face == 2)     // links: X↔Y getauscht (Spiegelung)
        translate([wall_left_inner, 0, 0]) mirror([1, 0, 0]) rotate([0, 0, 90])
            for (w = walls) {
                ref = licht_ref(wall_left_inner, w[0]);
                inner_wall(w[0], w[1],
                           ref[0] - licht_w/2 - wall_left_inner, ref[1]);
            }
    else if (face == 3)     // rechts: 90°-Drehung
        translate([wall_right_inner, 0, 0]) rotate([0, 0, 90])
            for (w = walls) {
                ref = licht_ref(wall_right_inner, w[0]);
                inner_wall(w[0], w[1],
                           wall_right_inner - (ref[0] + licht_w/2), ref[1]);
            }
}

// ── Hauptgeometrie ────────────────────────────────────────────────────────────
// Druckorientierung: Modell um die X-Achse kippen, so dass die Dachfläche
// (ursprünglich Oberkante bei z=room_height) flach auf dem Druckbett (z=0) liegt.

translate([0, room_depth, 0]) rotate([180, 0, 0])
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
            color([0,0,0.5]) cube([room_width - po_le - po_ri, room_depth - po_fr - po_ba, dachwand]);
        for (l = licht)
            licht_transform(l)
                translate([l[0] - licht_w/2, l[1] - licht_d/2, room_height - dachwand - 0.1])
                    cube([licht_w, licht_d, dachwand + 0.2]);
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

    // Tunnel-Struktur für jeden Dachausschnitt
    for (l = licht)
        licht_transform(l)
            color([1, 0.4, 0]) tunnel(l);

    // Innenwände
    color([0.5, 0.5, 0.8]) {
        inner_walls_place(0, front_walls);
        inner_walls_place(1, back_walls);
        inner_walls_place(2, left_walls);
        inner_walls_place(3, right_walls);
        poly_walls_draw(poly_walls);
        named_walls_draw(is_undef(named_walls) ? [] : named_walls);
    }

    // Randrahmen für jeden Dachausschnitt
    for (l = licht)
        licht_transform(l)
            color([0.8, 0.8, 0]) licht_border(l);

    // Zapfen der Stapelecken ab dem ersten Obergeschoss
    if (geschoss_nr > 0)
        color([0.8, 0.8, 0]) ecken_pin();
} // union

// Aussparungen der Stapelecken, sobald ein Stockwerk angegeben ist
if (geschoss_nr >= 0)
    ecken_cut();

// Kabelschlitz global schneiden
for (l = licht)
    licht_transform(l) mode_switch(l);

for (t = texts)
    translate([t[1], t[2], room_height - dachwand + 0.4])
        rotate([0, 0, t[3]])
            linear_extrude(height = dachwand)
                text(t[0], size = 5);

} // difference
