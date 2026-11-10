// SPDX-License-Identifier: AGPL-3.0-only
// Independent reference for ILanzou's desktop AES/ECB/PKCS5Padding parameters.
import java.nio.charset.StandardCharsets;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

class ILanzouFixture {
    public static void main(String[] args) throws Exception {
        String[] cases = {"1700000000123", "123|456", "123|", "中文|123"};
        StringBuilder output = new StringBuilder("[");
        for (int i = 0; i < cases.length; i++) {
            Cipher cipher = Cipher.getInstance("AES/ECB/PKCS5Padding");
            cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec("lanZouY-disk-app".getBytes(StandardCharsets.UTF_8), "AES"));
            byte[] encrypted = cipher.doFinal(cases[i].getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder();
            for (byte value : encrypted) hex.append(String.format("%02x", value & 255));
            if (i > 0) output.append(',');
            output.append("{\"plain\":\"").append(cases[i]).append("\",\"hex\":\"").append(hex).append("\"}");
        }
        System.out.println(output.append(']'));
    }
}
