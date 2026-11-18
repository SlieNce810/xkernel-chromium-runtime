/*
 * Focused procfs/MM observation probe for Linux and x-kernel.
 *
 * The probe prints raw statm/status/smaps_rollup values at allocation,
 * first-touch, file-backed shared mapping, fork+COW, and release phases.
 * Missing procfs fields are printed as UNAVAILABLE; the probe never fabricates
 * PSS/USS values when smaps_rollup is absent.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define PAGE_COUNT 32

static int read_status_kb(pid_t pid, const char *field, long *value)
{
	char path[128];
	char line[256];
	int found = 0;
	snprintf(path, sizeof(path), "/proc/%d/status", (int)pid);
	FILE *stream = fopen(path, "r");
	if (!stream)
		return 0;
	while (fgets(line, sizeof(line), stream)) {
		if (strncmp(line, field, strlen(field)) == 0 &&
		    sscanf(line + strlen(field), "%ld kB", value) == 1) {
			found = 1;
			break;
		}
	}
	fclose(stream);
	return found;
}

static void sample_process(const char *phase, pid_t pid)
{
	char path[128];
	long size_pages = -1, resident_pages = -1, shared_pages = -1;
	long status_rss = -1, status_hwm = -1;
	long smaps_rss = -1, pss = -1;
	long shared_clean = -1, shared_dirty = -1;
	long private_clean = -1, private_dirty = -1;
	int have_smaps = 0;

	snprintf(path, sizeof(path), "/proc/%d/statm", (int)pid);
	FILE *stream = fopen(path, "r");
	if (stream) {
		if (fscanf(stream, "%ld %ld %ld", &size_pages,
		           &resident_pages, &shared_pages) != 3) {
			size_pages = resident_pages = shared_pages = -1;
		}
		fclose(stream);
	}
	(void)read_status_kb(pid, "VmRSS:", &status_rss);
	(void)read_status_kb(pid, "VmHWM:", &status_hwm);

	snprintf(path, sizeof(path), "/proc/%d/smaps_rollup", (int)pid);
	stream = fopen(path, "r");
	if (stream) {
		char line[256];
		have_smaps = 1;
		while (fgets(line, sizeof(line), stream)) {
			long value;
			if (sscanf(line, "Rss: %ld kB", &value) == 1)
				smaps_rss = value;
			else if (sscanf(line, "Pss: %ld kB", &value) == 1)
				pss = value;
			else if (sscanf(line, "Shared_Clean: %ld kB", &value) == 1)
				shared_clean = value;
			else if (sscanf(line, "Shared_Dirty: %ld kB", &value) == 1)
				shared_dirty = value;
			else if (sscanf(line, "Private_Clean: %ld kB", &value) == 1)
				private_clean = value;
			else if (sscanf(line, "Private_Dirty: %ld kB", &value) == 1)
				private_dirty = value;
		}
		fclose(stream);
	}

	printf("MEM_SAMPLE phase=%s pid=%d statm_size_pages=%ld "
	       "statm_resident_pages=%ld statm_shared_pages=%ld "
	       "vmrss_kb=%ld vmhwm_kb=%ld smaps_rss_kb=%ld ",
	       phase, (int)pid, size_pages, resident_pages, shared_pages,
	       status_rss, status_hwm, smaps_rss);
	if (have_smaps && pss >= 0)
		printf("pss_kb=%ld ", pss);
	else
		printf("pss_kb=UNAVAILABLE ");
	if (have_smaps && private_clean >= 0 && private_dirty >= 0)
		printf("uss_kb=%ld ", private_clean + private_dirty);
	else
		printf("uss_kb=UNAVAILABLE ");
	if (have_smaps && shared_clean >= 0 && shared_dirty >= 0)
		printf("smaps_shared_kb=%ld\n", shared_clean + shared_dirty);
	else
		printf("smaps_shared_kb=UNAVAILABLE\n");
}

static void touch_pages(unsigned char *memory, size_t length, size_t page_size,
			unsigned char value)
{
	for (size_t offset = 0; offset < length; offset += page_size)
		memory[offset] = value;
}

int main(void)
{
	long page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) {
		perror("sysconf(_SC_PAGESIZE)");
		return 2;
	}
	size_t length = (size_t)page_size * PAGE_COUNT;
	char file_path[] = "/tmp/xk6-procfs-memory-XXXXXX";
	int file_fd = mkstemp(file_path);
	if (file_fd < 0) {
		perror("mkstemp");
		return 2;
	}
	if (ftruncate(file_fd, (off_t)length) != 0) {
		perror("ftruncate");
		close(file_fd);
		unlink(file_path);
		return 2;
	}

	unsigned char *anon = mmap(NULL, length, PROT_READ | PROT_WRITE,
	                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	unsigned char *file_private = mmap(NULL, length, PROT_READ | PROT_WRITE,
	                                   MAP_PRIVATE, file_fd, 0);
	unsigned char *file_shared = mmap(NULL, length, PROT_READ | PROT_WRITE,
	                                  MAP_SHARED, file_fd, 0);
	if (anon == MAP_FAILED || file_private == MAP_FAILED ||
	    file_shared == MAP_FAILED) {
		perror("mmap");
		if (anon != MAP_FAILED) munmap(anon, length);
		if (file_private != MAP_FAILED) munmap(file_private, length);
		if (file_shared != MAP_FAILED) munmap(file_shared, length);
		close(file_fd);
		unlink(file_path);
		return 2;
	}

	printf("MEM_PROBE_START page_size=%ld page_count=%d length_bytes=%zu\n",
	       page_size, PAGE_COUNT, length);
	sample_process("baseline", getpid());
	touch_pages(anon, length, (size_t)page_size, 0x41);
	sample_process("anon_touched", getpid());
	volatile unsigned char file_sink = 0;
	for (size_t offset = 0; offset < length; offset += (size_t)page_size)
		file_sink ^= file_private[offset];
	(void)file_sink;
	sample_process("file_private_touched", getpid());
	touch_pages(file_shared, length, (size_t)page_size, 0x52);
	(void)msync(file_shared, length, MS_SYNC);
	sample_process("file_shared_touched", getpid());
	if (unlink(file_path) != 0)
		perror("unlink(temp file)");
	close(file_fd);

	int ready_pipe[2], release_pipe[2];
	if (pipe(ready_pipe) != 0 || pipe(release_pipe) != 0) {
		perror("pipe");
		return 2;
	}
	pid_t child = fork();
	if (child < 0) {
		perror("fork");
		return 2;
	}
	if (child == 0) {
		close(ready_pipe[0]);
		close(release_pipe[1]);
		anon[0] ^= 1;          /* anonymous private COW */
		file_private[0] ^= 1;  /* file-backed private COW */
		file_shared[0] ^= 1;   /* shared mapping remains visible to parent */
		char ready = 'R';
		if (write(ready_pipe[1], &ready, 1) != 1)
			_exit(3);
		char release = 0;
		if (read(release_pipe[0], &release, 1) != 1)
			_exit(4);
		_exit(0);
	}

	close(ready_pipe[1]);
	close(release_pipe[0]);
	char ready = 0;
	if (read(ready_pipe[0], &ready, 1) != 1 || ready != 'R') {
		fprintf(stderr, "child did not reach post-fork sample point\n");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 2;
	}
	sample_process("fork_child_after_child_cow", child);
	sample_process("fork_parent_before_parent_cow", getpid());
	anon[1] ^= 1;
	file_private[page_size] ^= 1;
	sample_process("fork_parent_after_parent_cow", getpid());
	sample_process("fork_child_after_parent_cow", child);
	char release = 'Q';
	if (write(release_pipe[1], &release, 1) != 1)
		kill(child, SIGKILL);
	close(ready_pipe[0]);
	close(release_pipe[1]);
	int child_status = 0;
	if (waitpid(child, &child_status, 0) != child) {
		perror("waitpid");
		return 2;
	}
	printf("MEM_CHILD_EXIT code=%d\n",
	       WIFEXITED(child_status) ? WEXITSTATUS(child_status) : -1);

	if (munmap(anon, length) != 0 ||
	    munmap(file_private, length) != 0 ||
	    munmap(file_shared, length) != 0) {
		perror("munmap");
		return 2;
	}
	sample_process("after_unmap", getpid());
	printf("MEM_PROBE_DONE pss_uss_unavailable_is_explicit=1\n");
	return 0;
}
