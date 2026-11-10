// SPDX-License-Identifier: AGPL-3.0-only
// Independent Java reference using the desktop backup's actual JCE primitives.
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;

class BackupFixture {
    public static void main(String[] args) throws Exception {
        String plain = "{\"app\":\"yunx_auth_backup\",\"version\":1,\"accounts\":[{\"platform\":\"quark\",\"cookie\":\"test-only-cookie=fixture\",\"nickname\":\"测试账号\"}]}";
        String password = "fixture-密码-123";
        System.out.print("{\"v1\":\"" + encrypt(plain, password, 1) + "\",\"v2\":\"" + encrypt(plain, password, 2) + "\"}");
    }
    static String encrypt(String plain, String password, int version) throws Exception {
        byte[] salt = new byte[16], iv = new byte[12];
        for (int i = 0; i < salt.length; i++) salt[i] = (byte)i;
        for (int i = 0; i < iv.length; i++) iv[i] = (byte)(i + 20);
        PBEKeySpec spec = new PBEKeySpec(password.toCharArray(), salt, version == 1 ? 10000 : 210000, 256);
        byte[] key = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        byte[] encrypted = cipher.doFinal(plain.getBytes(StandardCharsets.UTF_8));
        byte[] magic = ("YUNX_AUTH_V" + version).getBytes(StandardCharsets.UTF_8);
        byte[] result = new byte[magic.length + salt.length + iv.length + encrypted.length];
        int pos = 0;
        for (byte[] part : new byte[][]{magic, salt, iv, encrypted}) {
            System.arraycopy(part, 0, result, pos, part.length); pos += part.length;
        }
        return Base64.getEncoder().encodeToString(result);
    }
}
