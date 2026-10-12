// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The tap slots of the C shim: native consumers of the packets of a source,
// called on CoreMIDI's receive thread without the Dart isolate in between.
//
// A table holds the slots of one client, keyed by the ref con of the
// connected source. The receive thread enters the slot of a ref con, calls
// the tap once per MIDIEventPacket and leaves; the notification thread
// reports "gone" when the source disappears or goes offline. Nothing in
// here depends on CoreMIDI, so that the tests run under the sanitizers on
// the development machine:
//
// - an in-flight count per slot: a detach waits until it is 0 and never
//   frees a slot a call may still touch (a timeout leaks it and logs),
// - a busy flag per slot: a data call that finds the slot busy drops its
//   packets and counts them, so that the path never takes a lock; "gone"
//   ignores the flag and is never dropped,
// - a "gone" mark per slot, so that the gap between offline and online is
//   reported once,
// - the 128-bit conversion of mach ticks to nanoseconds.

#ifndef AUD_MIDI_APPLE_TAP_H
#define AUD_MIDI_APPLE_TAP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The kinds of a tap call: UMP words in host byte order (one complete
/// packet per call), bytes of a MIDI 1.0 stream (never from CoreMIDI), or
/// the source is gone (no data).
#define AUD_MIDI_APPLE_TAP_UMP 1
#define AUD_MIDI_APPLE_TAP_BYTES 2
#define AUD_MIDI_APPLE_TAP_GONE 3

/// The number of tap slots of a client; an attach beyond it fails.
#define AUD_MIDI_APPLE_TAP_SLOTS 64

/// The error of an attach when every slot is taken.
#define AUD_MIDI_APPLE_TAP_FULL_ERROR -2

/// The tap function (the contract with the consumer): [data] are [count]
/// words (UMP), NULL and 0 for GONE; [host_time_ns] is
/// `mach_absolute_time` in nanoseconds, the clock of
/// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`.
typedef void (*AudMidiAppleTapFunction)(void *user, uint32_t kind,
                                        const void *data, uint32_t count,
                                        int64_t host_time_ns);

/// The tap slots of one client.
typedef struct AudMidiAppleTapTable AudMidiAppleTapTable;

/// An entered slot, valid until aud_midi_apple_taps_leave.
typedef struct AudMidiAppleTapSlot AudMidiAppleTapSlot;

/// Creates an empty table.
AudMidiAppleTapTable *aud_midi_apple_taps_create(void);

/// Frees [table]; every slot must be detached. Returns 0, or
/// AUD_MIDI_APPLE_PARAM_ERROR when a slot is still attached or leaked;
/// the table then stays.
int32_t aud_midi_apple_taps_free(AudMidiAppleTapTable *table);

/// Takes a slot for the packets of [ref_con] from the source [source]:
/// [function] is called with [user]. [ring] 1 keeps the packets going to
/// the ring buffer as well (a Dart listener), 0 sends them to the tap only.
/// Returns 0, AUD_MIDI_APPLE_PARAM_ERROR for a ref con of 0, a NULL
/// function or a ref con with a slot already, or
/// AUD_MIDI_APPLE_TAP_FULL_ERROR.
int32_t aud_midi_apple_taps_attach(AudMidiAppleTapTable *table,
                                   uint32_t ref_con, uint32_t source,
                                   AudMidiAppleTapFunction function,
                                   void *user, int32_t ring);

/// Stops the calls of the slot of [ref_con] and waits up to [timeout_ms]
/// milliseconds until none is in flight, then frees the slot. Returns 0,
/// AUD_MIDI_APPLE_PARAM_ERROR when [ref_con] has no slot, or
/// AUD_MIDI_APPLE_TIMEOUT_ERROR when a call did not return in time; the
/// slot is then leaked and never reused.
int32_t aud_midi_apple_taps_detach(AudMidiAppleTapTable *table,
                                   uint32_t ref_con, int32_t timeout_ms);

/// Sets whether the packets of [ref_con] go to the ring buffer as well.
int32_t aud_midi_apple_taps_set_ring(AudMidiAppleTapTable *table,
                                     uint32_t ref_con, int32_t ring);

/// Sets the source of the slot of [ref_con] after the source came back
/// under a new endpoint, and clears its "gone" mark.
int32_t aud_midi_apple_taps_set_source(AudMidiAppleTapTable *table,
                                       uint32_t ref_con, uint32_t source);

/// Returns the number of packets the slot of [ref_con] dropped because it
/// was busy since the last call, and resets it; 0 for an unknown ref con.
uint64_t aud_midi_apple_taps_take_dropped(AudMidiAppleTapTable *table,
                                          uint32_t ref_con);

/// Copies the sources of the attached slots into [out] (at most
/// [capacity]) and returns their number.
uint32_t aud_midi_apple_taps_sources(AudMidiAppleTapTable *table,
                                     uint32_t *out, uint32_t capacity);

/// Returns the number of slots taken, leaked ones included.
int32_t aud_midi_apple_taps_count(const AudMidiAppleTapTable *table);

// .............................................................................
// The receive thread

/// Enters the slot of [ref_con] for a list of [packets] packets: returns
/// the slot when it is attached and not busy, else NULL — busy drops and
/// counts the packets. [ring_out] receives whether the packets go to the
/// ring buffer as well: 1 without a slot. Never blocks.
AudMidiAppleTapSlot *aud_midi_apple_taps_enter(AudMidiAppleTapTable *table,
                                               uint32_t ref_con,
                                               uint32_t packets,
                                               int32_t *ring_out);

/// Calls the tap of the entered [slot] with [count] words of [data] at
/// [host_time_ns]. Never blocks.
void aud_midi_apple_taps_call(AudMidiAppleTapSlot *slot, uint32_t kind,
                              const void *data, uint32_t count,
                              int64_t host_time_ns);

/// Leaves the entered [slot]. Never blocks.
void aud_midi_apple_taps_leave(AudMidiAppleTapSlot *slot);

// .............................................................................
// The notification thread

/// Reports GONE at [host_time_ns] to the slots whose source is [source],
/// once until the source is set again. Returns the number of taps called.
/// Ignores the busy flag; may run while a data call runs.
int32_t aud_midi_apple_taps_source_gone(AudMidiAppleTapTable *table,
                                        uint32_t source,
                                        int64_t host_time_ns);

/// Reports GONE to the slots of [source] when [offline] is 1 and they are
/// not gone yet; clears their "gone" mark when [offline] is 0, so that the
/// next offline reports again. Returns the number of taps called.
int32_t aud_midi_apple_taps_source_offline(AudMidiAppleTapTable *table,
                                           uint32_t source, int32_t offline,
                                           int64_t host_time_ns);

// .............................................................................
// Time

/// Returns [ticks] of a mach timebase of [numer] / [denom] in nanoseconds,
/// computed in 128-bit integers so that it never overflows.
uint64_t aud_midi_apple_taps_ticks_to_ns(uint64_t ticks, uint32_t numer,
                                         uint32_t denom);

// .............................................................................
// Probe: a tap for the tests and the example

/// A tap that counts what it receives.
typedef struct AudMidiAppleProbe AudMidiAppleProbe;

/// The number of values aud_midi_apple_probe_read fills: UMP calls, byte
/// calls, gone calls, words, bytes, the last host time, the sum of all
/// words and bytes, the first word or byte of the last data call, the
/// number of calls that overlapped another one, and the smallest
/// difference between the time of a data call and its arrival in ns.
#define AUD_MIDI_APPLE_PROBE_VALUES 10

/// Creates a probe; free it with aud_midi_apple_probe_free after the tap
/// was detached.
AudMidiAppleProbe *aud_midi_apple_probe_create(void);

/// Frees [probe].
void aud_midi_apple_probe_free(AudMidiAppleProbe *probe);

/// Returns the tap function of the probes; the probe is the user.
AudMidiAppleTapFunction aud_midi_apple_probe_function(void);

/// Copies up to [capacity] of the AUD_MIDI_APPLE_PROBE_VALUES values of
/// [probe] into [out].
void aud_midi_apple_probe_read(const AudMidiAppleProbe *probe, int64_t *out,
                               uint32_t capacity);

#ifdef __cplusplus
}
#endif

#endif  // AUD_MIDI_APPLE_TAP_H
