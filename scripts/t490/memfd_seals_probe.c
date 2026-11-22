#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef MFD_NOEXEC_SEAL
#define MFD_NOEXEC_SEAL 0x0008U
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#endif
#ifndef F_GET_SEALS
#define F_GET_SEALS 1034
#endif
#ifndef F_SEAL_EXEC
#define F_SEAL_EXEC 0x0020
#endif

static int passed;
static int failed;

static void check(const char *name, int ok, long rc, int err)
{
	printf("[MF] %-38s rc=%ld errno=%d (%s) %s\n",
	       name, rc, err, err ? strerror(err) : "-", ok ? "PASS" : "FAIL");
	if (ok)
		passed++;
	else
		failed++;
}

int main(void)
{
	const int required_seals = F_SEAL_WRITE | F_SEAL_GROW |
		F_SEAL_SHRINK | F_SEAL_SEAL;
	int fd = (int)syscall(SYS_memfd_create, "xk6-seal-probe",
			     MFD_CLOEXEC | MFD_ALLOW_SEALING);
	int err = errno;
	check("memfd_create allow sealing", fd >= 0, fd, fd >= 0 ? 0 : err);
	if (fd < 0)
		goto done;

	errno = 0;
	int rc = ftruncate(fd, 4096);
	check("initial ftruncate", rc == 0, rc, errno);
	errno = 0;
	rc = (int)write(fd, "x", 1);
	check("initial write", rc == 1, rc, errno);
	errno = 0;
	rc = fcntl(fd, F_ADD_SEALS, required_seals);
	check("F_ADD_SEALS all required", rc == 0, rc, errno);
	errno = 0;
	rc = fcntl(fd, F_GET_SEALS);
	check("F_GET_SEALS contains all", rc >= 0 &&
	      (rc & required_seals) == required_seals, rc, errno);

	errno = 0;
	long write_rc = pwrite(fd, "y", 1, 0);
	check("sealed pwrite returns EPERM", write_rc == -1 && errno == EPERM,
	      write_rc, errno);
	errno = 0;
	rc = ftruncate(fd, 8192);
	check("sealed grow returns EPERM", rc == -1 && errno == EPERM, rc, errno);
	errno = 0;
	rc = ftruncate(fd, 2048);
	check("sealed shrink returns EPERM", rc == -1 && errno == EPERM, rc, errno);
	errno = 0;
	void *map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	check("sealed writable shared mmap denied",
	      map == MAP_FAILED && errno == EPERM,
	      map == MAP_FAILED ? -1 : 0, errno);
	if (map != MAP_FAILED)
		munmap(map, 4096);
	close(fd);

	fd = (int)syscall(SYS_memfd_create, "xk6-seal-disabled", MFD_CLOEXEC);
	if (fd >= 0) {
		errno = 0;
		rc = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE);
		check("seal without ALLOW_SEALING denied",
		      rc == -1 && errno == EPERM, rc, errno);
		close(fd);
	} else {
		check("memfd without ALLOW_SEALING create", 0, fd, errno);
	}

	errno = 0;
	fd = (int)syscall(SYS_memfd_create, "xk6-invalid-flags", UINT32_MAX);
	err = errno;
	if (fd >= 0)
		close(fd);
	check("all-ones flags return EINVAL", fd == -1 && err == EINVAL, fd, err);

	errno = 0;
	fd = (int)syscall(SYS_memfd_create, "xk6-noexec-seal",
			  MFD_CLOEXEC | MFD_NOEXEC_SEAL);
	err = errno;
	if (fd < 0 && (err == EINVAL || err == ENOSYS || err == EOPNOTSUPP)) {
		printf("[MF] MFD_NOEXEC_SEAL unsupported errno=%d (%s); capability result\n",
		       err, strerror(err));
	} else if (fd < 0) {
		check("MFD_NOEXEC_SEAL unexpected error", 0, fd, err);
	} else {
		errno = 0;
		rc = fcntl(fd, F_GET_SEALS);
		check("MFD_NOEXEC_SEAL sets F_SEAL_EXEC",
		      rc >= 0 && (rc & F_SEAL_EXEC) != 0, rc, errno);
		close(fd);
	}

done:
	printf("[MFSUM] pass=%d fail=%d\n", passed, failed);
	printf("[MFRESULT] %s\n", failed ? "FAIL" : "PASS");
	return failed ? 1 : 0;
}
