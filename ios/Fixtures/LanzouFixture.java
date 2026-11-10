// SPDX-License-Identifier: AGPL-3.0-only
class LanzouFixture {
    public static void main(String[] args) {
        int[] positions={15,35,29,24,33,16,1,38,10,9,19,31,40,27,22,23,25,13,6,11,39,18,20,8,14,21,32,26,2,30,7,4,17,5,3,28,34,37,12,36};
        String arg="0123456789abcdef0123456789abcdef01234567", mask="3000176000856006061501533003690027800375";
        StringBuilder rearranged=new StringBuilder(), result=new StringBuilder();
        for(int position:positions) rearranged.append(arg.charAt(position-1));
        for(int i=0;i<40;i+=2) result.append(String.format("%02x", Integer.parseInt(rearranged.substring(i,i+2),16)^Integer.parseInt(mask.substring(i,i+2),16)));
        System.out.println("{\"arg\":\""+arg+"\",\"cookie\":\""+result+"\"}");
    }
}
