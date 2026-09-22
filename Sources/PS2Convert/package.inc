// SPDX-License-Identifier: GPL-3.0-only
/* Native PS3 debug PKG writer. Format adapted from PSL1GHT ps3py,
 * Copyright (c) 2011 PSL1GHT Development Team, MIT. See ThirdParty/PSL1GHT. */
#include <dirent.h>
typedef struct { char name[PATH_MAX]; uint64_t size, offset; uint32_t name_offset; int directory; struct stat original; } PkgEntry;
static PkgEntry entries[1024]; static unsigned entry_count;
static uint64_t align16(uint64_t n) { return (n+15)&~(uint64_t)15; }
static void pkg_path(char path[PATH_MAX], const char *root, const char *name) {
    if(snprintf(path,PATH_MAX,"%s/%s",root,name)>=PATH_MAX) fail("Package path is too long.");
}
static void pkg_walk(const char *root,const char *relative) {
    unsigned depth=0; for(const char *p=relative;*p;++p) if(*p=='/') ++depth;
    if(depth>32) fail("Package directories are too deeply nested.");
    char path[PATH_MAX]; pkg_path(path,root,relative);
    struct dirent **list=NULL; int count=scandir(path,&list,NULL,alphasort);
    if(count<0) fail("Cannot enumerate package workspace.");
    for(int directories=0;directories<2;++directories) for(int i=0;i<count;++i) {
        const char *name=list[i]->d_name;
        if(!strcmp(name,".")||!strcmp(name,"..")) continue;
        char rel[PATH_MAX],full[PATH_MAX];
        if(snprintf(rel,sizeof(rel),"%s%s%s",relative,relative[0]?"/":"",name)>=PATH_MAX) fail("Package path too long.");
        for(size_t c=0;c<strlen(rel);++c) if((unsigned char)rel[c]<32 || (unsigned char)rel[c]>126 || rel[c]=='\\') fail("Internal package filenames must be printable ASCII.");
        pkg_path(full,root,rel); struct stat st;
        if(lstat(full,&st) || (!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode))) fail("Package workspace contains a link or unsupported file.");
        int directory=S_ISDIR(st.st_mode); if(directory!=directories) continue;
        if(entry_count>=1024) fail("Package has too many entries.");
        PkgEntry *e=&entries[entry_count++];strcpy(e->name,rel);e->directory=directory;e->size=directory?0:(uint64_t)st.st_size;e->original=st;
        if(directory) pkg_walk(root,rel);
    }
    for(int i=0;i<count;++i) free(list[i]);free(list);
}
static void pkg_crypt(uint8_t *bytes,size_t count,const uint8_t key[16],uint64_t block) {
    uint8_t context[64]={0},hash[20];memcpy(context,key,8);memcpy(context+8,key,8);memcpy(context+16,key+8,8);memcpy(context+24,key+8,8);
    for(size_t p=0;p<count;p+=16) {put(context+56,block++,8);CC_SHA1(context,64,hash);size_t n=count-p<16?count-p:16;for(size_t i=0;i<n;++i)bytes[p+i]^=hash[i];}
}
static void pkg_stream(int output,uint8_t *data,size_t size,const uint8_t key[16],uint64_t *position,CC_SHA256_CTX *sha) {
    CC_SHA256_Update(sha,data,(CC_LONG)size);pkg_crypt(data,size,key,*position/16);write_exact(output,data,size);*position+=size;
}
static void package_build(const char *root,const char *target,const char *cid) {
    validate_cid(cid);entry_count=0;pkg_walk(root,"");if(!entry_count) fail("Package workspace is empty.");
    uint64_t index_size=entry_count*32;
    for(unsigned i=0;i<entry_count;++i) {entries[i].name_offset=(uint32_t)index_size;index_size+=align16(strlen(entries[i].name));}
    uint64_t total=index_size;
    for(unsigned i=0;i<entry_count;++i) {entries[i].offset=total;total+=align16(entries[i].size);if(total>1ULL<<40)fail("Package is too large.");}
    uint8_t *index=calloc(1,(size_t)index_size),*buffer=malloc(CHUNK);if(!index||!buffer)fail("Cannot allocate package buffers.");
    for(unsigned i=0;i<entry_count;++i) {
        PkgEntry *e=&entries[i];uint8_t *p=index+i*32;put(p,e->name_offset,4);put(p+4,strlen(e->name),4);put(p+8,e->offset,8);put(p+16,e->size,8);put(p+24,e->directory?0x80000004:0x80000003,4);memcpy(index+e->name_offset,e->name,strlen(e->name));
    }
    uint8_t header[128]={0},meta[64]={0},qa[20],hs[20],ms[20],license[16]={0},pad[48]={0},pad2[48];
    put(header,0x7f504b47,4);put(header+4,1,4);put(header+8,0xc0,4);put(header+12,5,4);put(header+16,0x80,4);put(header+20,entry_count,4);put(header+24,total+0x1a0,8);put(header+32,0x140,8);put(header+40,total,8);
    CC_SHA1_CTX qactx;CC_SHA1_Init(&qactx);
    for(unsigned i=0;i<entry_count;++i) if(!entries[i].directory && entries[i].size) {
        char path[PATH_MAX];pkg_path(path,root,entries[i].name);struct stat st;int fd=open_input(path,&st);
        if(st.st_size!=entries[i].original.st_size)fail("Package source changed.");uint64_t left=entries[i].size;
        while(left) {size_t n=left<CHUNK?(size_t)left:CHUNK;read_exact(fd,buffer,n);CC_SHA1_Update(&qactx,buffer,(CC_LONG)n);left-=n;}
        unchanged(fd,&entries[i].original);close(fd);progress("package fingerprint",i+1,entry_count);
    }
    CC_SHA1_Update(&qactx,header,128);CC_SHA1_Update(&qactx,index,(CC_LONG)index_size);CC_SHA1_Final(qa,&qactx);
    memcpy(header+48,cid,strlen(cid));memcpy(header+96,qa,16);pkg_crypt(license,16,qa,UINT64_MAX);memcpy(header+112,license,16);
    const uint32_t words[]={1,4,3,2,4,6,3,4,14,4,8};for(unsigned i=0;i<11;++i)put(meta+i*4,words[i],4);
    put(meta+46,(total>>32)&0xffff,2);put(meta+48,total&0xffffffff,4);put(meta+52,5,4);put(meta+56,4,4);put(meta+60,0x1061,2);
    CC_SHA1(header,128,hs);CC_SHA1(meta,64,ms);pkg_crypt(pad,48,ms+3,0);memcpy(pad2,pad,48);pkg_crypt(pad2,48,hs+3,0);
    int out=create_output(target,total+0x1a0);write_exact(out,header,128);write_exact(out,hs+3,16);write_exact(out,pad2,48);write_exact(out,meta,64);write_exact(out,ms+3,16);write_exact(out,pad,48);
    CC_SHA256_CTX sha;CC_SHA256_Init(&sha);uint64_t position=0;pkg_stream(out,index,(size_t)index_size,qa,&position,&sha);
    for(unsigned i=0;i<entry_count;++i) if(!entries[i].directory && entries[i].size) {
        char path[PATH_MAX];pkg_path(path,root,entries[i].name);struct stat st;int fd=open_input(path,&st);uint64_t left=entries[i].size;
        if(st.st_size!=entries[i].original.st_size)fail("Package source changed.");
        while(left) {size_t n=left<CHUNK?(size_t)left:CHUNK;read_exact(fd,buffer,n);size_t padded=(size_t)align16(n);memset(buffer+n,0,padded-n);pkg_stream(out,buffer,padded,qa,&position,&sha);left-=n;progress("package",position,total);}
        unchanged(fd,&entries[i].original);close(fd);
    }
    uint8_t tail[96]={0},expected[32],actual[32];write_exact(out,tail,96);CC_SHA256_Final(expected,&sha);
    if(fsync(out))fail("Package flush failed.");seek_to(out,0x140);CC_SHA256_Init(&sha);position=0;
    while(position<total) {size_t n=total-position<CHUNK?(size_t)(total-position):CHUNK;read_exact(out,buffer,n);pkg_crypt(buffer,n,qa,position/16);CC_SHA256_Update(&sha,buffer,(CC_LONG)n);position+=n;progress("verify package",position,total);}
    CC_SHA256_Final(actual,&sha);if(memcmp(actual,expected,32))fail("Package read-back mismatch.");finish_output(out,target);free(index);free(buffer);puts("{\"stage\":\"complete\",\"locallyVerified\":true}");
}
/* Read-only verification of an already-published package. Recomputes the
 * header digests, the index, the encrypted payload and the QA/license fields
 * without writing anything, so a package found after a crash is judged on its
 * contents rather than its name. Optionally binds the result to the expected
 * content ID and title ID. Reports entries, payload bytes, entry names, the
 * package content ID and the PARAM.SFO title ID. */
static void package_verify(const char *path, const char *expected_cid, const char *expected_title) {
    if (expected_cid) validate_cid(expected_cid);
    if (expected_title && (strlen(expected_title) != 9)) fail("Expected title ID must be nine characters.");
    struct stat st; int fd=open_input(path,&st);
    uint8_t header[128], hs[20], meta[64], pad[48], pad2[48], stored[20], ms[20];
    read_exact(fd,header,128);
    if(be(header,4)!=0x7f504b47||be(header+8,4)!=0xc0||be(header+12,4)!=5||be(header+16,4)!=0x80)
        fail("Not a supported PS2 package header.");
    uint32_t count=(uint32_t)be(header+20,4);
    uint64_t declared=be(header+24,8), base=be(header+32,8), total=be(header+40,8);
    if(base!=0x140||count==0||count>1024) fail("Package header fields are out of range.");
    if(total==0||total>MAX_PAYLOAD) fail("Package payload size is out of range.");
    if((uint64_t)st.st_size!=declared||declared!=total+0x1a0) fail("Package size does not match its header.");
    char package_cid[37]; memcpy(package_cid,header+48,36); package_cid[36]=0;
    if(expected_cid && memcmp(header+48,expected_cid,36)) fail("Package content ID does not match the expected job.");
    CC_SHA1(header,128,hs);
    read_exact(fd,stored,16); if(memcmp(stored,hs+3,16)) fail("Package header digest mismatch.");
    read_exact(fd,pad2,48); read_exact(fd,meta,64); read_exact(fd,stored,16);
    CC_SHA1(meta,64,ms); if(memcmp(stored,ms+3,16)) fail("Package metadata digest mismatch.");
    read_exact(fd,pad,48);
    uint8_t recheck[48];
    /* Writer derives pad from the metadata digest, then pad2 from pad using the
     * header digest. Reproduce both exactly. */
    memset(recheck,0,48); pkg_crypt(recheck,48,ms+3,0); if(memcmp(recheck,pad,48)) fail("Package metadata padding mismatch.");
    pkg_crypt(recheck,48,hs+3,0); if(memcmp(recheck,pad2,48)) fail("Package header padding mismatch.");
    uint8_t key[16]; memcpy(key,header+96,16);
    uint64_t records=(uint64_t)count*32, capacity=records+PATH_MAX*1024;
    uint8_t *index=malloc(capacity); if(!index) fail("Cannot allocate package index buffer.");
    uint8_t *buffer=malloc(CHUNK); if(!buffer) fail("Cannot allocate package buffer.");
    /* Entry records first, only to learn the full index extent. */
    uint64_t position=0, index_size=records;
    while(position<records) { size_t n=records-position<CHUNK?(size_t)(records-position):CHUNK;
        read_exact(fd,buffer,n); pkg_crypt(buffer,n,key,position/16); memcpy(index+position,buffer,n); position+=n; }
    for(unsigned i=0;i<count;++i) {
        uint8_t *record=index+(uint64_t)i*32;
        uint32_t name_offset=(uint32_t)be(record,4), name_length=(uint32_t)be(record+4,4);
        if(name_length==0||name_length>PATH_MAX-1||name_offset<records) fail("Package entry name is invalid.");
        uint64_t end=(uint64_t)name_offset+align16(name_length);
        if(end>index_size) index_size=end;
    }
    if(index_size>capacity) fail("Package index is too large.");
    while(position<index_size) { size_t n=index_size-position<CHUNK?(size_t)(index_size-position):CHUNK;
        read_exact(fd,buffer,n); pkg_crypt(buffer,n,key,position/16); memcpy(index+position,buffer,n); position+=n; }
    CC_SHA1_CTX qa; CC_SHA1_Init(&qa);
    uint64_t sfo_offset=0, sfo_size=0; int last_percent=-1;
    for(unsigned i=0;i<count;++i) {
        uint8_t *record=index+(uint64_t)i*32;
        uint32_t name_offset=(uint32_t)be(record,4), name_length=(uint32_t)be(record+4,4);
        uint64_t offset=be(record+8,8), size=be(record+16,8); uint32_t flags=(uint32_t)be(record+24,4);
        if(offset!=position) fail("Package entry stream offset is inconsistent.");
        if(offset>total||size>total-offset||align16(size)>total-offset) fail("Package entry range is invalid.");
        for(uint32_t c=0;c<name_length;++c) {
            unsigned char ch=index[name_offset+c];
            if(ch<32||ch>126||ch=='\\') fail("Package entry name is not printable ASCII.");
        }
        int directory=(flags&0x0000000f)==4;
        if(!directory && name_length==9 && !memcmp(index+name_offset,"PARAM.SFO",9)) { sfo_offset=offset; sfo_size=size; }
        uint64_t padded=align16(size);
        while(padded) { size_t n=padded<CHUNK?(size_t)padded:CHUNK; read_exact(fd,buffer,n);
            pkg_crypt(buffer,n,key,position/16); position+=n;
            size_t actual=(size_t)(size< n ? size : n); if(actual) { CC_SHA1_Update(&qa,buffer,(CC_LONG)actual); size-=actual; }
            padded-=n; }
        int percent=(int)(position*100/total);
        if(percent!=last_percent) { progress("verify package",position,total); last_percent=percent; }
    }
    if(position!=total) fail("Package payload length is inconsistent.");
    uint8_t zeroed[128]; memcpy(zeroed,header,128); memset(zeroed+48,0,80);
    CC_SHA1_Update(&qa,zeroed,128); CC_SHA1_Update(&qa,index,(CC_LONG)index_size);
    uint8_t digest[20]; CC_SHA1_Final(digest,&qa);
    if(memcmp(digest,header+96,16)) fail("Package content digest (QA) mismatch; the package is not intact.");
    uint8_t license[16]={0}; pkg_crypt(license,16,digest,UINT64_MAX);
    if(memcmp(license,header+112,16)) fail("Package license field mismatch.");
    uint8_t tail[96]; seek_to(fd,base+total); read_exact(fd,tail,96);
    for(int i=0;i<96;++i) if(tail[i]) fail("Package trailer is not empty.");
    /* Bind to the PARAM.SFO title ID when present. */
    char title_id[17]=""; size_t title_length=0;
    if(sfo_size && sfo_size<=65536) {
        uint8_t *sfo=malloc((size_t)sfo_size); if(!sfo) fail("Cannot allocate SFO buffer.");
        seek_to(fd,base+sfo_offset);
        uint64_t left=sfo_size, done=0;
        while(left) { size_t n=left<CHUNK?(size_t)left:CHUNK; check_cancel(); read_exact(fd,buffer,n);
            pkg_crypt(buffer,n,key,(sfo_offset+done)/16); memcpy(sfo+done,buffer,n); done+=n; left-=n; }
        if(sfo_size>=20 && !memcmp(sfo,"\0PSF",4)) {
            uint32_t key_start=(uint32_t)le(sfo+8,4), data_start=(uint32_t)le(sfo+12,4), entries=(uint32_t)le(sfo+16,4);
            if(entries<=64 && key_start<=(uint32_t)sfo_size && data_start<=(uint32_t)sfo_size) {
                for(uint32_t e=0;e<entries;++e) {
                    uint32_t key_off=(uint32_t)le(sfo+20+e*16,2), param_len=(uint32_t)le(sfo+20+e*16+4,4);
                    uint32_t data_off=(uint32_t)le(sfo+20+e*16+12,4);
                    if(key_start+key_off+9<=(uint32_t)sfo_size && !memcmp(sfo+key_start+key_off,"TITLE_ID",9)
                       && data_start+data_off+param_len<=(uint32_t)sfo_size && param_len && param_len<sizeof(title_id)) {
                        memcpy(title_id,sfo+data_start+data_off,param_len);
                        title_length=strnlen(title_id,sizeof(title_id)-1);
                        break;
                    }
                }
            }
        }
        memset(sfo,0,(size_t)sfo_size); free(sfo);
    }
    if(expected_title && (title_length!=9 || memcmp(title_id,expected_title,9)))
        fail("Package title ID does not match the expected job.");
    free(buffer);
    printf("{\"verified\":true,\"entries\":%u,\"payloadBytes\":%llu,\"contentID\":",count,(unsigned long long)total);
    { FILE *out=stdout; char cid[37]; memcpy(cid,header+48,36); cid[36]=0; json_string(out,cid); }
    printf(",\"titleID\":"); { FILE *out=stdout; json_string(out,title_id); }
    printf(",\"names\":[");
    for(unsigned i=0;i<count;++i) {
        uint8_t *record=index+(uint64_t)i*32;
        uint32_t name_offset=(uint32_t)be(record,4), name_length=(uint32_t)be(record+4,4);
        if(i) printf(",");
        char name[PATH_MAX]; memcpy(name,index+name_offset,name_length); name[name_length]=0;
        json_string(stdout,name);
    }
    printf("]}\n"); fflush(stdout);
    free(index); close(fd);
}
