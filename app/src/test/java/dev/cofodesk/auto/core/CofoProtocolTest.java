package dev.cofodesk.auto.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class CofoProtocolTest {
    @Test public void controlFramesMatchOriginalStaticConstants() {
        assertArrayEquals(hex("F1 F1 01 00 01 7E"), CofoProtocol.up());
        assertArrayEquals(hex("F1 F1 02 00 02 7E"), CofoProtocol.down());
        assertArrayEquals(hex("F1 F1 2B 00 2B 7E"), CofoProtocol.stop());
    }
    @Test public void queriesMatchOriginalInitializationFrames() {
        assertArrayEquals(hex("F1 F1 0C 00 0C 7E"), CofoProtocol.requestHeight());
        assertArrayEquals(hex("F1 F1 07 00 07 7E"), CofoProtocol.requestLimits());
    }
    @Test public void targetUsesMillimetresAndBigEndianPayload() {
        assertArrayEquals(hex("F1 F1 1B 02 04 1A 3B 7E"), CofoProtocol.moveToMillimetres(1050));
        assertArrayEquals(hex("F1 F1 1B 02 01 00 1E 7E"), CofoProtocol.moveToMillimetres(256));
    }
    @Test public void checksumWrapsUnsignedBytesAndFieldLimitsAreExplicit() {
        assertArrayEquals(hex("F1 F1 1B 02 FF FF 1B 7E"), CofoProtocol.moveToMillimetres(65535));
        assertThrows(IllegalArgumentException.class, () -> CofoProtocol.moveToMillimetres(-1));
        assertThrows(IllegalArgumentException.class, () -> CofoProtocol.moveToMillimetres(65536));
    }
    private static byte[] hex(String text) {
        String[] parts = text.split(" "); byte[] bytes = new byte[parts.length];
        for (int i = 0; i < parts.length; i++) bytes[i] = (byte) Integer.parseInt(parts[i], 16);
        return bytes;
    }
}
