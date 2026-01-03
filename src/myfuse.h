
#ifndef _MYFUSE_H
#define _MYFUSE_H

#include <stdlib.h>
#include <stdint.h>
#include <errno.h>

struct myfuse_file_info
{
    int32_t flags;
    // uint32_t writepage : 1; // low
    // uint32_t direct_io: 1;
    // uint32_t keep_cache : 1;
    // uint32_t flush : 1;
    // uint32_t nonseekable : 1;
    // uint32_t flock_release : 1;
    // uint32_t cache_readdir : 1;
    // uint32_t noflush : 1;
    // uint32_t parallel_direct_writes : 1; // high
    uint32_t padding;
    uint32_t padding2;
    uint32_t padding3;
    uint64_t fh;
    uint64_t lock_owner;
    uint32_t poll_events;
    int32_t backing_id;
    uint64_t compat_flags;
    uint64_t reserved[2];
};

int
myfuse_create(const char* mountpoint, void* user, void** obj);
int
myfuse_delete(void* obj);
int
myfuse_get_fds(void* obj,
        int* rfds, size_t max_rfds, size_t* num_rfds,
        int* wfds, size_t max_wfds, size_t* num_wfds,
        int* timeout);
int
myfuse_check_fds(void* obj);

#endif
