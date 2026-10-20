package dev.cofodesk.auto;

/** One tab's views. The Activity calls refresh on every tick while the page is shown. */
interface Page {
    void refresh();
}
