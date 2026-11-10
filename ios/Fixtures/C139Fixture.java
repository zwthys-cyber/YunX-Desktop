// SPDX-License-Identifier: AGPL-3.0-only
// Independent Java/JCE wire vectors, executed only by the GitHub macOS test script.
import java.nio.charset.StandardCharsets;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;
import java.io.ByteArrayOutputStream;
import java.util.zip.GZIPOutputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;
import javax.crypto.spec.IvParameterSpec;

class C139Fixture {
    static String md5(String text) throws Exception {
        StringBuilder output = new StringBuilder();
        for (byte b : MessageDigest.getInstance("MD5").digest(text.getBytes(StandardCharsets.UTF_8))) output.append(String.format("%02x", b & 255));
        return output.toString();
    }
    static String encrypt(byte[] data) throws Exception {
        byte[] iv = new byte[16]; for (int i=0;i<16;i++) iv[i]=(byte)i;
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec("PVGDwmcvfs1uV3d1".getBytes(StandardCharsets.UTF_8), "AES"), new IvParameterSpec(iv));
        ByteArrayOutputStream combined = new ByteArrayOutputStream(); combined.write(iv); combined.write(cipher.doFinal(data));
        return Base64.getEncoder().encodeToString(combined.toByteArray());
    }
    public static void main(String[] args) throws Exception {
        String plain = "{\"name\":\"中文 !'()*~+\",\"page\":1}", timestamp = "2026-11-10 08:09:10", random = "aBcD0123456789xy";
        String encoded = URLEncoder.encode(plain, "UTF-8").replace("+", "%20").replace("%21", "!").replace("%27", "'").replace("%28", "(").replace("%29", ")").replace("%2A", "*");
        char[] sorted = encoded.toCharArray(); Arrays.sort(sorted);
        String base64 = Base64.getEncoder().encodeToString(new String(sorted).getBytes(StandardCharsets.UTF_8));
        String sign = md5(md5(base64) + md5(timestamp + ":" + random)).toUpperCase(java.util.Locale.ROOT);
        ByteArrayOutputStream gzip = new ByteArrayOutputStream();
        try (GZIPOutputStream out = new GZIPOutputStream(gzip)) { out.write(plain.getBytes(StandardCharsets.UTF_8)); }
        System.out.println("{\"plainBase64\":\"" + Base64.getEncoder().encodeToString(plain.getBytes(StandardCharsets.UTF_8)) + "\",\"cipher\":\"" + encrypt(plain.getBytes(StandardCharsets.UTF_8)) + "\",\"gzipCipher\":\"" + encrypt(gzip.toByteArray()) + "\",\"timestamp\":\"" + timestamp + "\",\"random\":\"" + random + "\",\"sign\":\"" + sign + "\"}");
    }
}
