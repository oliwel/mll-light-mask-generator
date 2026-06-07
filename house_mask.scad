// Hausmaske mit Fenster- und Türöffnungen aus CSV-Daten
// Aufruf: python3 server.py --parse sample.csv > house_data.scad
// Dann diese Datei in OpenSCAD öffnen.

include <house_data.scad>

// ── Konstanten ────────────────────────────────────────────────────────────────
licht_w    = 40;   // Dachausschnitt Breite [mm]
licht_d    = 35;   // Dachausschnitt Tiefe  [mm]
tunnel_w   = 15;   // Tunnel Innenbreite (X) [mm]
tunnel_d   = 6;    // Tunnel Innentiefe  (Y) [mm]
licht_tiefe = 1.2; // Einstecktiefe Lichtausschnitt von Dachoberkante [mm]

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
// licht = [[x, y, rotation], ...]
// x/y = Abstand von links vorne (Außenwand) zur linken unteren Ecke des Ausschnitts.
// Ohne Datenwerte im licht-Abschnitt → automatisch zentriert (server.py).

// Referenz-Eintrag für Innenwand-Logik (erster Eintrag)
licht_x  = len(licht) > 0 ? licht[0][0] : 0;
licht_y  = len(licht) > 0 ? licht[0][1] : 0;
licht_cx = licht_x + licht_w / 2;
licht_cy = licht_y + licht_d / 2;

module licht_transform(l) {
    cx = l[0] + licht_w / 2;
    cy = l[1] + licht_d / 2;
    translate([cx, cy, 0])
        rotate([0, 0, l[2]])
            translate([-cx, -cy, 0])
                children();
}

// ── Wandöffnungen ─────────────────────────────────────────────────────────────
// Koordinatenreferenz: linke untere Ecke von außen
// w = [x_von_links, y_ab_boden, breite, hoehe]
// Negativer x-Offset: von der gegenüberliegenden Seite, Referenzkante rechts/oben

module front_cuts(windows) {
    for (w = windows) {
        x = w[0] >= 0 ? w[0] : room_width + w[0] - w[2];
        translate([x, po_fr - 0.1, w[1]])
            cube([w[2], aussenwand + 0.2, w[3]]);
    }
}

module back_cuts(windows) {
    for (w = windows) {
        x = w[0] >= 0 ? room_width - w[0] - w[2] : -w[0] - w[2];
        translate([x, room_depth - po_ba - aussenwand - 0.1, w[1]])
            cube([w[2], aussenwand + 0.2, w[3]]);
    }
}

module left_cuts(windows) {
    for (w = windows) {
        y = w[0] >= 0 ? room_depth - w[0] - w[2] : -w[0] - w[2];
        translate([po_le - 0.1, y, w[1]])
            cube([aussenwand + 0.2, w[2], w[3]]);
    }
}

module right_cuts(windows) {
    for (w = windows) {
        y = w[0] >= 0 ? w[0] : room_depth + w[0] - w[2];
        translate([room_width - po_ri - aussenwand - 0.1, y, w[1]])
            cube([aussenwand + 0.2, w[2], w[3]]);
    }
}

// ── Tunnel-Struktur ───────────────────────────────────────────────────────────
// Zentriert im Dachausschnitt; Innenmasse tunnel_w × tunnel_d.
// Aufbau: Vorder-/Hinterwand (15mm in X), center_fins (bei licht_cx in Y),
// Würfel 5×5×5mm außen links und rechts (ab Innenmass).

module tunnel(l) {
    lx  = l[0];   ly  = l[1];
    cx  = lx + licht_w / 2;
    cy  = ly + licht_d / 2;
    tw  = tunnel_w / 2;
    td  = tunnel_d / 2;
    h   = room_height - 1.2;
    lhd = licht_d / 2;

    difference() {
        union() {
            // Vorderwand: 15mm in X, innenwand tief, volle Höhe
            translate([cx - 12.5, cy - td - innenwand, 0])
                cube([25, tunnel_d + 2*innenwand, h]);
            
            translate([lx - innenwand , cy - innenwand/2, 0])
                cube([ licht_w + 2 * innenwand, innenwand, h]);
            
            // center_fin forward: von Vorderkante Cutout+Rahmen bis Tunnel-Vorderwand
            translate([cx - innenwand/2, ly - innenwand, 0])
                cube([innenwand, lhd - td, h]);

            // center_fin backward: von Hinterwand Tunnel bis Hinterkante Cutout + innenwand
            translate([cx - innenwand/2, cy + td + innenwand, 0])
                cube([innenwand, lhd - td, h]);

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
// 2mm hoch, innenwand breit. Kabelschlitz wird global geschnitten (cable_slot).

module licht_border(l) {
    lx = l[0]; ly = l[1];
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

module cable_slot(l) {
    cx = l[0] + licht_w / 2;
    ly = l[1];
    translate([cx - 2.5, ly - 3, room_height - 2.5])
        cube([5, 8, 3]);
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

// ── Innenwände ────────────────────────────────────────────────────────────────
// walls = [[pos, laenge], ...] — laenge=-1 → auto

module walls_from_front(walls) {
    for (w = walls) {
        p   = w[0];
        len = w[1];
        if (len != -1) {
            translate([p - innenwand/2, wall_front_inner, 0])
                cube([innenwand, len, room_height]);
        } else {
            // Wand bis zum Randrahmen (licht_y), überlappt border-Vorderwand
            translate([p - innenwand/2, wall_front_inner, 0])
                cube([innenwand, licht_y - wall_front_inner, room_height]);
            // Querelement bei Y=licht_y-innenwand von p nach licht_cx (verbindet center_fin)
            x0 = min(p, licht_cx) - innenwand/2;
            translate([x0, licht_y - innenwand, 0])
                cube([abs(p - licht_cx) + innenwand, innenwand, room_height]);
        }
    }
}

module walls_from_back(walls) {
    for (w = walls) {
        p   = w[0];
        len = w[1];

        if (len != -1) {
            translate([p - innenwand/2, wall_back_inner - len, 0])
                cube([innenwand, len, room_height]);
        } else {
            // Wand bis zum hinteren Randrahmen, überlappt border-Hinterwand
            eff = wall_back_inner - (licht_y + licht_d - innenwand);
            translate([p - innenwand/2, licht_y + licht_d, 0])
                cube([innenwand, eff, room_height]);
            // Querelement bei Y=licht_y+licht_d von p nach licht_cx
            x0 = min(p, licht_cx) - innenwand/2;
            translate([x0, licht_y + licht_d, 0])
                cube([abs(p - licht_cx) + innenwand, innenwand, room_height]);
        }
    }
}

module walls_from_left(walls) {
    for (w = walls) {
        p   = w[0];
        len = w[1];
        if (len != -1) {
            translate([wall_left_inner, p - innenwand/2, 0])
                cube([len, innenwand, room_height]);
        } else {
            // Wand bis linkem Randrahmen
            eff = licht_x - wall_left_inner + innenwand;
            translate([wall_left_inner - aussenwand, p - innenwand/2, 0])
                cube([eff, innenwand, room_height]);
            // Querelement bei X=licht_x-innenwand von p nach licht_cy
            y0 = min(p, licht_cy) - innenwand/2;
            translate([licht_x - innenwand, y0, 0])
                cube([innenwand, abs(p - licht_cy) + innenwand, room_height]);
        }
    }
}

module walls_from_right(walls) {
    for (w = walls) {
        p   = w[0];
        len = w[1];
        if (len != -1) {
            translate([wall_right_inner - len, p - innenwand/2, 0])
                cube([len, innenwand, room_height]);
        } else {
            // Wand bis rechtem Randrahmen
            eff = wall_right_inner - (licht_x + licht_w - innenwand);
            translate([licht_x + licht_w, p - innenwand/2, 0])
                cube([eff, innenwand, room_height]);
            // Querelement bei X=licht_x+licht_w von p nach licht_cy
            y0 = min(p, licht_cy) - innenwand/2;
            translate([licht_x + licht_w, y0, 0])
                cube([innenwand, abs(p - licht_cy) + innenwand, room_height]);

        }
    }
}

// ── Hauptgeometrie ────────────────────────────────────────────────────────────

difference() {
union() {
    // Hohlbox: Außenhülle minus Innenraum + Öffnungen
    difference() {
        translate([po_le, po_fr, 0])
            color([0,0,0.5]) cube([room_width - po_le - po_ri, room_depth - po_fr - po_ba, room_height]);
        translate([wall_left_inner, wall_front_inner, -dachwand])
            cube([
                wall_right_inner - wall_left_inner,
                wall_back_inner  - wall_front_inner,
                room_height
            ]);
        front_cuts(front_windows);
        back_cuts(back_windows);
        left_cuts(left_windows);
        right_cuts(right_windows);
        // Wand entfernen wenn keine Fenster/Türen
        if (len(front_windows) == 0)
            translate([po_le - 0.1, po_fr - 0.1, -0.1])
                cube([room_width - po_le - po_ri + 0.2, aussenwand + 0.2, room_height + 0.2]);
        if (len(back_windows) == 0)
            translate([po_le - 0.1, room_depth - po_ba - aussenwand - 0.1, -0.1])
                cube([room_width - po_le - po_ri + 0.2, aussenwand + 0.2, room_height + 0.2]);
        if (len(left_windows) == 0)
            translate([po_le - 0.1, po_fr - 0.1, -0.1])
                cube([aussenwand + 0.2, room_depth - po_fr - po_ba + 0.2, room_height + 0.2]);
        if (len(right_windows) == 0)
            translate([room_width - po_ri - aussenwand - 0.1, po_fr - 0.1, -0.1])
                cube([aussenwand + 0.2, room_depth - po_fr - po_ba + 0.2, room_height + 0.2]);
        
        // Decke mit Dachausschnitt.
        for (l = licht)
            licht_transform(l)
                translate([l[0], l[1], 0])
                    cube([licht_w, licht_d, room_height + 0.2]);
        for (c = dach_cuts)
            translate([c[0], c[1], room_height - dachwand - 0.1])
                cube([c[2], c[3], dachwand + 0.2]);
        
    }

    // Tunnel-Struktur für jeden Dachausschnitt
    for (l = licht)
        licht_transform(l)
            color([1, 0.4, 0]) tunnel(l);

    // Innenwände
    color([0.5, 0.5, 0.8]) {
        walls_from_front(front_walls);
        walls_from_back(back_walls);
        walls_from_left(left_walls);
        walls_from_right(right_walls);
        poly_walls_draw(poly_walls);
    }

    // Randrahmen für jeden Dachausschnitt
    for (l = licht)
        licht_transform(l)
            color([0.8, 0.8, 0]) licht_border(l);
} // union
// Kabelschlitz global schneiden
for (l = licht)
    licht_transform(l) cable_slot(l);
} // difference
