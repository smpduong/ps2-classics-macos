// SPDX-License-Identifier: GPL-3.0-only
/* PS2 Classics native codec adapter, 2026.
 * PS2 header and segment layout adapted from ps2classic by 2013 USER,
 * decrypt algorithms by flatz; GPL-3.0. See ThirdParty/PS2Classic.
 * I/O, validation and process interface are new. Crypto uses Apple CommonCrypto.
 */
#include <CommonCrypto/CommonCrypto.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <sys/statvfs.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <limits.h>

#define SEG 16384
#define GROUP 512
#define CHUNK (SEG * GROUP)
#define MAX_PAYLOAD ((uint64_t)0x1000000 * SEG)   /* 256 GiB */
static volatile sig_atomic_t cancelled;
static char temporary[PATH_MAX];
static char partial_manifests[4][PATH_MAX];
static unsigned partial_manifest_count;
static int workspace_lock = -1;
static uint8_t data_key[16], meta_key[16];
static const char *logical_name = "ISO.BIN.ENC";
static const uint8_t zero_iv[16] = {0};
static void cleanup(void) {
    if (temporary[0]) unlink(temporary);
    for (unsigned i = 0; i < partial_manifest_count; ++i) unlink(partial_manifests[i]);
}
static void stop(int signum) { (void)signum; cancelled = 1; }
static void fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(cancelled ? 130 : 1);
}
static void check_cancel(void) { if (cancelled) fail("Cancelled. No finished output was published."); }
/* Exact logical-profile allowlist; shared by argument validation and detection. */
static const char *const supported_profiles[] = {
    "ISO.BIN.ENC", "ISO.BIN.ENC2", "ISO.BIN.ENC3", "ISO.BIN.ENC4", "ISO.BIN.ENC5",
    "ISO.BIN.ENC6", "ISO.BIN.ENC7", "ISO.BIN.ENC8", "ISO.BIN.ENC9",
    "CONFIG", "CONFIG2", "CONFIG3", "CONFIG4", "CONFIG5",
    "CONFIG6", "CONFIG7", "CONFIG8", "CONFIG9"
};
static int profile_supported(const char *name) {
    for (size_t i = 0; i < sizeof(supported_profiles)/sizeof(supported_profiles[0]); ++i)
        if (!strcmp(name, supported_profiles[i])) return 1;
    return 0;
}
static uint64_t be(const uint8_t *p, size_t n) {
    uint64_t v = 0; while (n--) v = (v << 8) | *p++; return v;
}
static uint64_t le(const uint8_t *p, size_t n) {
    uint64_t v = 0; while (n) v = (v << 8) | p[--n]; return v;
}
static void put(uint8_t *p, uint64_t v, size_t n) {
    while (n) { p[--n] = (uint8_t)v; v >>= 8; }
}
static void read_exact(int fd, void *buffer, size_t n) {
    uint8_t *p = buffer;
    while (n) {
        check_cancel(); ssize_t got = read(fd, p, n);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) fail("Input read failed or input is truncated.");
        p += got; n -= (size_t)got;
    }
}
static void write_exact(int fd, const void *buffer, size_t n) {
    const uint8_t *p = buffer;
    while (n) {
        check_cancel(); ssize_t wrote = write(fd, p, n);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) fail("Output write failed. Check space and destination permissions.");
        p += wrote; n -= (size_t)wrote;
    }
}
static void seek_to(int fd, uint64_t offset) {
    if (lseek(fd, (off_t)offset, SEEK_SET) < 0) fail("Cannot seek in input.");
}
static int open_input(const char *path, struct stat *st) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0 || fstat(fd, st) || !S_ISREG(st->st_mode) || st->st_size <= 0)
        fail("Input must be a readable, nonempty regular file.");
    return fd;
}
static void unchanged(int fd, const struct stat *before) {
    struct stat after;
    if (fstat(fd, &after) || after.st_size != before->st_size || after.st_ino != before->st_ino || after.st_dev != before->st_dev ||
        after.st_mtimespec.tv_sec != before->st_mtimespec.tv_sec ||
        after.st_mtimespec.tv_nsec != before->st_mtimespec.tv_nsec)
        fail("Source changed while processing. Finished output was not published.");
}
static void json_string(FILE *file, const char *text) {
    fputc('"', file);
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        switch (*p) {
            case '"': fputs("\\\"", file); break;
            case '\\': fputs("\\\\", file); break;
            case '\n': fputs("\\n", file); break;
            case '\r': fputs("\\r", file); break;
            case '\t': fputs("\\t", file); break;
            default:
                if (*p < 0x20) fprintf(file, "\\u%04x", *p);
                else fputc(*p, file);
        }
    }
    fputc('"', file);
}
/* Shared (reader) lock held for this process's lifetime on the workspace that
 * the parent created. Cleanup can only proceed when every writer is gone. */
static void lock_workspace_from_environment(void) {
    const char *directory = getenv("PS2_WORKSPACE");
    if (!directory || !*directory) return;
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/.ps2-lock", directory) >= (int)sizeof(path)) return;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    if (flock(fd, LOCK_SH | LOCK_NB) != 0) { close(fd); return; }
    workspace_lock = fd;
}
/* Durable provenance for an unpublished partial output. A rescanned cleanup
 * needs this record plus a released lock before it will touch the file. */
static void write_partial_manifest(const char *candidate, const char *target) {
    const char *job = getenv("PS2_JOB_ID");
    if (!job || strlen(job) != 36) job = "00000000-0000-4000-8000-000000000000";
    const char *slash = strrchr(candidate, '/');
    if (!slash) return;
    size_t suffix_length = strlen(candidate) - (size_t)(slash - candidate) - 1;
    if (suffix_length < 6) return;
    const char *suffix = candidate + strlen(candidate) - 6;
    char manifest[PATH_MAX];
    if (snprintf(manifest, sizeof(manifest), "%.*s/.ps2-partial-%s.json",
                 (int)(slash - candidate), candidate, suffix) >= (int)sizeof(manifest)) return;
    char stamp[32]; time_t now = time(NULL); struct tm utc; gmtime_r(&now, &utc);
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &utc);
    int fd = open(manifest, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return;
    FILE *file = fdopen(fd, "w");
    if (!file) { close(fd); return; }
    fputs("{\"format\":\"ps2-classics/workspace\",\"version\":1,\"kind\":\"partial\",\"jobID\":", file);
    json_string(file, job);
    fputs(",\"output\":", file); json_string(file, target);
    fputs(",\"partial\":", file); json_string(file, candidate + (slash - candidate) + 1);
    fputs(",\"createdAt\":", file); json_string(file, stamp);
    fprintf(file, ",\"pid\":%d}", (int)getpid());
    fclose(file);
    if (partial_manifest_count < sizeof(partial_manifests)/sizeof(partial_manifests[0]))
        strcpy(partial_manifests[partial_manifest_count++], manifest);
}
static int create_output(const char *path, uint64_t bytes) {
    struct stat st;
    if (lstat(path, &st) == 0 || errno != ENOENT) fail("Output already exists or cannot be inspected; choose a new name.");
    char candidate[PATH_MAX];
    if (snprintf(candidate, sizeof(candidate), "%s.partial.XXXXXX", path) >= (int)sizeof(candidate))
        fail("Output path is too long.");
    int fd = mkstemp(candidate);
    if (fd < 0) fail("Cannot create a temporary file at the destination.");
    strcpy(temporary, candidate);
    flock(fd, LOCK_SH);                 // let a rescanned cleanup see a live writer
    write_partial_manifest(candidate, path);
    struct statvfs fs;
    if (fstatvfs(fd, &fs)) fail("Cannot check destination storage.");
    if ((uint64_t)fs.f_bavail * fs.f_frsize < bytes + 16 * 1024 * 1024)
        fail("Not enough free space at the destination.");
    return fd;
}
static void finish_output(int fd, const char *path) {
    check_cancel();
    if (fsync(fd) || close(fd)) fail("Could not finalize output writes.");
    // Both operations create a name without replacing another file. Never
    // reserve an empty path then plain-rename over it: another process can
    // replace that placeholder in between, and a crash leaves a false output.
    if (renamex_np(temporary, path, RENAME_EXCL)) {
        if (errno != ENOTSUP && errno != EOPNOTSUPP && errno != EINVAL)
            fail("Cannot publish output without overwriting; choose another destination.");
        if (link(temporary, path))
            fail("This filesystem cannot publish output safely without overwriting. Build on an APFS or Mac OS Extended volume, then copy the completed file.");
        unlink(temporary);
    }
    temporary[0] = 0;
    for (unsigned i = 0; i < partial_manifest_count; ++i) unlink(partial_manifests[i]);
    partial_manifest_count = 0;
}
static void progress(const char *stage, uint64_t done, uint64_t total) {
    printf("{\"stage\":\"%s\",\"completed\":%llu,\"total\":%llu}\n", stage,
           (unsigned long long)done, (unsigned long long)total);
    fflush(stdout);
}
static void aes_cbc(int operation, const uint8_t key[16], const uint8_t *input, size_t n, uint8_t *output) {
    size_t written = 0;
    if (CCCrypt(operation, kCCAlgorithmAES, 0, key, 16, zero_iv, input, n, output, n, &written) != kCCSuccess || written != n)
        fail("AES operation failed.");
}
static void double_block(uint8_t block[16]) {
    unsigned carry = block[0] >> 7;
    for (int i = 0; i < 15; ++i) block[i] = (uint8_t)((block[i] << 1) | (block[i+1] >> 7));
    block[15] = (uint8_t)((block[15] << 1) ^ (carry ? 0x87 : 0));
}
static void cmac(const uint8_t key[16], const uint8_t *input, size_t n, uint8_t result[16]) {
    uint8_t subkey[16], chain[16] = {0}, block[16];
    aes_cbc(kCCEncrypt, key, zero_iv, 16, subkey); double_block(subkey);
    while (n > 16) {
        for (int i=0; i<16; ++i) block[i] = chain[i] ^ input[i];
        aes_cbc(kCCEncrypt, key, block, 16, chain); input += 16; n -= 16;
    }
    memset(block, 0, 16); memcpy(block, input, n);
    if (n < 16) { block[n] = 0x80; double_block(subkey); }
    for (int i=0; i<16; ++i) block[i] ^= chain[i] ^ subkey[i];
    aes_cbc(kCCEncrypt, key, block, 16, result);
}
static const uint8_t ps2_key_cex_meta[16] = { 0x38, 0x9D, 0xCB, 0xA5, 0x20, 0x3C, 0x81, 0x59, 0xEC, 0xF9, 0x4C, 0x93, 0x93, 0x16, 0x4C, 0xC9 };
static const uint8_t ps2_key_cex_data[16] = { 0x10, 0x17, 0x82, 0x34, 0x63, 0xF4, 0x68, 0xC1, 0xAA, 0x41, 0xD7, 0x00, 0xB1, 0x40, 0xF2, 0x57 };
static const uint8_t npd_omac_key2[16] = {0x6B,0xA5,0x29,0x76,0xEF,0xDA,0x16,0xEF,0x3C,0x33,0x9F,0xB2,0x97,0x1E,0x25,0x6B};
static const uint8_t npd_omac_key3[16] = {0x9B,0x51,0x5F,0xEA,0xCF,0x75,0x06,0x49,0x81,0xAA,0x60,0x4D,0x91,0xA5,0x4E,0x97};
static const uint8_t npd_kek[16] = {0x72,0xF9,0x90,0x78,0x8F,0x9C,0xFF,0x74,0x57,0x25,0xF0,0x8E,0x4C,0x12,0x83,0x87};
static void load_key(const char *path) {
    const char *extension = strrchr(path, '.');
    if (extension && (!strcasecmp(extension, ".rap") || !strcasecmp(extension, ".rif")))
        fail("RAP/RIF files must be converted to the appropriate klicensee first. Choose a 16-byte binary klicensee file.");
    struct stat st; int fd = open_input(path, &st); uint8_t license[16];
    if (st.st_size != 16) fail("The klicensee file must contain exactly 16 binary bytes; RAP/RIF files are not accepted as substitutes.");
    read_exact(fd, license, 16); close(fd);
    aes_cbc(kCCEncrypt, ps2_key_cex_data, license, 16, data_key);
    aes_cbc(kCCEncrypt, ps2_key_cex_meta, license, 16, meta_key);
    memset(license, 0, sizeof(license));
}
static int header_name_matches(const uint8_t *header, const char *name) {
    uint8_t message[96], mac[16];
    memcpy(message, header+16, 48); memcpy(message+48, name, strlen(name));
    cmac(npd_omac_key3, message, 48+strlen(name), mac);
    return memcmp(mac, header+0x50, 16) == 0;
}
static int header_auth_matches(const uint8_t *header) {
    uint8_t key[16], mac[16];
    for (int i=0; i<16; ++i) key[i] = npd_kek[i] ^ npd_omac_key2[i];
    cmac(key, header, 0x60, mac);
    return memcmp(mac, header+0x60, 16) == 0;
}
static int header_matches(const uint8_t *header, const char *name) {
    return header_name_matches(header, name) && header_auth_matches(header);
}
static void header_macs(uint8_t *header, int validate) {
    if (validate) {
        if (!header_name_matches(header, logical_name)) {
            static char message[160];
            snprintf(message, sizeof(message),
                "Header filename/content-ID check failed (%s profile required). Select the matching numbered-disc profile.", logical_name);
            fail(message);
        }
        if (!header_auth_matches(header)) fail("Header authentication check failed.");
        return;
    }
    {
        uint8_t message[96], key[16], mac[16];
        memcpy(message, header+16, 48); memcpy(message+48, logical_name, strlen(logical_name));
        cmac(npd_omac_key3, message, 48+strlen(logical_name), mac);
        memcpy(header+0x50, mac, 16);
        for (int i=0; i<16; ++i) key[i] = npd_kek[i] ^ npd_omac_key2[i];
        cmac(key, header, 0x60, mac);
        memcpy(header+0x60, mac, 16);
    }
}
/* Read-only profile detection: reports which logical filename the header was
 * sealed with, without decrypting payload segments. Disc number lives in
 * per-segment metadata, so callers still pass the disc number explicitly.
 * The declared payload size is unauthenticated, so it is bounded and only
 * reported as a payload length when the whole file matches it exactly. */
static void inspect_encrypted(const char *path) {
    struct stat st; int fd = open_input(path, &st);
    if ((uint64_t)st.st_size < SEG) fail("File is too small to be an encrypted image.");
    uint8_t header[SEG]; read_exact(fd, header, SEG);
    if (memcmp(header,"PS2\0",4) || be(header+4,2)!=1 || be(header+6,2)!=1 ||
        be(header+8,4)!=2 || be(header+12,4)!=1 || be(header+0x84,4)!=SEG)
        fail("Unsupported or malformed PS2 Classics header.");
    uint64_t size = be(header+0x88,8);
    if (!size || size > MAX_PAYLOAD)
        fail("The encrypted header declares an impossible payload length; it is not a usable image.");
    uint64_t segments = size/SEG + (size%SEG ? 1 : 0);
    uint64_t expected = SEG + segments*SEG + ((segments + GROUP - 1)/GROUP)*SEG;
    int complete = expected == (uint64_t)st.st_size;
    const char *match = NULL;
    for (unsigned i = 0; i < sizeof(supported_profiles)/sizeof(supported_profiles[0]); ++i) {
        check_cancel();
        if (header_matches(header, supported_profiles[i])) { match = supported_profiles[i]; break; }
    }
    unchanged(fd, &st); close(fd);
    if (!match) fail("No supported ISO.BIN.ENC/CONFIG profile authenticates this header. The file may use a wrong key family or an unsupported profile.");
    if (complete)
        printf("{\"logicalName\":\"%s\",\"payloadBytes\":%llu,\"complete\":true}\n",
               match, (unsigned long long)size);
    else
        printf("{\"logicalName\":\"%s\",\"complete\":false}\n", match);
    fflush(stdout);
}
static uint64_t encoded_size(uint64_t size) {
    if (!size || size > MAX_PAYLOAD) fail("Unsupported payload size (maximum 256 GiB).");
    uint64_t segments = size/SEG + (size%SEG ? 1 : 0);
    if (segments > 0x1000000) fail("Unsupported payload size (maximum 256 GiB).");
    return SEG + segments*SEG + ((segments + GROUP - 1)/GROUP)*SEG;
}
static unsigned sector_bytes=2048;
static uint32_t inspect_iso(int fd, uint64_t size) {
    uint8_t block[2048];
    if (size >= SEG) {
        seek_to(fd, size-SEG); read_exact(fd, block, 16);
        if (!memcmp(block, "LIMG", 4)) fail("This image already has a LIMG block. Reimport the original image; existing LIMG repair is not enabled.");
    }
    const unsigned strides[]={2048,2352,2352}, offsets[]={0,16,24};
    for(unsigned layout=0;layout<3;++layout) {
      unsigned stride=strides[layout], offset=offsets[layout];
      if(size%stride) continue;
      for (unsigned sector=16; sector<80 && ((uint64_t)sector+1)*stride <= size; ++sector) {
        seek_to(fd, (uint64_t)sector*stride+offset); read_exact(fd, block, sizeof(block));
        if (memcmp(block+1, "CD001", 5) || block[6] != 1 || block[0] == 255) break;
        if (block[0] != 1) continue;
        uint64_t blocks = be(block+84, 4);
        if (blocks != le(block+80, 4) || blocks <= sector || blocks*stride > size ||
            be(block+130,2) != 2048 || le(block+128,2) != 2048)
            fail("ISO descriptor is inconsistent or truncated.");
        sector_bytes=stride; return (uint32_t)blocks;
      }
    }
    fail("No supported ISO descriptor found. Use 2048-byte ISO or single-track 2352-byte BIN.");
    return 0;
}
static void decode(int fd, uint64_t file_size, int output, int disc, uint8_t digest[32]) {
    uint8_t header[SEG], meta[SEG], data[SEG], plain[SEG], hash[20];
    seek_to(fd,0); read_exact(fd,header,SEG);
    if (memcmp(header,"PS2\0",4) || be(header+4,2)!=1 || be(header+6,2)!=1 ||
        be(header+8,4)!=2 || be(header+12,4)!=1 || be(header+0x84,4)!=SEG)
        fail("Unsupported or malformed PS2 Classics header.");
    header_macs(header,1);
    uint64_t size=be(header+0x88,8);
    if (encoded_size(size)!=file_size) fail("Encrypted image size does not match its header.");
    uint64_t remaining=size; uint32_t number=0; int last_percent=-1;
    CC_SHA256_CTX sha; CC_SHA256_Init(&sha);
    while (remaining) {
        check_cancel(); read_exact(fd,meta,SEG); aes_cbc(kCCDecrypt,meta_key,meta,SEG,meta);
        unsigned count = (unsigned)((remaining+SEG-1)/SEG); if(count>GROUP) count=GROUP;
        for (unsigned i=0;i<count;++i) {
            read_exact(fd,data,SEG); CC_SHA1(data,SEG,hash);
            if (memcmp(hash,meta+i*32,20) || be(meta+i*32+20,4)!=(((uint32_t)(disc-1)<<24)|number))
                fail("Encrypted segment hash or disc/segment number failed verification.");
            for (int r=24;r<32;++r) if(meta[i*32+r]) fail("Unsupported segment metadata flags.");
            aes_cbc(kCCDecrypt,data_key,data,SEG,plain);
            size_t n = remaining<SEG ? (size_t)remaining : SEG;
            if(output>=0) write_exact(output,plain,n);
            CC_SHA256_Update(&sha,plain,(CC_LONG)n);
            remaining-=n; number++;
        }
        for (unsigned i=count*32;i<SEG;++i) if(meta[i]) fail("Unexpected unused metadata.");
        int percent=(int)((size-remaining)*100/size);
        if(percent!=last_percent) { progress(output>=0?"decrypt":"verify",size-remaining,size); last_percent=percent; }
    }
    CC_SHA256_Final(digest,&sha);
}
static void encrypt_image(int input, uint64_t original, int output, const char *cid, int disc, int prepare, uint8_t digest[32]) {
    uint32_t blocks = prepare ? inspect_iso(input,original) : 0;
    uint64_t padded = original/SEG*SEG + (original%SEG ? SEG : 0);
    uint64_t total=prepare?padded+SEG:original;
    uint8_t header[SEG]={0}, meta[SEG], limg[SEG]={0};
    uint8_t *data=calloc(1,CHUNK); if(!data) fail("Cannot allocate conversion buffers.");
    memcpy(header,"PS2\0",4); put(header+4,1,2); put(header+6,1,2);
    put(header+8,2,4); put(header+12,1,4); memcpy(header+16,cid,strlen(cid));
    arc4random_buf(header+0x40,16); put(header+0x84,SEG,4); put(header+0x88,total,8);
    header_macs(header,0); write_exact(output,header,SEG);
    if(prepare) { memcpy(limg,"LIMG",4); put(limg+4,sector_bytes==2048?1:2,4); put(limg+8,blocks,4); put(limg+12,sector_bytes,4); }
    seek_to(input,0); uint64_t position=0; uint32_t number=0; int last_percent=-1;
    CC_SHA256_CTX sha; CC_SHA256_Init(&sha);
    while(position<total) {
        check_cancel(); memset(data,0,CHUNK); memset(meta,0,SEG);
        size_t actual=(size_t)((total-position)<CHUNK?(total-position):CHUNK);
        if(position<original) {
            size_t n=(size_t)((original-position)<actual?(original-position):actual);
            read_exact(input,data,n);
        }
        if(prepare && position+actual>padded) {
            size_t dest=padded>position?(size_t)(padded-position):0;
            size_t from=position>padded?(size_t)(position-padded):0;
            memcpy(data+dest,limg+from,actual-dest);
        }
        CC_SHA256_Update(&sha,data,(CC_LONG)actual);
        unsigned count=(unsigned)((actual+SEG-1)/SEG);
        for(unsigned i=0;i<count;++i) {
            aes_cbc(kCCEncrypt,data_key,data+i*SEG,SEG,data+i*SEG);
            CC_SHA1(data+i*SEG,SEG,meta+i*32);
            put(meta+i*32+20,((uint32_t)(disc-1)<<24)|number++,4);
        }
        aes_cbc(kCCEncrypt,meta_key,meta,SEG,meta);
        write_exact(output,meta,SEG); write_exact(output,data,count*SEG); position+=actual;
        int percent=(int)(position*100/total);
        if(percent!=last_percent) { progress("encrypt",position,total); last_percent=percent; }
    }
    CC_SHA256_Final(digest,&sha); free(data);
}
static void validate_cid(const char *cid) {
    size_t n=strlen(cid);
    if(n!=36 || cid[6]!='-' || cid[16]!='_' || cid[19]!='-') fail("Content ID must follow the 36-character PS3 content-ID format.");
    for(size_t i=0;i<n;++i) {
        char c=cid[i]; if(!((c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_')) fail("Content ID must use uppercase ASCII letters, numbers, hyphens and underscores.");
    }
}
#include "chd.inc"
#include "extras.inc"
#include "package.inc"
int main(int argc,char **argv) {
    atexit(cleanup); signal(SIGTERM,stop); signal(SIGINT,stop); signal(SIGPIPE,SIG_IGN); signal(SIGXFSZ,SIG_IGN);
    lock_workspace_from_environment();
    if(argc==3 && !strcmp(argv[1],"inspect-encrypted")) { inspect_encrypted(argv[2]);return 0; }
    if(argc==3 && !strcmp(argv[1],"verify-package")) { package_verify(argv[2],NULL,NULL);return 0; }
    if((argc==4 || argc==5) && !strcmp(argv[1],"verify-package")) { package_verify(argv[2],argv[3],argc==5?argv[4]:NULL);return 0; }
    if(argc==3 && !strcmp(argv[1],"inspect-chd")) { chd_inspect(argv[2]);return 0; }
    if(argc==4 && !strcmp(argv[1],"extract-chd")) { chd_extract(argv[2],argv[3]);return 0; }
    if(argc==5 && !strcmp(argv[1],"package")) { package_build(argv[2],argv[3],argv[4]);return 0; }
    if(argc==4 && (!strcmp(argv[1],"vmc-encrypt")||!strcmp(argv[1],"vmc-decrypt"))) { memory_card(argv[2],argv[3],!strcmp(argv[1],"vmc-encrypt"));return 0; }
    if(argc==7 && !strcmp(argv[1],"edat")) { build_edat(argv[2],argv[3],argv[4],argv[5],argv[6]);return 0; }
    if(argc==2 && !strcmp(argv[1],"--version")) { puts("ps2-convert 1.0.0 (CEX, PS2 Classics profiles)"); return 0; }
    int encrypt=argc>1 && (!strcmp(argv[1],"encrypt-iso")||!strcmp(argv[1],"encrypt-raw"));
    int decrypt=argc>1 && !strcmp(argv[1],"decrypt");
    int verify=argc>1 && !strcmp(argv[1],"verify");
    if((encrypt&&argc!=7&&argc!=8)||(decrypt&&argc!=6&&argc!=7)||(verify&&argc!=5&&argc!=6)||(!encrypt&&!decrypt&&!verify)) {
        fputs("Usage: ps2-convert encrypt-iso|encrypt-raw INPUT OUTPUT KLICENSEE CONTENT_ID DISC [LOGICAL]\n       ps2-convert decrypt INPUT OUTPUT KLICENSEE DISC [LOGICAL]\n       ps2-convert verify INPUT KLICENSEE DISC [LOGICAL]\n       ps2-convert inspect-encrypted INPUT\n       ps2-convert verify-package INPUT [CONTENT_ID] [TITLE_ID]\n",stderr); return 2;
    }
    int disc_arg=encrypt?6:(decrypt?5:4);
    if(argc>disc_arg+1) {
        logical_name=argv[disc_arg+1];
        if(!profile_supported(logical_name)) fail("Unsupported logical filename. Use ISO.BIN.ENC2 through ISO.BIN.ENC9 or a matching CONFIG profile.");
    }
    char *end; long disc=strtol(argv[disc_arg],&end,10);
    if(*end || disc<1 || disc>9) fail("Disc number must be 1 through 9.");
    struct stat source; int input=open_input(argv[2],&source);
    load_key(argv[verify?3:4]);
    uint8_t expected[32], recovered[32];
    if(encrypt) {
        validate_cid(argv[5]); int prepare=!strcmp(argv[1],"encrypt-iso");
        uint64_t original=(uint64_t)source.st_size;
        if(original>MAX_PAYLOAD) fail("Input is larger than the supported 256 GiB payload limit.");
        uint64_t aligned=original/SEG*SEG + (original%SEG ? SEG : 0);
        uint64_t total=prepare?aligned+SEG:original;
        if(prepare) inspect_iso(input,original);
        int output=create_output(argv[3],encoded_size(total));
        encrypt_image(input,original,output,argv[5],(int)disc,prepare,expected);
        unchanged(input,&source);
        if(fsync(output)) fail("Cannot flush encrypted output.");
        struct stat encrypted; if(fstat(output,&encrypted)) fail("Cannot inspect encrypted output size.");
        decode(output,(uint64_t)encrypted.st_size,-1,(int)disc,recovered);
        if(memcmp(expected,recovered,32)) fail("Recovered payload differs from source/preparation stream.");
        unchanged(input,&source); finish_output(output,argv[3]);
    } else {
        int output=-1;
        if(decrypt) {
            uint8_t header[SEG]; read_exact(input,header,SEG);
            uint64_t size=be(header+0x88,8);
            if(encoded_size(size)!=(uint64_t)source.st_size) fail("Invalid encrypted payload size.");
            output=create_output(argv[3],size);
        }
        decode(input,(uint64_t)source.st_size,output,(int)disc,recovered);
        unchanged(input,&source); if(decrypt) finish_output(output,argv[3]);
    }
    close(input); puts("{\"stage\":\"complete\",\"locallyVerified\":true}"); return 0;
}
