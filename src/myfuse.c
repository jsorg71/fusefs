#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#define FUSE_USE_VERSION 35
#include <fuse_lowlevel.h>

#include "myfuse.h"

struct myfuse_info
{
    struct fuse_args args;
    struct fuse_lowlevel_ops ops;
    struct fuse_session* se;
    struct fuse_buf buf;
};

// zig callbacks
void cb_lookup(fuse_req_t req, fuse_ino_t parent, const char* name);
void cb_readdir(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off,
        struct fuse_file_info* fi);
void cb_mkdir(fuse_req_t req, fuse_ino_t parent, const char* name,
        mode_t mode);
void cb_rmdir(fuse_req_t req, fuse_ino_t parent, const char* name);
void cb_unlink(fuse_req_t req, fuse_ino_t parent, const char* name);
void cb_rename(fuse_req_t req, fuse_ino_t old_parent, const char* old_name,
        fuse_ino_t new_parent, const char* new_name, unsigned int flags);
void cb_open(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info* fi);
void cb_release(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info* fi);
void cb_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off,
        struct fuse_file_info* fi);
void cb_write(fuse_req_t req, fuse_ino_t ino, const char* buf, size_t size,
        off_t off, struct fuse_file_info* fi);
void cb_create(fuse_req_t req, fuse_ino_t parent, const char* name,
        mode_t mode, struct fuse_file_info* fi);
void cb_fsync(fuse_req_t req, fuse_ino_t ino, int datasync,
        struct fuse_file_info* fi);
void cb_getattr(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info* fi);
void cb_setattr(fuse_req_t req, fuse_ino_t ino, struct stat* attr, int to_set,
        struct fuse_file_info* fi);
void cb_opendir(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info* fi);
void cb_releasedir(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info* fi);
void cb_statfs(fuse_req_t req, fuse_ino_t ino);

//*****************************************************************************
// return 0 = ok
//        1 = alloc failed
//        2 = fuse_session_new failed
//        3 = fuse_session_mount failed
int
myfuse_create(const char* mountpoint, void* user, void** obj)
{
    int rv;
    struct myfuse_info* mi;

    rv = 1;
    mi = (struct myfuse_info*)calloc(1, sizeof(struct myfuse_info));
    if (mi != NULL)
    {
        fuse_opt_add_arg(&mi->args, "./fusefsc");
        // assign callbacks
        mi->ops.lookup      = cb_lookup;
        mi->ops.readdir     = cb_readdir;
        mi->ops.mkdir       = cb_mkdir;
        mi->ops.rmdir       = cb_rmdir;
        mi->ops.unlink      = cb_unlink;
        mi->ops.rename      = cb_rename;
        mi->ops.open        = cb_open;
        mi->ops.release     = cb_release;
        mi->ops.read        = cb_read;
        mi->ops.write       = cb_write;
        mi->ops.create      = cb_create;
        mi->ops.fsync       = cb_fsync;
        mi->ops.getattr     = cb_getattr;
        mi->ops.setattr     = cb_setattr;
        mi->ops.opendir     = cb_opendir;
        mi->ops.releasedir  = cb_releasedir;
        mi->ops.statfs      = cb_statfs;
        // create session
        rv = 2;
        mi->se = fuse_session_new(&mi->args, &mi->ops,
                sizeof(struct fuse_lowlevel_ops), user);
        if (mi->se != NULL)
        {
            // mount
            rv = 3;
            int mount_rv = fuse_session_mount(mi->se, mountpoint);
            if (mount_rv == 0)
            {
                // all good
                *obj = mi;
                return 0;
            }
            fuse_session_destroy(mi->se);
        }
        fuse_opt_free_args(&mi->args);
        free(mi);
    }
    return rv;
}

//*****************************************************************************
int
myfuse_delete(void* obj)
{
    struct myfuse_info* mi;

    mi = (struct myfuse_info*)obj;
    if (mi == NULL)
    {
        return 0;
    }
    fuse_session_unmount(mi->se);
    fuse_session_destroy(mi->se);
    free(mi->buf.mem);
    fuse_opt_free_args(&mi->args);
    free(mi);
    return 0;
}

//*****************************************************************************
int
myfuse_get_fds(void* obj, int* fd)
{
    struct myfuse_info* mi;
    int lfd;

    mi = (struct myfuse_info*)obj;
    if (mi == NULL)
    {
        return 1;
    }
    lfd = fuse_session_fd(mi->se);
    if (lfd >= 0)
    {
        *fd = lfd;
        return 0;
    }
    return 2;
}

//*****************************************************************************
int
myfuse_check_fds(void* obj)
{
    int size;
    struct myfuse_info* mi;

    mi = (struct myfuse_info*)obj;
    if (mi != NULL)
    {
        size = fuse_session_receive_buf(mi->se, &mi->buf);
        if (size > 0)
        {
            fuse_session_process_buf(mi->se, &mi->buf);
        }
        return 0;
    }
    return 1;
}

//*****************************************************************************
struct fuse_bufvec*
myfuse_bufvec_create(size_t count)
{
    if (count == 0)
    {
        return NULL;
    }
    if (count == 1)
    {
        return (struct fuse_bufvec*)calloc(1, sizeof(struct fuse_bufvec));
    }
    return (struct fuse_bufvec*)calloc(1, sizeof(struct fuse_bufvec) +
            sizeof(struct fuse_buf) * count);
}

//*****************************************************************************
void
myfuse_bufvec_delete(struct fuse_bufvec* bufv)
{
    free(bufv);
}

//*****************************************************************************
void
myfuse_bufvec_set(struct fuse_bufvec* bufv, size_t index,
        struct fuse_buf* buf)
{
    bufv->buf[index] = *buf;
}

//*****************************************************************************
void
myfuse_file_info_get(struct fuse_file_info* fi, int32_t* flags,
        uint32_t* padding, uint64_t* fh, uint64_t* lock_owner,
        uint32_t* poll_events, int32_t* backing_id, uint64_t* compat_flags)
{
    uint32_t lpadding;
    uint32_t val;

    *flags = fi->flags;
    lpadding = fi->writepage;
    val = fi->direct_io;                lpadding |= val << 1;
    val = fi->keep_cache;               lpadding |= val << 2;
    val = fi->flush;                    lpadding |= val << 3;
    val = fi->nonseekable;              lpadding |= val << 4;
    val = fi->flock_release;            lpadding |= val << 5;
    val = fi->cache_readdir;            lpadding |= val << 6;
    val = fi->noflush;                  lpadding |= val << 7;
    val = fi->parallel_direct_writes;   lpadding |= val << 8;
    *padding = lpadding;
    *fh = fi->fh;
    *lock_owner = fi->lock_owner;
    *poll_events = fi->poll_events;
    *backing_id = fi->backing_id;
    *compat_flags = fi->compat_flags;
}

//*****************************************************************************
struct fuse_file_info*
myfuse_file_info_create(int32_t flags,
        uint32_t padding, uint64_t fh, uint64_t lock_owner,
        uint32_t poll_events, int32_t backing_id, uint64_t compat_flags)
{
    struct fuse_file_info* fi;

    fi = (struct fuse_file_info*)calloc(1, sizeof(struct fuse_file_info));
    if (fi == NULL)
    {
        return NULL;
    }
    fi->flags = flags;
    fi->writepage               = padding & 1;
    fi->direct_io               = (padding >> 1) & 1;
    fi->keep_cache              = (padding >> 2) & 1;
    fi->flush                   = (padding >> 3) & 1;
    fi->nonseekable             = (padding >> 4) & 1;
    fi->flock_release           = (padding >> 5) & 1;
    fi->cache_readdir           = (padding >> 6) & 1;
    fi->noflush                 = (padding >> 7) & 1;
    fi->parallel_direct_writes  = (padding >> 8) & 1;
    fi->fh = fh;
    fi->lock_owner = lock_owner;
    fi->poll_events = poll_events;
    fi->backing_id = backing_id;
    fi->compat_flags = compat_flags;
    return fi;
}

//*****************************************************************************
void
myfuse_file_info_delete(struct fuse_file_info* fi)
{
    free(fi);
}
