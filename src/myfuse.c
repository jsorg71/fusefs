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
    int rv = 1;
    struct myfuse_info* mi = (struct myfuse_info*)
            calloc(1, sizeof(struct myfuse_info));
    if (mi != NULL)
    {
        fuse_opt_add_arg(&mi->args, "./fusefsc");
        //mi->user = user;
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
    struct myfuse_info* mi = (struct myfuse_info*)obj;
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
myfuse_get_fds(void* obj,
        int* rfds, size_t* num_rfds,
        int* wfds, size_t* num_wfds,
        int* timeout)
{
    struct myfuse_info* mi = (struct myfuse_info*)obj;
    int fd = fuse_session_fd(mi->se);
    if (fd >= 0)
    {
        size_t lnum_rfds = *num_rfds;
        rfds[lnum_rfds] = fd;
        lnum_rfds++;
        *num_rfds = lnum_rfds;
        return 0;
    }
    return 1;
}

//*****************************************************************************
int
myfuse_check_fds(void* obj)
{
    struct myfuse_info* mi = (struct myfuse_info*)obj;
    int size = fuse_session_receive_buf(mi->se, &mi->buf);
    if (size > 0)
    {
        fuse_session_process_buf(mi->se, &mi->buf);
        return 0;
    }
    return 1;
}
