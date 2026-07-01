/* Konstanten für Kastenformat */
OPEN_NONE = 0; // Box mit fünf Seiten
OPEN_LEFT = -1; // Box mit vier Seite, vorne und links offen
OPEN_RIGHT = 1; // Box mit vier Seite, vorne und rechts offen

/*
 * LED-Öffnungstyp (Parameter "led"). Bestimmt die komplette Öffnungsgeometrie.
 * Zweiteilige Öffnungen sitzen auf der Rückwand und sind durchgehend: das innere
 * Feature (LED-/Lichtseite) ist led_membrane (0.4mm) tief, das äußere Feature
 * nimmt die restliche Wanddicke ein.
 */
LED_NONE   = 0; // keine Öffnung
LED_3MM    = 1; // durchgehender Zylinder 3mm
LED_5MM    = 2; // durchgehender Zylinder 5mm
LED_5050   = 3; // innen Zylinder 4mm, außen Ausschnitt 6x6mm (WS2812)
LED_3528   = 4; // innen Zylinder 3mm, außen Ausschnitt 4x3mm
LED_WS2812 = 5; // innen Ausschnitt 6x6mm, außen Zylinder 15mm
LED_DEFAULT = LED_5050;

/*
 * Halteclip auf der Deckenwand (Parameter "clip"), unabhängig vom Öffnungstyp.
 */
CLIP_NONE   = 0; // kein Clip
CLIP_SINGLE = 1; // ein Clip mittig über der Öffnung
CLIP_DOUBLE = 2; // zwei Clips, 14mm Abstand (je 7mm links/rechts der Mitte)
clip_dist   = 12; // Abstand der beiden Clips bei CLIP_DOUBLE

/*
 * Fläche, auf der LED-Öffnung + Clip sitzen (Parameter "face").
 * Die LED-Position wird als [u, v] relativ zur Flächenmitte (mm) angegeben:
 *   FACE_TOP:   u entlang Breite (X), v entlang Tiefe (Z)
 *   FACE_LEFT/RIGHT: u entlang Tiefe (Z), v entlang Höhe (Y)
 * u ist zugleich die Achse, entlang der die Doppelclips versetzt werden.
 */
FACE_TOP   = 0; // oben:   X-Z-Fläche bei y = +height/2 (größere Y-Koordinate)
FACE_LEFT  = 1; // links:  Y-Z-Fläche bei x = -width/2
FACE_RIGHT = 2; // rechts: Y-Z-Fläche bei x = +width/2

/* Wandstärke */
wall = 1.2;
tunnel_height = 2;
clip_spacing = 3;
clip_thick = 2.5;
/* verbleibende Materialdicke auf der Innenseite bei quadratischem Ausschnitt */
led_membrane = 0.4;
/*
 * width/height = Abmessungen des "Fensters" (Außenmass)
 * depth = Tiefe der Kiste
 * open = Kiste mit zwei offenen Seiten für Über-Eck Einbau
 * led = Öffnungstyp (LED_*), siehe Konstanten oben
 * led_offset = Abweichung der LED Position von der Mitte
 *    Zahl > 1: Offset in Einheiten von der Mitte aus
 *    Zahl < 1: relative Position auf der Wand von links außen gemessen
*/
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
 *   Wandmitte liegt bei z = 0, die Wand reicht von -wall/2 (außen) bis
 *   +wall/2 (innen); +z zeigt ins Innere der Box.
 *   through  = durchgehender Zylinder (Durchmesser) über die ganze Wand
 *   inner    = Feature auf der Innenseite, led_membrane (0.4mm) tief
 *   outer    = Feature auf der Außenseite, restliche Wanddicke
 *   inner und outer überlappen in der Wand -> durchgehende Öffnung.
 */
module led_negative( inner = undef, outer = undef, through = undef ) {
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
 * Negativform der LED-Öffnung nach Öffnungstyp (kanonische Lage, +z = innen).
 */
module led_negative_by_type( led, dist_ground ) {
    if (led == LED_3MM)         led_negative(through = 3);
    else if (led == LED_5MM)    led_negative(through = 5);
    else if (led == LED_5050)   led_negative(inner = 4,      outer = [6,6]);
    else if (led == LED_3528)   led_negative(inner = 3,      outer = [4,3]);
    else if (led == LED_WS2812) {
        led_negative(inner = [6,6],  outer = 11);
        translate([0, -5.5, -led_membrane/2]) cube([6, dist_ground, 1.1 * wall - led_membrane ],true);
    }
}

/*
 * Setzt die Kinder in kanonischer Lage auf die gewählte Fläche der Box:
 *   - Wandmitte der Fläche liegt im Ursprung der Kinder
 *   - kanonisches +z zeigt ins Box-Innere
 * pos = [u, v] verschiebt entlang der Flächenachsen (siehe FACE_* oben).
 */
module on_face( face, pos, width, height, depth ) {
    if (face == FACE_TOP)
        translate([pos[0], height/2 - wall/2, pos[1]]) rotate([90,0,0]) children();
    else if (face == FACE_RIGHT)
        translate([width/2 - wall/2, pos[1], pos[0]]) rotate([0,-90,0]) rotate([0,0,-90]) children();
    else if (face == FACE_LEFT)
        translate([-width/2 + wall/2, pos[1], pos[0]]) rotate([0,90,0]) rotate([0,0,90]) children();
}

/*
 * Halteclip, IMMER entlang Z (Tiefe) ausgerichtet, unabhängig von der Fläche.
 * Lokaler Aufbau: Außenfläche der Wand bei y = 0, Clip ragt nach +y (außen),
 * Balken läuft über die ganze Tiefe in Z.
 *   - Verbindung zum Gehäuse an der oberen Kante (z = +depth/2).
 *   - 3x3mm Pod am unteren Ende (z = -depth/2, Druckbett) als Haftungshilfe.
 */
module clip_z( depth ) {
    bar_y  = clip_spacing + clip_thick/2; // Mitte des Haltebalkens (außen)
    pod_h  = 0.2;                          // Höhe des Druck-Pods
    color([1,0,0]) {
        // Haltebalken parallel zur Wand, über die ganze Tiefe
        translate([0, bar_y, 0]) cube([3, clip_thick, depth], true);
        // Verbindung zum Gehäuse an der oberen Kante (z = +depth/2)
        translate([0, 0, depth/2])
            rotate([-90, 0, 0])
                linear_extrude(height = clip_spacing+clip_thick)
                    polygon([[4, 0], [-4,0], [-1.5, 4], [1.5, 4]]);
        // Pod auf dem Druckbett (z = -depth/2), 3x3mm, verbessert die Haftung
        translate([0, bar_y + clip_thick/2, -depth/2 + pod_h/2])
            cube([5, 5, pod_h], true);
    }
}

/*
 * Setzt einen Clip auf die Außenseite der gewählten Fläche.
 *   perp = Versatz entlang der flächeninternen Achse senkrecht zu Z
 *          (X bei FACE_TOP, Y bei FACE_LEFT/RIGHT).
 * Der Balken läuft stets entlang Z, der Fuß bleibt in der Rückseiten-Ebene.
 */
module clip_on( face, perp, width, height, depth ) {
    if (face == FACE_TOP)
        translate([perp, height/2, 0]) clip_z(depth);
    else if (face == FACE_RIGHT)
        translate([width/2, perp, 0]) rotate([0,0,-90]) clip_z(depth);
    else if (face == FACE_LEFT)
        translate([-width/2, perp, 0]) rotate([0,0,90]) clip_z(depth);
}

/*
 * Box-Körper: Außenquader mit ausgehöhltem Innenraum (vorne offen). Bei
 * open != OPEN_NONE wird zusätzlich eine Seitenwand entfernt (Über-Eck Einbau).
 */
module lightbox_body( width, height, depth, open = OPEN_NONE ) {
    shrink = (open != OPEN_NONE ? wall : (2*wall));
    move = open * wall;
    difference(){
        cube([width,height,depth],true);
        translate([move,0,wall]) cube([width-shrink,height-2*wall,depth],true);
    }
}

/*
 * Box-Körper mit beliebig vielen LED-Öffnungen + Clips. leds ist eine Liste von
 * Einträgen [face, led, u, v, clip]:
 *   face = FACE_TOP | FACE_LEFT | FACE_RIGHT
 *   led  = LED_* Öffnungstyp
 *   u, v = LED-Mitte relativ zur Flächenmitte (mm), siehe on_face / FACE_*
 *   clip = CLIP_NONE | CLIP_SINGLE | CLIP_DOUBLE
 */
module lightbox_multi( width, height, depth, open = OPEN_NONE, leds = [] ) {
    translate([0,0,depth/2])
    union() {
        difference() {
            lightbox_body(width, height, depth, open);
            for (m = leds)
                on_face(m[0], [m[2], m[3]], width, height, depth)
                    led_negative_by_type(m[1], depth/2 - m[2]);
        }
        for (m = leds) {
            face = m[0];
            clip = m[4];
            // Clip-Versatz entlang der Achse senkrecht zu Z (= LED-Achse):
            // X bei FACE_TOP (u), Y bei FACE_LEFT/RIGHT (v).
            clip_perp = (face == FACE_TOP) ? m[2] : m[3];
            if (clip == CLIP_SINGLE)
                clip_on(face, clip_perp, width, height, depth);
            else if (clip == CLIP_DOUBLE)
                for (s = [-1, 1])
                    clip_on(face, clip_perp + s*clip_dist/2, width, height, depth);
        }
    }
}

module lightbox( width = 20, height = 25, depth = 15, open = OPEN_NONE, led = LED_DEFAULT, led_pos = [0,0], clip = CLIP_NONE, face = FACE_TOP ) {
    lightbox_multi(width, height, depth, open, [[face, led, led_pos[0], led_pos[1], clip]]);
}


module clibox() {
    width = 20;
    height = 15;
    depth = 20;
    open = OPEN_NONE;
    led = LED_WS2812;
    led_pos = [0,0];
    clip = CLIP_DOUBLE;
    face = FACE_TOP;

    lightbox( width = width, height = height, depth = depth, open = open, led = led, led_pos = led_pos, clip = clip, face = face );
}

// Wird box_data.scad vor dieser Datei eingebunden (include), so liefert es
// box_dims/box_leds und der Generator rendert daraus. Ohne diese Daten dient
// die Datei als Standalone-Testfall (clibox).
if (is_undef(box_leds))
    clibox();
else
    lightbox_multi(box_dims[0], box_dims[1], box_dims[2],
                   is_undef(box_open) ? OPEN_NONE : box_open, box_leds);
