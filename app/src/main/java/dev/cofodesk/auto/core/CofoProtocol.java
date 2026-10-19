package dev.cofodesk.auto.core;

/** Outgoing frames recovered from COFO Android 1.0.10. This class never sends BLE traffic.
 * See docs/reverse-engineering.md for static Evidence and unverified incoming framing.
 */
public final class CofoProtocol {
    private CofoProtocol() {}
    public static byte[] up() { return frame(0x01); }
    public static byte[] down() { return frame(0x02); }
    public static byte[] stop() { return frame(0x2b); }
    public static byte[] requestHeight() { return frame(0x0c); }
    public static byte[] requestLimits() { return frame(0x07); }
    /** Wire field is unsigned millimetres; the transport must separately enforce device limits. */
    public static byte[] moveToMillimetres(int millimetres) {
        if (millimetres < 0 || millimetres > 0xffff) throw new IllegalArgumentException("error_height");
        return frame(0x1b, (byte) (millimetres >>> 8), (byte) millimetres);
    }
    private static byte[] frame(int opcode, byte... payload) {
        byte[] output = new byte[payload.length + 6];
        output[0] = (byte) 0xf1; output[1] = (byte) 0xf1;
        output[2] = (byte) opcode; output[3] = (byte) payload.length;
        int checksum = opcode + payload.length;
        for (int i = 0; i < payload.length; i++) {
            output[4 + i] = payload[i]; checksum += Byte.toUnsignedInt(payload[i]);
        }
        output[output.length - 2] = (byte) checksum;
        output[output.length - 1] = 0x7e;
        return output;
    }
}
