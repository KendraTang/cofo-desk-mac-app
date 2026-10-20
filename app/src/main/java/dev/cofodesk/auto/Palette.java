package dev.cofodesk.auto;

import android.graphics.Color;

/** App colours for the light or dark theme. */
record Palette(int accent, int ink, int muted, int surface, int background, int button, int line, int leg) {
    static Palette of(boolean dark) {
        return dark
                ? new Palette(0xff90b8ff, 0xffe6edf8, 0xffb0bed3, 0xff1b2638, 0xff101827, 0xff263a58, 0xff36465e, 0xff91a6c5)
                : new Palette(0xff246bdf, 0xff1d2a3e, 0xff66778e, Color.WHITE, 0xfff4f7fc, 0xffedf3fd, 0xffe0e7f2, 0xff869ec4);
    }
}
