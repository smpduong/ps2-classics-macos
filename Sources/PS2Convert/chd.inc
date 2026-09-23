// SPDX-License-Identifier: GPL-3.0-only
/* CHD import adapter. libchdr and its codecs are statically linked.
 * Source provenance and licenses: ThirdParty/libchdr/PS2-NOTICE.md. */
#include <libchdr/chd.h>
typedef struct { chd_file *chd; chd_file *parent_chd; FILE *file; FILE *parent_file; struct stat st; struct stat parent_st; int has_parent; const chd_header *header; uint8_t *hunk; uint32_t loaded; uint64_t frames, output_bytes; unsigned width; int cd; } CHDInput;
static void chd_require(chd_error err) { if(err!=CHDERR_NONE) { fprintf(stderr,"CHD: %s\n",chd_error_string(err));fail("CHD import stopped; no completed output was published."); } }
/* Header acceptance shared by every CHD entry point. Reports the detected
 * version precisely instead of a generic failure. */
static void chd_check_head(const uint8_t head[124], int is_parent) {
    if (memcmp(head,"MComprHD",8)) {
        if (is_parent) fail("The selected parent is not a CHD image.");
        fail("Not a CHD image.");
    }
    if (be(head+12,4)!=5) {
        static char version_message[128];
        snprintf(version_message,sizeof(version_message),"CHD version %u detected; only version 5 images are supported.",
                 (unsigned)be(head+12,4));
        if (is_parent) fail("The parent must also be a version 5 CHD.");
        fail(version_message);
    }
    if (be(head+8,4)!=124) {
        if (is_parent) fail("The selected parent has a malformed CHD header.");
        fail("CHD header is malformed.");
    }
}
static int chd_needs_parent(const uint8_t head[124]) {
    for (int i=104;i<124;++i) if (head[i]) return 1;
    return 0;
}
/* Opens the declared parent: same-file, version, nesting and readability are
 * all checked before libchdr ever sees it, so each failure names its cause. */
static void chd_open_parent(CHDInput *in, const char *path, const char *parent_path) {
    struct stat child_st, parent_stat;
    if (stat(path,&child_st) || stat(parent_path,&parent_stat))
        fail("Cannot inspect the selected parent CHD.");
    if (child_st.st_dev == parent_stat.st_dev && child_st.st_ino == parent_stat.st_ino)
        fail("The parent CHD and the image are the same file. Choose the file this image was derived from.");
    int pfd=open_input(parent_path,&in->parent_st);
    uint8_t phead[124];read_exact(pfd,phead,sizeof(phead));
    chd_check_head(phead,1);
    if (chd_needs_parent(phead)) {
        close(pfd);
        fail("Only single-level parent CHDs are supported. Flatten deeper chains before importing.");
    }
    seek_to(pfd,0);in->parent_file=fdopen(pfd,"rb");if(!in->parent_file)fail("Cannot read the selected parent CHD.");
    chd_error err=chd_open_file(in->parent_file,CHD_OPEN_READ,NULL,&in->parent_chd);
    if (err==CHDERR_REQUIRES_PARENT)fail("The selected parent is itself parent-dependent. Only single-level parent CHDs are supported.");
    chd_require(err);
    in->has_parent=1;
}
static CHDInput chd_input(const char *path, const char *parent_path) {
    CHDInput in={0}; in.loaded=UINT32_MAX;
    int fd=open_input(path,&in.st);uint8_t head[124];read_exact(fd,head,sizeof(head));
    chd_check_head(head,0);
    uint64_t logical=be(head+32,8);uint32_t hunk=(uint32_t)be(head+56,4),unit=(uint32_t)be(head+60,4);
    if(!logical||logical>(1ULL<<38)||!hunk||hunk>524288||!unit||hunk%unit||logical%unit)fail("CHD geometry is unsupported or malformed.");
    int need_parent=chd_needs_parent(head);
    if(need_parent && !parent_path)fail("Parent-dependent CHDs must be flattened before importing, or choose the exact parent CHD this image was derived from.");
    if(!need_parent && parent_path)fail("This CHD declares no parent; clear the parent selection before importing.");
    seek_to(fd,0);in.file=fdopen(fd,"rb");if(!in.file)fail("Cannot read CHD input.");
    if(need_parent) {
        chd_open_parent(&in,path,parent_path);
        chd_error err=chd_open_file(in.file,CHD_OPEN_READ,in.parent_chd,&in.chd);
        if(err==CHDERR_INVALID_PARENT)fail("The selected file is not this image's parent (identity mismatch). Choose the exact parent CHD.");
        chd_require(err);
    } else {
        chd_require(chd_open_file(in.file,CHD_OPEN_READ,NULL,&in.chd));
    }
    in.header=chd_get_header(in.chd);
    uint8_t metadata[1024]={0};uint32_t length=0,tag=0;
    chd_error dvd=chd_get_metadata(in.chd,DVD_METADATA_TAG,0,metadata,sizeof(metadata)-1,&length,&tag,NULL);
    if(dvd==CHDERR_NONE) {
        if(unit!=2048)fail("DVD CHD must use 2048-byte units.");
        for(unsigned i=0;i<2;++i) {
            chd_error extra=chd_get_metadata(in.chd,i?CDROM_TRACK_METADATA2_TAG:CDROM_TRACK_METADATA_TAG,0,metadata,sizeof(metadata),&length,&tag,NULL);
            if(extra!=CHDERR_METADATA_NOT_FOUND)fail("Ambiguous DVD/CD metadata is not supported.");
        }
        in.width=2048;in.frames=logical/2048;
    } else {
        if(dvd!=CHDERR_METADATA_NOT_FOUND)chd_require(dvd);
        int track=0,frames=0,pregap=0,postgap=0,used=0;char type[32]={0},sub[32]={0},pgtype[32]={0},pgsub[32]={0};
        uint32_t foundtag=CDROM_TRACK_METADATA2_TAG;
        chd_error err=chd_get_metadata(in.chd,foundtag,0,metadata,sizeof(metadata)-1,&length,&tag,NULL);
        if(err==CHDERR_METADATA_NOT_FOUND) { foundtag=CDROM_TRACK_METADATA_TAG;err=chd_get_metadata(in.chd,foundtag,0,metadata,sizeof(metadata)-1,&length,&tag,NULL); }
        chd_require(err);if(length>=sizeof(metadata))fail("CHD track metadata is too long.");
        metadata[length]=0;
        int fields=foundtag==CDROM_TRACK_METADATA2_TAG ? sscanf((char*)metadata,"TRACK:%d TYPE:%31s SUBTYPE:%31s FRAMES:%d PREGAP:%d PGTYPE:%31s PGSUB:%31s POSTGAP:%d %n",&track,type,sub,&frames,&pregap,pgtype,pgsub,&postgap,&used) : sscanf((char*)metadata,"TRACK:%d TYPE:%31s SUBTYPE:%31s FRAMES:%d %n",&track,type,sub,&frames,&used);
        if(fields!=(foundtag==CDROM_TRACK_METADATA2_TAG?8:4)||!used||metadata[used]||track!=1||frames<=0||pregap||postgap||strcmp(sub,"NONE"))fail("CHD import needs one data track without pregaps, postgaps or subchannel data.");
        chd_error alternate=chd_get_metadata(in.chd,foundtag==CDROM_TRACK_METADATA2_TAG?CDROM_TRACK_METADATA_TAG:CDROM_TRACK_METADATA2_TAG,0,metadata,sizeof(metadata),&length,&tag,NULL);
        if(alternate!=CHDERR_METADATA_NOT_FOUND)fail("Ambiguous CD track metadata is not supported.");
        for(unsigned i=0;i<2;++i) {
            uint32_t checktag=i?CDROM_TRACK_METADATA2_TAG:CDROM_TRACK_METADATA_TAG;
            err=chd_get_metadata(in.chd,checktag,1,metadata,sizeof(metadata),&length,&tag,NULL);
            if(err!=CHDERR_METADATA_NOT_FOUND)fail("Multi-track/audio CHDs are not supported; no tracks will be silently discarded.");
        }
        if(unit!=2448)fail("CD CHD must use 2448-byte units.");
        if(!strcmp(type,"MODE1"))in.width=2048;
        else if(!strcmp(type,"MODE1_RAW")||!strcmp(type,"MODE2_RAW"))in.width=2352;
        else fail("CHD track type is unsupported. Use DVD, MODE1, MODE1_RAW or MODE2_RAW.");
        in.cd=1;in.frames=(uint64_t)frames;
        if(in.frames>logical/unit||logical/unit-in.frames>3)fail("CHD track length and logical size disagree.");
    }
    in.output_bytes=in.frames*in.width;in.hunk=malloc(hunk);if(!in.hunk)fail("Cannot allocate CHD hunk buffer.");
    return in;
}
static void chd_close_input(CHDInput *in) {
    unchanged(fileno(in->file),&in->st);
    if (in->has_parent) unchanged(fileno(in->parent_file),&in->parent_st);
    chd_close(in->chd);
    if (in->has_parent) chd_close(in->parent_chd);
    fclose(in->file);
    if (in->has_parent) fclose(in->parent_file);
    free(in->hunk);
}
static void chd_bytes(CHDInput *in,uint64_t offset,uint8_t *buffer,size_t count) {
    if(offset>in->header->logicalbytes||count>in->header->logicalbytes-offset)fail("CHD read exceeds the logical image.");
    while(count) { check_cancel();uint32_t index=(uint32_t)(offset/in->header->hunkbytes);size_t start=(size_t)(offset%in->header->hunkbytes),n=in->header->hunkbytes-start;if(n>count)n=count;
        if(in->loaded!=index) { chd_require(chd_read(in->chd,index,in->hunk));in->loaded=index; }
        memcpy(buffer,in->hunk+start,n);buffer+=n;offset+=n;count-=n;
    }
}
static void chd_sector(CHDInput *in,uint64_t sector,unsigned useroffset,uint8_t *buffer) {
    if(sector>=in->frames)fail("ISO directory exceeds CHD track.");chd_bytes(in,sector*in->header->unitbytes+useroffset,buffer,2048);
}
static void chd_gameid(CHDInput *in,char id[10]) {
    uint8_t sector[2048],record[2048];unsigned offset=0;int found=0;
    const unsigned offsets[]={0,16,24};
    for(unsigned o=0;o<3&&!found;++o) {
        if(in->width==2048 && o)break;
        for(unsigned i=16;i<80 && i<in->frames;++i) {
            chd_sector(in,i,offsets[o],sector);
            if(memcmp(sector+1,"CD001",5)||sector[6]!=1||sector[0]==255)break;
            if(sector[0]==1) {offset=offsets[o];found=1;break;}
        }
    }
    if(!found)fail("No supported ISO9660 data volume found inside CHD.");
    uint64_t extent=le(sector+158,4),bytes=le(sector+166,4);
    if(bytes>4*1024*1024||extent>=in->frames||(bytes+2047)/2048>in->frames-extent)return;
    for(uint64_t s=0;s<(bytes+2047)/2048;++s) {
        chd_sector(in,extent+s,offset,record);
        for(unsigned p=0;p<2048;) {
            unsigned n=record[p];if(!n)break;if(n<34||p+n>2048)return;
            uint8_t *r=record+p;unsigned namelen=r[32];if(33+namelen>n)return;
            if(namelen==12 && !strncasecmp((char*)r+33,"SYSTEM.CNF;1",12)) {
                uint64_t lba=le(r+2,4),length=le(r+10,4);if(!length||length>65536||lba>=in->frames||(length+2047)/2048>in->frames-lba)return;
                char text[65537];size_t done=0;
                while(done<length) {chd_sector(in,lba+done/2048,offset,sector);size_t take=length-done<2048?(size_t)(length-done):2048;memcpy(text+done,sector,take);done+=take;}
                text[length]=0;for(size_t j=0;j<length;++j)if(text[j]>='a'&&text[j]<='z')text[j]-=32;
                char *boot=strstr(text,"BOOT2");if(!boot)return;
                for(char *q=boot; q+11<=text+length && *q!='\n';++q) {
                    int good=q[4]=='_'&&q[8]=='.';for(int k=0;k<4;++k)good=good&&q[k]>='A'&&q[k]<='Z';for(int k=5;k<11;++k)if(k!=8)good=good&&q[k]>='0'&&q[k]<='9';
                    if(good) {memcpy(id,q,4);memcpy(id+4,q+5,3);memcpy(id+7,q+9,2);id[9]=0;return;}
                }return;
            }p+=n;
        }
    }
}
static void chd_inspect(const char *path, const char *parent_path) {
    if (!parent_path) {
        /* A parent-dependent image reports its requirement (and the exact
         * parent identity it declares) without failing, so callers can ask
         * the user to choose the parent explicitly. */
        struct stat st;int fd=open_input(path,&st);
        uint8_t head[124];read_exact(fd,head,sizeof(head));
        chd_check_head(head,0);
        if (chd_needs_parent(head)) {
            char hex[41];for(int i=0;i<20;++i)sprintf(hex+i*2,"%02x",head[104+i]);
            unchanged(fd,&st);close(fd);
            printf("{\"requiresParent\":true,\"parentSHA1\":\"%s\"}\n",hex);fflush(stdout);
            return;
        }
        unchanged(fd,&st);close(fd);
    }
    CHDInput in=chd_input(path,parent_path);char id[10]={0};chd_gameid(&in,id);
    printf("{\"expandedByteCount\":%llu,\"sectorBytes\":%u,\"gameID\":\"%s\"}\n",(unsigned long long)in.output_bytes,in.width,id);chd_close_input(&in);
}
static void chd_extract(const char *path,const char *target,const char *parent_path) {
    CHDInput in=chd_input(path,parent_path);char id[10]={0};chd_gameid(&in,id);
    int out=create_output(target,in.output_bytes);CC_SHA1_CTX raw;CC_SHA1_Init(&raw);CC_SHA256_CTX sha;CC_SHA256_Init(&sha);uint64_t logical=0,written=0;int last=-1;
    for(uint32_t h=0;logical<in.header->logicalbytes;++h) {
        check_cancel();chd_require(chd_read(in.chd,h,in.hunk));size_t n=in.header->logicalbytes-logical<in.header->hunkbytes?(size_t)(in.header->logicalbytes-logical):in.header->hunkbytes;
        CC_SHA1_Update(&raw,in.hunk,(CC_LONG)n);
        for(size_t p=0;p<n;p+=in.header->unitbytes) {
            uint64_t frame=(logical+p)/in.header->unitbytes;
            if(frame<in.frames) { write_exact(out,in.hunk+p,in.width);CC_SHA256_Update(&sha,in.hunk+p,in.width);written+=in.width; }
        }
        logical+=n;int pct=(int)(logical*100/in.header->logicalbytes);if(pct!=last){progress("extract CHD",logical,in.header->logicalbytes);last=pct;}
    }
    uint8_t rawhash[20],expected[32],actual[32],has_hash=0;CC_SHA1_Final(rawhash,&raw);CC_SHA256_Final(expected,&sha);
    for(int i=0;i<20;++i)has_hash|=in.header->rawsha1[i];
    if(has_hash&&memcmp(rawhash,in.header->rawsha1,20))fail("CHD raw SHA-1 integrity check failed.");
    if(written!=in.output_bytes||fsync(out))fail("CHD extraction output is incomplete.");
    seek_to(out,0);CC_SHA256_Init(&sha);uint8_t buffer[65536];uint64_t remaining=written;
    while(remaining){size_t n=remaining<sizeof(buffer)?(size_t)remaining:sizeof(buffer);read_exact(out,buffer,n);CC_SHA256_Update(&sha,buffer,(CC_LONG)n);remaining-=n;}
    CC_SHA256_Final(actual,&sha);if(memcmp(actual,expected,32))fail("CHD extraction read-back mismatch.");
    chd_close_input(&in);finish_output(out,target);puts("{\"stage\":\"complete\",\"locallyVerified\":true}");
}
