// SPDX-License-Identifier: GPL-3.0-only
/* Scoped EDAT v3 adapter: Hykem (C) 2014, GPLv3. See ThirdParty/NPData. */
static const uint8_t EDAT_KEY_0[16] = {0xBE, 0x95, 0x9C, 0xA8, 0x30, 0x8D, 0xEF, 0xA2, 0xE5, 0xE1, 0x80, 0xC6, 0x37, 0x12, 0xA9, 0xAE};
static const uint8_t RAP_KEY[16] = {0x86, 0x9F, 0x77, 0x45, 0xC1, 0x3F, 0xD8, 0x90, 0xCC, 0xF2, 0x91, 0x88, 0xE3, 0xCC, 0x3E, 0xDF};
static const uint8_t RAP_PBOX[16] = {0x0C, 0x03, 0x06, 0x04, 0x01, 0x0B, 0x0F, 0x08, 0x02, 0x07, 0x00, 0x05, 0x0A, 0x0E, 0x0D, 0x09};
static const uint8_t RAP_E1[16] = {0xA9, 0x3E, 0x1F, 0xD6, 0x7C, 0x55, 0xA3, 0x29, 0xB7, 0x5F, 0xDD, 0xA6, 0x2A, 0x95, 0xC7, 0xA5};
static const uint8_t RAP_E2[16] = {0x67, 0xD4, 0x5D, 0xA3, 0x29, 0x6D, 0x00, 0x6A, 0x4E, 0x7C, 0x53, 0x7B, 0xF5, 0x53, 0x8C, 0x74};
static const uint8_t vmc_key[16] = { 0x64, 0xE3, 0x0D, 0x19, 0xA1, 0x69, 0x41, 0xD6, 0x77, 0xE3, 0x2E, 0xEB, 0xE0, 0x7F, 0x45, 0xD2 };
static void fixed_key(const char *path,uint8_t key[16]) {
    struct stat st;int fd=open_input(path,&st);if(st.st_size!=16)fail("Key/RAP file must be exactly 16 bytes.");read_exact(fd,key,16);close(fd);
}
static void rap_decode(const uint8_t rap[16],uint8_t key[16]) {
    aes_cbc(kCCDecrypt,RAP_KEY,rap,16,key);
    for(int round=0;round<5;++round) {
        for(int i=0;i<16;++i)key[RAP_PBOX[i]]^=RAP_E1[RAP_PBOX[i]];
        for(int i=15;i>=1;--i)key[RAP_PBOX[i]]^=key[RAP_PBOX[i-1]];
        int borrow=0;
        for(int i=0;i<16;++i) {int p=RAP_PBOX[i];uint8_t value=key[p]-borrow,sub=RAP_E2[p];if(borrow!=1||value!=255) {borrow=value<sub;key[p]=value-sub;}else key[p]=value-sub;}
    }
}
static void build_edat(const char *gameid,const char *target,const char *keypath,const char *rappath,const char *cid) {
    validate_cid(cid);if(strlen(gameid)!=9)fail("EDAT requires a nine-character game identifier.");
    for(int i=0;i<9;++i)if(!((gameid[i]>='A'&&gameid[i]<='Z')||(gameid[i]>='0'&&gameid[i]<='9')))fail("Invalid game identifier.");
    uint8_t file[320]={0},license[16],rap[16],rif[16],devkey[16],message[64]={0};fixed_key(keypath,license);fixed_key(rappath,rap);rap_decode(rap,rif);
    memcpy(file,"NPD\0",4);put(file+4,3,4);put(file+8,2,4);put(file+12,1,4);memcpy(file+16,cid,36);arc4random_buf(file+64,16);
    memcpy(message,file+16,48);memcpy(message+48,"ISO.BIN.EDAT",12);cmac(npd_omac_key3,message,60,file+80);
    for(int i=0;i<16;++i)devkey[i]=license[i]^npd_omac_key2[i];cmac(devkey,file,96,file+96);
    put(file+128,0x3c,4);put(file+132,16384,4);put(file+136,10,8);
    uint8_t blockkey[16]={0},result[16],hashkey[20]={0},key[16],hash[20],plain[16]={0};
    memcpy(blockkey,file+96,12);aes_cbc(kCCEncrypt,rif,blockkey,16,result);aes_cbc(kCCEncrypt,rif,result,16,hashkey);
    aes_cbc(kCCDecrypt,EDAT_KEY_0,result,16,key);aes_cbc(kCCDecrypt,EDAT_KEY_0,hashkey,16,hashkey);
    memcpy(plain,gameid,4);plain[4]='_';memcpy(plain+5,gameid+4,5);
    size_t written=0;if(CCCrypt(kCCEncrypt,kCCAlgorithmAES,0,key,16,file+64,plain,16,file+288,16,&written)!=kCCSuccess||written!=16)fail("EDAT encryption failed.");
    CCHmac(kCCHmacAlgSHA1,hashkey,20,file+288,16,hash);arc4random_buf(file+272,16);memcpy(file+272,hash+16,4);
    for(int i=0;i<16;++i)file[256+i]=hash[i]^file[272+i];
    aes_cbc(kCCDecrypt,EDAT_KEY_0,rif,16,key);cmac(key,file+256,32,file+144);cmac(key,file,160,file+160);
    // Matches make_npdata: placeholders, not Sony ECDSA signatures. CFW/HEN-style packages only.
    arc4random_buf(file+176,80);memcpy(file+304,"EDATA 3.3.0.W\0\0\0",16);
    int out=create_output(target,sizeof(file));write_exact(out,file,sizeof(file));seek_to(out,0);uint8_t check[320];read_exact(out,check,320);if(memcmp(check,file,320))fail("EDAT write-back mismatch.");finish_output(out,target);puts("{\"stage\":\"complete\",\"locallyVerified\":true}");
}
static void memory_card(const char *source,const char *target,int encrypt) {
    struct stat st;int in=open_input(source,&st);uint64_t size=(uint64_t)st.st_size;
    int valid=0;for(unsigned mb=8;mb<=64;mb*=2)if(size==(uint64_t)mb*1024*1024/512*528 || size==(uint64_t)mb*1024*1024/512*528+SEG)valid=1;
    if(!valid)fail("Supported cards are 8/16/32/64 MiB PS2 cards with 528-byte pages (ECC included).");
    uint8_t data[SEG],original[SEG],expected[32],actual[32];
    read_exact(in,data,SEG);if(!encrypt)aes_cbc(kCCDecrypt,vmc_key,data,SEG,data);
    if(memcmp(data,"Sony PS2 Memory Card Format ",27))fail("Memory-card header is not recognized. Original remains unchanged.");seek_to(in,0);
    int out=create_output(target,size);CC_SHA256_CTX sha;CC_SHA256_Init(&sha);uint64_t position=0;int last=-1;
    while(position<size) {size_t n=size-position<SEG?(size_t)(size-position):SEG;read_exact(in,data,n);CC_SHA256_Update(&sha,data,(CC_LONG)n);aes_cbc(encrypt?kCCEncrypt:kCCDecrypt,vmc_key,data,n,data);write_exact(out,data,n);position+=n;int pct=(int)(position*100/size);if(pct!=last){progress("memory card",position,size);last=pct;}}
    CC_SHA256_Final(expected,&sha);if(fsync(out))fail("Card output flush failed.");seek_to(out,0);position=0;CC_SHA256_Init(&sha);
    while(position<size){size_t n=size-position<SEG?(size_t)(size-position):SEG;read_exact(out,data,n);aes_cbc(encrypt?kCCDecrypt:kCCEncrypt,vmc_key,data,n,original);CC_SHA256_Update(&sha,original,(CC_LONG)n);position+=n;}
    CC_SHA256_Final(actual,&sha);if(memcmp(actual,expected,32))fail("Memory-card round-trip verification failed.");unchanged(in,&st);close(in);finish_output(out,target);puts("{\"stage\":\"complete\",\"locallyVerified\":true}");
}
