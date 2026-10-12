// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The C shim of aud_midi_apple.
//
// CoreMIDI calls its receive blocks on its own high-priority threads and
// reuses the event lists after the block returns; its notification blocks
// only arrive on a thread that runs a run loop. Dart can neither block
// those threads nor keep their pointers, so this shim
//
// - runs one CFRunLoop thread that creates every MIDI client, so that
//   notifications arrive even in a Dart process without a run loop,
// - copies every received MIDIEventPacket into a ring buffer of the client
//   and signals Dart through a NativeCallable.listener function pointer,
// - builds MIDIEventLists for sending,
// - offers a "closed" handshake so that Dart can wait until no callback is
//   in flight before it closes the NativeCallable,
// - and calls native taps (aud_midi_apple_tap.h) on the receive thread
//   with the packets of a source, with "gone" from the notification thread.

#ifndef AUD_MIDI_APPLE_H
#define AUD_MIDI_APPLE_H

#include <stdint.h>

#include "aud_midi_apple_tap.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The signal bit for new packet records in the ring buffer.
#define AUD_MIDI_APPLE_SIGNAL_PACKETS 1

/// The signal bit for new notification records.
#define AUD_MIDI_APPLE_SIGNAL_NOTIFICATIONS 2

/// The number of 32-bit words in front of the UMP words of a packet record:
/// ref con, protocol, timestamp low, timestamp high, arrival low, arrival
/// high and word count.
#define AUD_MIDI_APPLE_RECORD_HEADER_WORDS 7

/// The number of 32-bit words of a notification record: message id and up
/// to five values that depend on the message id.
#define AUD_MIDI_APPLE_NOTIFICATION_WORDS 6

/// The message id of the notification record that reports lost
/// notifications.
#define AUD_MIDI_APPLE_NOTIFICATIONS_LOST 0

/// The largest MIDIEventList the shim builds, in bytes (CoreMIDI's limit).
#define AUD_MIDI_APPLE_MAX_LIST_BYTES 65536

/// The error the shim returns for invalid arguments (CoreMIDI's paramErr).
#define AUD_MIDI_APPLE_PARAM_ERROR -50

/// The error the shim returns when the close handshake times out.
#define AUD_MIDI_APPLE_TIMEOUT_ERROR -1

/// The error the shim returns when the operating system lacks an API
/// (CoreServices' unimpErr).
#define AUD_MIDI_APPLE_UNSUPPORTED_ERROR -4

/// Receives the signal bits of new data; called from CoreMIDI threads.
typedef void (*AudMidiAppleSignal)(int32_t signals);

/// A MIDI client with its input ports, output port and ring buffer.
typedef struct AudMidiAppleClient AudMidiAppleClient;

/// Creates a MIDI client named [name] (UTF-8) on the shim's run loop thread
/// with one MIDI 1.0 input port, one MIDI 2.0 input port, one output port
/// and a ring buffer of [capacity_words] words (rounded up to a power of
/// two). [signal] is called whenever new data waits.
///
/// Returns 0 and stores the client in [out_client], or the OSStatus of the
/// failed CoreMIDI call.
int32_t aud_midi_apple_client_create(const char *name,
                                     AudMidiAppleSignal signal,
                                     uint32_t capacity_words,
                                     AudMidiAppleClient **out_client);

/// Returns the MIDIClientRef of [client].
uint32_t aud_midi_apple_client_ref(const AudMidiAppleClient *client);

/// Returns the output port of [client].
uint32_t aud_midi_apple_output_port(const AudMidiAppleClient *client);

/// Returns the input port of [client] for [protocol] (1 = MIDI 1.0,
/// 2 = MIDI 2.0), or 0 for another protocol.
uint32_t aud_midi_apple_input_port(const AudMidiAppleClient *client,
                                   int32_t protocol);

/// Creates a virtual destination named [name] (UTF-8) with [protocol] whose
/// packets enter the ring buffer of [client] with [ref_con]. Returns 0 and
/// stores the endpoint in [out_destination], or an OSStatus;
/// AUD_MIDI_APPLE_PARAM_ERROR for a protocol other than 1 and 2.
int32_t aud_midi_apple_destination_create(AudMidiAppleClient *client,
                                          const char *name, int32_t protocol,
                                          uint32_t ref_con,
                                          uint32_t *out_destination);

/// Copies complete packet records into [buffer] (at most [capacity_words]
/// words) and returns the number of words copied; 0 when the ring buffer is
/// empty. Clears the pending packet signal first.
uint32_t aud_midi_apple_read_packets(AudMidiAppleClient *client,
                                     uint32_t *buffer,
                                     uint32_t capacity_words);

/// Copies up to [capacity_records] notification records into [buffer] and
/// returns their number. Clears the pending notification signal first.
uint32_t aud_midi_apple_read_notifications(AudMidiAppleClient *client,
                                           uint32_t *buffer,
                                           uint32_t capacity_records);

/// Returns the number of packets dropped because the ring buffer was full
/// since the last call, and resets it.
uint64_t aud_midi_apple_take_dropped(AudMidiAppleClient *client);

/// Marks [client] closed and waits up to [timeout_ms] milliseconds until no
/// callback is in flight. Afterwards no callback touches the ring buffer or
/// calls the signal any more. Returns 0, or AUD_MIDI_APPLE_TIMEOUT_ERROR.
int32_t aud_midi_apple_client_close(AudMidiAppleClient *client,
                                    int32_t timeout_ms);

/// Closes [client] if needed, disposes its ports and the MIDI client and
/// frees its memory. Endpoints created with the client are disposed by
/// CoreMIDI together with it.
void aud_midi_apple_client_dispose(AudMidiAppleClient *client);

/// Sends the UMP [words] through [port] to [destination] at [timestamp]
/// (mach ticks, 0 = now) in event lists of [protocol]. Returns 0 or an
/// OSStatus; AUD_MIDI_APPLE_PARAM_ERROR when the words end in the middle
/// of a UMP or for a protocol other than 1 and 2.
int32_t aud_midi_apple_send(uint32_t port, uint32_t destination,
                            int32_t protocol, uint64_t timestamp,
                            const uint32_t *words, uint32_t word_count);

/// Distributes the UMP [words] from the virtual [source] with [timestamp]
/// (mach ticks; 0 means now) to the clients connected to it. Returns 0 or
/// an OSStatus.
int32_t aud_midi_apple_receive(uint32_t source, int32_t protocol,
                               uint64_t timestamp, const uint32_t *words,
                               uint32_t word_count);

/// Returns the number of 32-bit words of the UMP that starts with [word].
uint32_t aud_midi_apple_ump_size(uint32_t word);

/// Returns kMIDIPropertyUMPActiveGroupBitmap (a CFStringRef), or NULL
/// before macOS 14 and iOS 17.
const void *aud_midi_apple_property_ump_active_group_bitmap(void);

/// Returns kMIDIPropertyUMPCanTransmitGroupless (a CFStringRef), or NULL
/// before macOS 14 and iOS 17.
const void *aud_midi_apple_property_ump_can_transmit_groupless(void);

/// Returns 1 when the Bluetooth MIDI driver functions exist (macOS 13,
/// iOS 16), else 0.
int32_t aud_midi_apple_bluetooth_available(void);

/// Calls MIDIBluetoothDriverActivateAllConnections; returns its OSStatus, or
/// AUD_MIDI_APPLE_UNSUPPORTED_ERROR before macOS 13 and iOS 16.
int32_t aud_midi_apple_bluetooth_activate_all(void);

/// Calls MIDIBluetoothDriverDisconnect for the CoreBluetooth peripheral
/// [uuid] (UTF-8); returns its OSStatus, or
/// AUD_MIDI_APPLE_UNSUPPORTED_ERROR before macOS 13 and iOS 16.
int32_t aud_midi_apple_bluetooth_disconnect(const char *uuid);

/// Presents Apple's Bluetooth MIDI device picker
/// (CABTMIDICentralViewController) with a Done button on the main thread of
/// iOS; calls [done] with 0 once it is dismissed, or with
/// AUD_MIDI_APPLE_UNSUPPORTED_ERROR when no view controller can present it.
/// Returns 0, or AUD_MIDI_APPLE_UNSUPPORTED_ERROR at once on macOS.
int32_t aud_midi_apple_show_bluetooth_picker(AudMidiAppleSignal done);

/// The browse event of a resolved service: name, host and port.
#define AUD_MIDI_APPLE_BROWSE_FOUND 1

/// The browse event of a service that disappeared: name only.
#define AUD_MIDI_APPLE_BROWSE_LOST 2

/// The browse event of a failed browse: the port carries the DNS-SD error.
#define AUD_MIDI_APPLE_BROWSE_ERROR 3

/// Receives browse events; [name] and [host] are malloc'ed (or NULL) and
/// belong to the receiver, which frees them with free().
typedef void (*AudMidiAppleBrowseCallback)(int32_t event, char *name,
                                           char *host, int32_t port);

/// A running DNS-SD browse.
typedef struct AudMidiAppleBrowser AudMidiAppleBrowser;

/// A registered DNS-SD service.
typedef struct AudMidiAppleService AudMidiAppleService;

/// Browses the local network for services of [type] (e.g.
/// "_apple-midi._udp") and resolves each to host and port; [callback] runs
/// on a private queue. Returns 0 and stores the browser in [out_browser],
/// or a DNS-SD error.
int32_t aud_midi_apple_browse_start(const char *type,
                                    AudMidiAppleBrowseCallback callback,
                                    AudMidiAppleBrowser **out_browser);

/// Stops [browser]; no callback runs after it returns.
void aud_midi_apple_browse_stop(AudMidiAppleBrowser *browser);

/// Registers the service [name] of [type] on [port] with the TXT record
/// [txt] ([txt_length] bytes) and waits up to [timeout_ms] for the
/// registrar. Returns 0, stores the service in [out_service] and the
/// registered name, which may differ after a conflict, in [out_name]
/// ([name_capacity] bytes); or returns a DNS-SD error.
int32_t aud_midi_apple_service_register(const char *name, const char *type,
                                        uint16_t port, const uint8_t *txt,
                                        uint16_t txt_length,
                                        int32_t timeout_ms, char *out_name,
                                        uint32_t name_capacity,
                                        AudMidiAppleService **out_service);

/// Withdraws [service].
void aud_midi_apple_service_unregister(AudMidiAppleService *service);

/// Returns the current host time in mach ticks.
uint64_t aud_midi_apple_now(void);

/// Stores the numerator and the denominator that convert mach ticks to
/// nanoseconds.
void aud_midi_apple_timebase(uint32_t *numer, uint32_t *denom);

/// Returns [ticks] in nanoseconds of the host clock, computed in 128-bit
/// integers: the time of the native taps.
uint64_t aud_midi_apple_ticks_to_ns(uint64_t ticks);

// .............................................................................
// Native taps

/// Attaches the tap [function] with [user] to the packets that reach
/// [client] with [ref_con] from the source [source]: the receive thread
/// calls it once per MIDIEventPacket with the UMP words
/// (AUD_MIDI_APPLE_TAP_UMP) and the timestamp in nanoseconds (0 becomes
/// the arrival time), and the notification thread reports
/// AUD_MIDI_APPLE_TAP_GONE when the source is removed or goes offline.
/// With [ring] 1 the packets go to the ring buffer as well, with 0 to the
/// tap only. Returns 0, AUD_MIDI_APPLE_PARAM_ERROR or
/// AUD_MIDI_APPLE_TAP_FULL_ERROR.
int32_t aud_midi_apple_tap_attach(AudMidiAppleClient *client,
                                  uint32_t ref_con, uint32_t source,
                                  AudMidiAppleTapFunction function,
                                  void *user, int32_t ring);

/// Detaches the tap of [ref_con]: no call starts afterwards, and the
/// function returns only after the calls in flight returned, waiting up to
/// [timeout_ms]. Returns 0, AUD_MIDI_APPLE_PARAM_ERROR, or
/// AUD_MIDI_APPLE_TIMEOUT_ERROR when a call did not return (the slot is
/// leaked, never freed, and a line is logged).
int32_t aud_midi_apple_tap_detach(AudMidiAppleClient *client,
                                  uint32_t ref_con, int32_t timeout_ms);

/// Sets whether the packets of [ref_con] go to the ring buffer as well.
int32_t aud_midi_apple_tap_set_ring(AudMidiAppleClient *client,
                                    uint32_t ref_con, int32_t ring);

/// Tells the tap of [ref_con] its new [source] after the source came back
/// under another endpoint, so that the next offline is reported again.
int32_t aud_midi_apple_tap_set_source(AudMidiAppleClient *client,
                                      uint32_t ref_con, uint32_t source);

/// Returns the number of packets the tap of [ref_con] dropped because a
/// call was running already since the last call, and resets it.
uint64_t aud_midi_apple_tap_take_dropped(AudMidiAppleClient *client,
                                         uint32_t ref_con);

#ifdef __cplusplus
}
#endif

#endif  // AUD_MIDI_APPLE_H
