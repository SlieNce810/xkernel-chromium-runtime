// BUILD: static
// Compare Linux and x-kernel mremap behavior for a subrange that grows in place.
// Run the same binary in both environments and compare the PASS line.
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        fprintf(stderr, "MREMAP_SUBRANGE_SETUP_FAIL errno=%d\n", errno);
        return 2;
    }

    const size_t page = (size_t)page_size;
    const size_t mapped_size = page * 8;
    unsigned char *base = mmap(NULL, mapped_size, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) {
        fprintf(stderr, "MREMAP_SUBRANGE_MMAP_FAIL errno=%d (%s)\n",
                errno, strerror(errno));
        return 2;
    }
    for (size_t offset = 0; offset < mapped_size; offset += page) {
        base[offset] = (unsigned char)(offset / page + 1);
    }

    // The old VMA begins at base, while the request starts two pages inside it.
    // Growing by one page remains entirely inside the original eight-page VMA.
    void *request = base + 2 * page;
    errno = 0;
    void *result = mremap(request, page, 2 * page, 0);
    int saved_errno = errno;
    int passed = result == request;
    printf("MREMAP_SUBRANGE_RESULT pass=%d addr_match=%d errno=%d page=%zu\n",
           passed, result == request, saved_errno, page);

    munmap(base, mapped_size);
    return passed ? 0 : 1;
}
