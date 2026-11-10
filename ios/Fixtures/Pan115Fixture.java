// SPDX-License-Identifier: AGPL-3.0-only
// Independent BigInteger reference; generated synthetic RSA key has no platform credentials.
import java.nio.charset.StandardCharsets;
import java.math.BigInteger;
import java.util.Base64;
import java.util.Arrays;
import java.io.ByteArrayOutputStream;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPrivateCrtKey;

class Pan115Fixture {
    static final int[] TABLE = {0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5};
    static final byte[] LONG = {(byte)0x78,6,(byte)0xad,0x4c,0x33,(byte)0x86,0x5d,0x18,0x4c,1,0x3f,0x46};
    static final String MODULUS = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683";
    static byte[] derive(byte[] seed, int size) {
        byte[] result = new byte[size];
        for (int i=0;i<size;i++) result[i]=(byte)((((seed[i%seed.length]&255)+TABLE[size*i])&255)^TABLE[size*(size-1-i)]);
        return result;
    }
    static void xor(byte[] data, byte[] key) {
        int offset = data.length % 4;
        for (int i=0;i<data.length;i++) data[i]^=key[(i<offset?i:i-offset)%key.length];
    }
    static void reverse(byte[] data) { for (int i=0,j=data.length-1;i<j;i++,j--) { byte value=data[i];data[i]=data[j];data[j]=value; } }
    static byte[] transform(byte[] data, BigInteger modulus, BigInteger exponent, int type) throws Exception {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        for (int offset=0;offset<data.length;offset+=117) {
            int count=Math.min(117,data.length-offset), separator=127-count;
            byte[] block=new byte[128]; Arrays.fill(block,(byte)0xff); block[0]=0;block[1]=(byte)type;block[separator]=0;
            System.arraycopy(data,offset,block,separator+1,count);
            byte[] raw=new BigInteger(1,block).modPow(exponent,modulus).toByteArray(), fixed=new byte[128];
            int size=Math.min(raw.length,128);System.arraycopy(raw,raw.length-size,fixed,128-size,size);result.write(fixed);
        }
        return result.toByteArray();
    }
    static byte[] combine(byte[] a, byte[] b) { byte[] result=Arrays.copyOf(a,a.length+b.length);System.arraycopy(b,0,result,a.length,b.length);return result; }
    static String b64(byte[] data) { return Base64.getEncoder().encodeToString(data); }
    public static void main(String[] args) throws Exception {
        byte[] key=new byte[16], salt=new byte[16];for(int i=0;i<16;i++){key[i]=(byte)i;salt[i]=(byte)(31-i);}
        String payload="{\"pickcode\":\"fixture-long-"+"abcdef".repeat(40)+"\"}";
        byte[] request=payload.getBytes(StandardCharsets.UTF_8);xor(request,derive(key,4));reverse(request);xor(request,LONG);
        String requestEncoded=b64(transform(combine(key,request),new BigInteger(MODULUS,16),BigInteger.valueOf(65537),2));
        KeyPairGenerator generator=KeyPairGenerator.getInstance("RSA");generator.initialize(1024);
        RSAPrivateCrtKey privateKey=(RSAPrivateCrtKey)generator.generateKeyPair().getPrivate();
        String response="{\"42\":{\"file_name\":\"中文 fixture\",\"file_size\":10,\"url\":{\"url\":\"https://cdn.example.test/"+"segment".repeat(25)+"\"}}}";
        byte[] body=response.getBytes(StandardCharsets.UTF_8);xor(body,derive(key,4));reverse(body);xor(body,derive(salt,12));
        String responseEncoded=b64(transform(combine(salt,body),privateKey.getModulus(),privateKey.getPrivateExponent(),1));
        System.out.println("{\"key\":\""+b64(key)+"\",\"requestPayload\":\""+b64(payload.getBytes(StandardCharsets.UTF_8))+"\",\"requestEncoded\":\""+requestEncoded+"\",\"syntheticModulus\":\""+privateKey.getModulus().toString(16)+"\",\"responseEncoded\":\""+responseEncoded+"\",\"responsePlain\":\""+b64(response.getBytes(StandardCharsets.UTF_8))+"\"}");
    }
}
