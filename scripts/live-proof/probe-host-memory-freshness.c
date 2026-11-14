#include <mach/mach.h>
#include <libproc.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static mach_port_t host;
static uint64_t physical;
static vm_size_t page_size;

static struct vm_statistics64 sample(void) {
    struct vm_statistics64 stats = {0};
    mach_msg_type_number_t count = sizeof(stats) / sizeof(integer_t);
    kern_return_t kr = host_statistics64(host, HOST_VM_INFO64,
                                        (host_info64_t)&stats, &count);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "host_statistics64 failed: %d\n", kr);
        exit(2);
    }
    return stats;
}

static uint64_t footprint(void) {
    struct rusage_info_v2 info = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&info)) {
        perror("proc_pid_rusage");
        exit(2);
    }
    return info.ri_phys_footprint;
}

static uint64_t available(struct vm_statistics64 s) {
    uint64_t internal = s.internal_page_count > s.purgeable_count
        ? s.internal_page_count - s.purgeable_count : 0;
    uint64_t used = ((uint64_t)s.wire_count + s.compressor_page_count + internal) * page_size;
    return physical > used ? physical - used : 0;
}

static void emit(int trial, const char *phase, struct vm_statistics64 s, uint64_t fp) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    printf("{\"trial\":%d,\"phase\":\"%s\",\"monotonic_seconds\":%.6f,"
           "\"physical_bytes\":%llu,\"page_size\":%llu,\"phys_footprint\":%llu,"
           "\"wired_pages\":%u,\"compressor_pages\":%u,\"internal_pages\":%u,"
           "\"purgeable_pages\":%u,\"reclaimable_bytes\":%llu}\n",
           trial, phase, now.tv_sec + now.tv_nsec / 1e9,
           (unsigned long long)physical, (unsigned long long)page_size,
           (unsigned long long)fp, s.wire_count, s.compressor_page_count,
           s.internal_page_count, s.purgeable_count,
           (unsigned long long)available(s));
    fflush(stdout);
}

int main(void) {
    host = mach_host_self();
    if (host_page_size(host, &page_size) != KERN_SUCCESS) return 2;
    size_t n = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &n, NULL, 0)) return 2;
    const size_t bytes = 64 * 1024 * 1024;
    int stale_trials = 0;
    for (int trial = 1; trial <= 5; trial++) {
        void *buffer = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON, -1, 0);
        if (buffer == MAP_FAILED) { perror("mmap"); return 2; }
        memset(buffer, 0xa5, bytes);
        usleep(1100000);
        // Exceed XNU's randomized 2..10 fresh queries per one-second window.
        struct vm_statistics64 before = {0};
        for (int i = 0; i < 20; i++) before = sample();
        uint64_t fp_before = footprint();
        emit(trial, "allocated_saturated", before, fp_before);
        if (munmap(buffer, bytes)) { perror("munmap"); return 2; }
        uint64_t fp_after = footprint();
        struct vm_statistics64 immediate = sample();
        emit(trial, "released_immediate", immediate, fp_after);
        int stale = fp_before > fp_after + bytes / 2
            && before.wire_count == immediate.wire_count
            && before.internal_page_count == immediate.internal_page_count
            && before.compressor_page_count == immediate.compressor_page_count
            && before.purgeable_count == immediate.purgeable_count;
        stale_trials += stale;
        usleep(1100000);
        emit(trial, "released_after_window", sample(), footprint());
    }
    printf("{\"stale_after_confirmed_release\":%d,\"trials\":5}\n", stale_trials);
    mach_port_deallocate(mach_task_self(), host);
    return stale_trials == 5 ? 0 : 1;
}
