/*
 * frame_tap.h — AirSink patch for UxPlay.
 *
 * Streams decrypted video NALUs (Annex-B H.264/H.265) over a Unix domain
 * socket so a host app can decode and render them itself instead of using
 * uxplay's GStreamer window.
 *
 * Wire format (network byte order):
 *   Once on connect:
 *     char[4]   magic = "AIRT"
 *     uint8_t   version = 1
 *   Per frame:
 *     uint8_t   codec  (1 = H264, 2 = H265)
 *     uint64_t  pts_ns (NTP-domain timestamp from uxplay)
 *     uint32_t  len
 *     uint8_t   data[len]   (Annex-B NALUs, may contain SPS/PPS/VPS+VCL)
 */
#ifndef FRAME_TAP_H
#define FRAME_TAP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FRAME_TAP_CODEC_H264 1
#define FRAME_TAP_CODEC_H265 2

/* Bind a listening Unix socket at `socket_path`. Returns 0 on success.
 * Replaces an existing socket file at the same path. */
int frame_tap_init(const char *socket_path);

/* Non-blocking write of one access unit. No-op if no client connected.
 * Drops the frame (and logs at debug level) if the socket buffer is full. */
void frame_tap_write(uint8_t codec, uint64_t pts_ns, const uint8_t *data, uint32_t len);

/* True once frame_tap_init() has succeeded. Used by the renderer to skip
 * uxplay's own GStreamer decode pipeline when an external consumer is active. */
int frame_tap_is_active(void);

/* macOS only: demote NSApp to .accessory so this process doesn't appear in
 * the Dock or app switcher. Safe to call multiple times. No-op on non-Apple. */
void frame_tap_hide_dock(void);

/* Close client + listening socket and unlink the socket file. */
void frame_tap_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
