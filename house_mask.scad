// Hausmaske mit Fenster- und Türöffnungen aus CSV-Daten
// Aufruf: python3 server.py --parse sample.csv > house_data.scad
// Dann diese Datei in OpenSCAD öffnen.

include <house_data.scad>

// ── Konstanten ────────────────────────────────────────────────────────────────
licht_h = 1.1; // Einstecktiefe Lichtausschnitt von Dachoberkante [mm]
tunnel_w   = 15;   // Tunnel Innenbreite (X) [mm]
tunnel_d   = 6;    // Tunnel Innentiefe  (Y) [mm]

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
// licht = [[cx, cy, rotation, slot_mode], ...]
// cx/cy = Mittelpunkt des Ausschnitts, absolute SCAD-Koordinaten vom Körperursprung (0,0).
// Ohne Datenwerte im licht-Abschnitt → automatisch zentriert (server.py).

// Referenz-Eintrag für Innenwand-Logik (erster Eintrag)
licht_cx = len(licht) > 0 ? licht[0][0] : 0;
licht_cy = len(licht) > 0 ? licht[0][1] : 0;
licht_x  = licht_cx - licht_w / 2;
licht_y  = licht_cy - licht_d / 2;

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
// Aufbau: Vorder-/Hinterwand (15mm in X), center_fins (bei licht_cx in Y),
// Würfel 5×5×5mm außen links und rechts (ab Innenmass).

module tunnel(l) {
    cx  = l[0];   cy  = l[1];
    lx  = cx - licht_w / 2;
    ly  = cy - licht_d / 2;
    tw  = tunnel_w / 2;
    td  = tunnel_d / 2;
    // 1mm Abstand für Platinenauflage
    h   = room_height - licht_h;

    difference() {
        union() {
            // Standfuss - solider Würfel bildet Pfeiler + X-Wände
            translate([cx - 12.5, cy - td - innenwand, 0])
                cube([25, tunnel_d + 2*innenwand, h]);

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
            cube([15, 6, h + 0.2]);

        // Durchgangslöcher Ø2.5mm von oben durch Würfel und Seitenwände
        translate([cx - tw - 2.5, cy, -1])
            cylinder(h=room_height + 2, d=2.5, $fn=32);
        translate([cx + tw + 2.5, cy, -1])
            cylinder(h=room_height + 2, d=2.5, $fn=32);
    }
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
module inner_walls_place(face, walls) {
    if (face == 0)          // vorne: keine Drehung, nach innen = +Y
        translate([0, wall_front_inner, 0])
            for (w = walls)
                inner_wall(w[0], w[1], licht_y - wall_front_inner, licht_cx);
    else if (face == 1)     // hinten: an Y gespiegelt
        translate([0, wall_back_inner, 0]) mirror([0, 1, 0])
            for (w = walls)
                inner_wall(w[0], w[1], wall_back_inner - (licht_y + licht_d), licht_cx);
    else if (face == 2)     // links: X↔Y getauscht (Spiegelung)
        translate([wall_left_inner, 0, 0]) mirror([1, 0, 0]) rotate([0, 0, 90])
            for (w = walls)
                inner_wall(w[0], w[1], licht_x - wall_left_inner, licht_cy);
    else if (face == 3)     // rechts: 90°-Drehung
        translate([wall_right_inner, 0, 0]) rotate([0, 0, 90])
            for (w = walls)
                inner_wall(w[0], w[1], wall_right_inner - (licht_x + licht_w), licht_cy);
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
} // union

// Kabelschlitz global schneiden
for (l = licht)
    licht_transform(l) mode_switch(l);

for (t = texts)
    translate([t[1], t[2], room_height - 0.4])
        rotate([0, 0, t[3]])
            linear_extrude(height = 0.5)
                text(t[0], size = 5);

} // difference
