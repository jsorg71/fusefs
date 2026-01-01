
#ifndef _MYFUSE_H
#define _MYFUSE_H

#include <stdlib.h>

int
myfuse_create(const char* mountpoint, void* user, void** obj);
int
myfuse_delete(void* obj);
int
myfuse_get_fds(void* obj,
        int* rfds, size_t* num_rfds,
        int* wfds, size_t* num_wfds,
        int* timeout);
int
myfuse_check_fds(void* obj);

#endif
