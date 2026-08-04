#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

#include <mtd/mtd-user.h>

static void die_errno(const char *what)
{
    fprintf(stderr, "nandrawdump: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void write_all(int fd, const unsigned char *buf, size_t len)
{
    while (len != 0) {
        ssize_t written = write(fd, buf, len);

        if (written < 0) {
            if (errno == EINTR)
                continue;
            die_errno("write");
        }
        if (written == 0) {
            errno = EIO;
            die_errno("zero-length write");
        }

        buf += written;
        len -= (size_t)written;
    }
}

static void pread_exact(int fd, unsigned char *buf, size_t len, off_t offset)
{
    size_t done = 0;

    while (done != len) {
        ssize_t got = pread(fd, buf + done, len - done, offset + (off_t)done);

        if (got < 0) {
            if (errno == EINTR)
                continue;
            die_errno("raw page-data read");
        }
        if (got == 0) {
            errno = EIO;
            die_errno("short raw page-data read");
        }

        done += (size_t)got;
    }
}

int main(int argc, char **argv)
{
    struct mtd_info_user info;
    struct mtd_oob_buf oob;
    unsigned char *page_data;
    unsigned char *oob_data;
    uint64_t offset;
    uint64_t pages;
    int fd;
    int mode = MTD_FILE_MODE_RAW;

    if (argc != 2) {
        fprintf(stderr, "usage: %s /dev/mtdN\n", argv[0]);
        return 2;
    }

    fd = open(argv[1], O_RDONLY);
    if (fd < 0)
        die_errno("open");

    memset(&info, 0, sizeof(info));
    if (ioctl(fd, MEMGETINFO, &info) < 0)
        die_errno("MEMGETINFO");

    if (info.writesize == 0 || info.oobsize == 0 ||
        info.size == 0 || info.size % info.writesize != 0) {
        fprintf(stderr,
                "nandrawdump: invalid geometry: size=%" PRIu32
                " writesize=%" PRIu32 " oobsize=%" PRIu32 "\n",
                info.size, info.writesize, info.oobsize);
        return 1;
    }

    if (ioctl(fd, MTDFILEMODE, mode) < 0)
        die_errno("MTDFILEMODE raw");

    page_data = malloc(info.writesize);
    oob_data = malloc(info.oobsize);
    if (page_data == NULL || oob_data == NULL)
        die_errno("malloc");

    pages = (uint64_t)info.size / info.writesize;
    fprintf(stderr,
            "nandrawdump: %s size=%" PRIu32 " erase=%" PRIu32
            " page=%" PRIu32 " oob=%" PRIu32 " pages=%" PRIu64 "\n",
            argv[1], info.size, info.erasesize, info.writesize,
            info.oobsize, pages);

    for (offset = 0; offset < info.size; offset += info.writesize) {
        pread_exact(fd, page_data, info.writesize, (off_t)offset);

        memset(&oob, 0, sizeof(oob));
        oob.start = (uint32_t)offset;
        oob.length = info.oobsize;
        oob.ptr = oob_data;
        if (ioctl(fd, MEMREADOOB, &oob) < 0)
            die_errno("raw OOB read");
        if (oob.length != info.oobsize) {
            fprintf(stderr,
                    "nandrawdump: short OOB read at 0x%08" PRIx64
                    ": got=%" PRIu32 " expected=%" PRIu32 "\n",
                    offset, oob.length, info.oobsize);
            return 1;
        }

        write_all(STDOUT_FILENO, page_data, info.writesize);
        write_all(STDOUT_FILENO, oob_data, info.oobsize);
    }

    fprintf(stderr, "nandrawdump: completed %s (%" PRIu64 " pages)\n",
            argv[1], pages);

    free(oob_data);
    free(page_data);
    if (close(fd) < 0)
        die_errno("close");
    return 0;
}
