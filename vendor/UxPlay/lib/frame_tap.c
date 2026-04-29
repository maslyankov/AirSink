/*
 * frame_tap.c — AirSink patch for UxPlay. See frame_tap.h.
 */
#include "frame_tap.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>

#if defined(__APPLE__)
#include <sys/uio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include <objc/message.h>
#endif

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0  /* macOS: use SO_NOSIGPIPE on the socket instead */
#endif

static int               tap_listen_fd = -1;
static int               tap_client_fd = -1;
static pthread_t         tap_accept_thread;
static volatile int      tap_running = 0;
static char              tap_socket_path[256] = {0};
static pthread_mutex_t   tap_client_lock = PTHREAD_MUTEX_INITIALIZER;

static void set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void send_handshake(int fd) {
    /* "AIRT" magic + version=1 */
    uint8_t hello[5] = { 'A', 'I', 'R', 'T', 1 };
    ssize_t n = send(fd, hello, sizeof(hello), MSG_NOSIGNAL);
    (void)n;  /* if it fails, the next write will close the client */
}

static void *accept_loop(void *arg) {
    (void)arg;
    while (tap_running) {
        int fd = accept(tap_listen_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            if (!tap_running) break;
            usleep(100 * 1000);
            continue;
        }

#if defined(__APPLE__) && defined(SO_NOSIGPIPE)
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        /* Generous send buffer + nonblocking writes; we drop on backpressure. */
        int sndbuf = 4 * 1024 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        set_nonblock(fd);

        pthread_mutex_lock(&tap_client_lock);
        if (tap_client_fd >= 0) close(tap_client_fd);
        tap_client_fd = fd;
        pthread_mutex_unlock(&tap_client_lock);

        send_handshake(fd);
    }
    return NULL;
}

#if defined(__APPLE__)
/* Saved original implementation of -[NSApplication setActivationPolicy:].
 * Our replacement always coerces the requested policy to .accessory so
 * GStreamer's setup calls can't bring the Dock icon back. */
typedef long NSAirSinkInteger;
static IMP original_setActivationPolicy_imp = NULL;

static unsigned char airsink_setActivationPolicy_swizzled(id self, SEL _cmd, NSAirSinkInteger policy) {
    (void)policy;  /* always force .accessory = 1 */
    typedef unsigned char (*OriginalImp)(id, SEL, NSAirSinkInteger);
    return ((OriginalImp)original_setActivationPolicy_imp)(self, _cmd, (NSAirSinkInteger)1);
}

static void install_setActivationPolicy_swizzle(void) {
    if (original_setActivationPolicy_imp) return;  /* already installed */
    Class nsApp = objc_getClass("NSApplication");
    if (!nsApp) return;
    SEL sel = sel_registerName("setActivationPolicy:");
    Method m = class_getInstanceMethod(nsApp, sel);
    if (!m) return;
    original_setActivationPolicy_imp = method_getImplementation(m);
    method_setImplementation(m, (IMP)airsink_setActivationPolicy_swizzled);
}

/* Inner: actual AppKit calls. MUST be invoked on the main thread. */
static void hide_from_dock_macos_unsafe(void) {
    /* dlopen AppKit unconditionally — cheap if already loaded. */
    static void *appkit_handle = NULL;
    if (!appkit_handle) {
        appkit_handle = dlopen(
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            RTLD_LAZY | RTLD_GLOBAL);
    }
    if (!appkit_handle) {
        fprintf(stderr, "frame_tap: AppKit dlopen failed: %s\n", dlerror());
        return;
    }

    /* Install the policy-coercion swizzle the first time we run. */
    install_setActivationPolicy_swizzle();

    Class nsApp = objc_getClass("NSApplication");
    if (!nsApp) {
        fprintf(stderr, "frame_tap: NSApplication class not found\n");
        return;
    }
    SEL sharedSel = sel_registerName("sharedApplication");
    id app = ((id (*)(id, SEL))objc_msgSend)((id)nsApp, sharedSel);
    if (!app) {
        fprintf(stderr, "frame_tap: NSApp sharedApplication returned nil\n");
        return;
    }
    /* setActivationPolicy: is now swizzled — argument is ignored, .accessory wins. */
    SEL setPolicy = sel_registerName("setActivationPolicy:");
    ((unsigned char (*)(id, SEL, long))objc_msgSend)(app, setPolicy, (long)1);
}

/* Public: thread-safe wrapper. gst_macos_main runs real_main on a worker
 * thread and keeps [NSApp run] on main, so we have to dispatch the
 * AppKit call to the main queue or it silently no-ops. */
static void hide_from_dock_macos(void) {
    if (pthread_main_np()) {
        hide_from_dock_macos_unsafe();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            hide_from_dock_macos_unsafe();
        });
    }
}

/* Run as early as possible — before main() executes. Sets the activation
 * policy so when GStreamer's osxvideosink (or anything else) creates the
 * shared NSApp it inherits .accessory and never gets a Dock icon. */
__attribute__((constructor))
static void airsink_early_dock_hide(void) {
    const char *flag = getenv("AIRSINK_HIDE_DOCK");
    if (!flag || !*flag || flag[0] == '0') return;
    hide_from_dock_macos();
}
#endif

int frame_tap_init(const char *socket_path) {
    if (!socket_path || !*socket_path) return -1;
    if (tap_listen_fd >= 0) return -1;  /* already initialized */

    if (strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "frame_tap: socket path too long: %s\n", socket_path);
        return -1;
    }

    unlink(socket_path);  /* clear stale socket file */

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "frame_tap: socket() failed: %s\n", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "frame_tap: bind(%s) failed: %s\n", socket_path, strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, 1) < 0) {
        fprintf(stderr, "frame_tap: listen() failed: %s\n", strerror(errno));
        close(fd);
        unlink(socket_path);
        return -1;
    }

    tap_listen_fd = fd;
    strncpy(tap_socket_path, socket_path, sizeof(tap_socket_path) - 1);
    tap_running = 1;

    if (pthread_create(&tap_accept_thread, NULL, accept_loop, NULL) != 0) {
        fprintf(stderr, "frame_tap: pthread_create failed\n");
        tap_running = 0;
        close(fd);
        tap_listen_fd = -1;
        unlink(socket_path);
        return -1;
    }

    fprintf(stdout, "frame_tap: listening at %s\n", socket_path);

#if defined(__APPLE__)
    hide_from_dock_macos();
#endif
    return 0;
}

void frame_tap_write(uint8_t codec, uint64_t pts_ns, const uint8_t *data, uint32_t len) {
    if (tap_listen_fd < 0 || !data || len == 0) return;

    /* Snapshot client fd under lock, then release; iovec write outside the lock. */
    pthread_mutex_lock(&tap_client_lock);
    int fd = tap_client_fd;
    pthread_mutex_unlock(&tap_client_lock);
    if (fd < 0) return;

    /* Header: codec(1) + pts(8 BE) + len(4 BE) = 13 bytes */
    uint8_t hdr[13];
    hdr[0] = codec;
    for (int i = 0; i < 8; i++) hdr[1 + i] = (uint8_t)((pts_ns >> (56 - 8 * i)) & 0xff);
    hdr[9]  = (uint8_t)((len >> 24) & 0xff);
    hdr[10] = (uint8_t)((len >> 16) & 0xff);
    hdr[11] = (uint8_t)((len >> 8) & 0xff);
    hdr[12] = (uint8_t)(len & 0xff);

    struct iovec iov[2];
    iov[0].iov_base = hdr;
    iov[0].iov_len  = sizeof(hdr);
    iov[1].iov_base = (void *)data;
    iov[1].iov_len  = len;

    struct msghdr msg = {0};
    msg.msg_iov    = iov;
    msg.msg_iovlen = 2;

    ssize_t n = sendmsg(fd, &msg, MSG_NOSIGNAL);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            /* Client is slow — drop this access unit. */
            return;
        }
        /* EPIPE/ECONNRESET/etc: drop the client, accept loop will pick up the next. */
        pthread_mutex_lock(&tap_client_lock);
        if (tap_client_fd == fd) {
            close(tap_client_fd);
            tap_client_fd = -1;
        }
        pthread_mutex_unlock(&tap_client_lock);
    }
}

int frame_tap_is_active(void) {
    return tap_listen_fd >= 0 ? 1 : 0;
}

void frame_tap_hide_dock(void) {
#if defined(__APPLE__)
    hide_from_dock_macos();
#endif
}

void frame_tap_shutdown(void) {
    tap_running = 0;

    pthread_mutex_lock(&tap_client_lock);
    if (tap_client_fd >= 0) {
        shutdown(tap_client_fd, SHUT_RDWR);
        close(tap_client_fd);
        tap_client_fd = -1;
    }
    pthread_mutex_unlock(&tap_client_lock);

    if (tap_listen_fd >= 0) {
        shutdown(tap_listen_fd, SHUT_RDWR);
        close(tap_listen_fd);
        tap_listen_fd = -1;
    }
    /* Joining the accept thread: it's blocked on accept(); shutdown above wakes it. */
    pthread_join(tap_accept_thread, NULL);

    if (tap_socket_path[0]) {
        unlink(tap_socket_path);
        tap_socket_path[0] = '\0';
    }
}
