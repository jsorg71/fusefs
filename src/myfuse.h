
#ifndef _MYFUSE_H
#define _MYFUSE_H

#include <stdlib.h>
#include <stdint.h>
#include <errno.h>

int
myfuse_create(const char* mountpoint, void* user, void** obj);
int
myfuse_delete(void* obj);
int
myfuse_get_fds(void* obj, int* fd);
int
myfuse_check_fds(void* obj);

void
myfuse_file_info_get(struct fuse_file_info* fi, int32_t* flags,
        uint32_t* padding, uint64_t* fh, uint64_t* lock_owner,
        uint32_t* poll_events, int32_t* backing_id, uint64_t* compat_flags);
struct fuse_file_info*
myfuse_file_info_create(int32_t flags, uint32_t padding, uint64_t fh,
        uint64_t lock_owner, uint32_t poll_events, int32_t backing_id,
        uint64_t compat_flags);
void
myfuse_file_info_delete(struct fuse_file_info* fi);

#endif
