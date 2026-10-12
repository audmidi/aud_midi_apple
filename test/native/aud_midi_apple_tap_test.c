// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The host-side test of the tap slots of the shim, the part independent of
// CoreMIDI: the table, the busy flag, the detach guarantee, "gone", the
// tick conversion and the probe. scripts/test-native.js builds it under the
// address, undefined behaviour, realtime and thread sanitizers.

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "aud_midi_apple.h"
#include "aud_midi_apple_tap.h"

#ifdef AUD_MIDI_RTSAN
#define NONBLOCKING [[clang::nonblocking]]
#else
#define NONBLOCKING
#endif

static int failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,     \
              #condition);                                                 \
      failures++;                                                          \
    }                                                                      \
  } while (0)

enum {
  UMP_CALLS,
  BYTE_CALLS,
  GONE_CALLS,
  WORDS,
  BYTES,
  LAST_TIME,
  SUM,
  FIRST,
  OVERLAPS,
  MIN_DELAY
};

static int64_t value(const AudMidiAppleProbe *probe, int index) {
  int64_t values[AUD_MIDI_APPLE_PROBE_VALUES];
  aud_midi_apple_probe_read(probe, values, AUD_MIDI_APPLE_PROBE_VALUES);
  return values[index];
}

static void sleep_ms(int ms) {
  const struct timespec pause = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&pause, NULL);
}

// Delivers [words] as one packet of [ref_con] through the receive path.
static int deliver(AudMidiAppleTapTable *table, uint32_t ref_con,
                   const uint32_t *words, uint32_t count, int64_t time,
                   int32_t *ring) {
  AudMidiAppleTapSlot *slot = aud_midi_apple_taps_enter(table, ref_con, 1, ring);
  if (slot == NULL) return 0;
  aud_midi_apple_taps_call(slot, AUD_MIDI_APPLE_TAP_UMP, words, count, time);
  aud_midi_apple_taps_leave(slot);
  return 1;
}

// #############################################################################
// Slots and calls

static void test_packets_reach_the_tap_of_the_ref_con(void) {
  AudMidiAppleTapTable *table = aud_midi_apple_taps_create();
  AudMidiAppleProbe *probe = aud_midi_apple_probe_create();
  int32_t ring = 0;
  const uint32_t note_on[2] = {0x40903c00, 0xc8000000};
  // Without a slot the packets go to the ring only.
  CHECK(deliver(table, 1, note_on, 2, 5, &ring) == 0);
  CHECK(ring == 1);
  CHECK(aud_midi_apple_taps_attach(table, 1, 11, aud_midi_apple_probe_function(),
                                   probe, 0) == 0);
  CHECK(aud_midi_apple_taps_count(table) == 1);
  CHECK(deliver(table, 1, note_on, 2, 5, &ring) == 1);
  CHECK(ring == 0);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(value(probe, WORDS) == 2);
  CHECK(value(probe, SUM) == (int64_t)0x40903c00 + 0xc8000000);
  CHECK(value(probe, FIRST) == 0x40903c00);
  CHECK(value(probe, LAST_TIME) == 5);
  // Another ref con has no slot.
  CHECK(deliver(table, 2, note_on, 2, 5, &ring) == 0);
  CHECK(ring == 1);
  CHECK(value(probe, UMP_CALLS) == 1);
  // The ring flag follows set_ring.
  CHECK(aud_midi_apple_taps_set_ring(table, 1, 1) == 0);
  CHECK(deliver(table, 1, note_on, 2, 6, &ring) == 1);
  CHECK(ring == 1);
  CHECK(aud_midi_apple_taps_set_ring(table, 2, 1) == AUD_MIDI_APPLE_PARAM_ERROR);
  // Detach: no further call, the slot is free again.
  CHECK(aud_midi_apple_taps_detach(table, 1, 100) == 0);
  CHECK(aud_midi_apple_taps_count(table) == 0);
  CHECK(deliver(table, 1, note_on, 2, 7, &ring) == 0);
  CHECK(ring == 1);
  CHECK(value(probe, UMP_CALLS) == 2);
  CHECK(aud_midi_apple_taps_detach(table, 1, 100) == AUD_MIDI_APPLE_PARAM_ERROR);
  CHECK(aud_midi_apple_taps_free(table) == 0);
  aud_midi_apple_probe_free(probe);
}

static void test_attach_refuses_bad_arguments_and_full_tables(void) {
  AudMidiAppleTapTable *table = aud_midi_apple_taps_create();
  AudMidiAppleProbe *probe = aud_midi_apple_probe_create();
  CHECK(aud_midi_apple_taps_attach(table, 0, 1, aud_midi_apple_probe_function(),
                                   probe, 0) == AUD_MIDI_APPLE_PARAM_ERROR);
  CHECK(aud_midi_apple_taps_attach(table, 1, 1, NULL, probe, 0) ==
        AUD_MIDI_APPLE_PARAM_ERROR);
  for (uint32_t ref_con = 1; ref_con <= AUD_MIDI_APPLE_TAP_SLOTS; ref_con++) {
    CHECK(aud_midi_apple_taps_attach(table, ref_con, ref_con,
                                     aud_midi_apple_probe_function(), probe,
                                     0) == 0);
  }
  // A ref con with a slot already, and no slot left.
  CHECK(aud_midi_apple_taps_attach(table, 1, 1, aud_midi_apple_probe_function(),
                                   probe, 0) == AUD_MIDI_APPLE_PARAM_ERROR);
  CHECK(aud_midi_apple_taps_attach(table, 100, 1,
                                   aud_midi_apple_probe_function(), probe,
                                   0) == AUD_MIDI_APPLE_TAP_FULL_ERROR);
  uint32_t sources[AUD_MIDI_APPLE_TAP_SLOTS];
  CHECK(aud_midi_apple_taps_sources(table, sources, AUD_MIDI_APPLE_TAP_SLOTS) ==
        AUD_MIDI_APPLE_TAP_SLOTS);
  CHECK(sources[0] == 1 && sources[63] == 64);
  CHECK(aud_midi_apple_taps_sources(table, sources, 2) == 2);
  // A table with slots cannot be freed.
  CHECK(aud_midi_apple_taps_free(table) == AUD_MIDI_APPLE_PARAM_ERROR);
  for (uint32_t ref_con = 1; ref_con <= AUD_MIDI_APPLE_TAP_SLOTS; ref_con++) {
    CHECK(aud_midi_apple_taps_detach(table, ref_con, 100) == 0);
  }
  CHECK(aud_midi_apple_taps_free(table) == 0);
  aud_midi_apple_probe_free(probe);
}

// #############################################################################
// Gone

static void test_gone_is_reported_once_per_gap(void) {
  AudMidiAppleTapTable *table = aud_midi_apple_taps_create();
  AudMidiAppleProbe *probe = aud_midi_apple_probe_create();
  CHECK(aud_midi_apple_taps_source_gone(table, 11, 1) == 0);
  CHECK(aud_midi_apple_taps_attach(table, 1, 11, aud_midi_apple_probe_function(),
                                   probe, 0) == 0);
  CHECK(aud_midi_apple_taps_source_gone(table, 12, 1) == 0);
  CHECK(aud_midi_apple_taps_source_gone(table, 11, 1) == 1);
  CHECK(value(probe, GONE_CALLS) == 1);
  CHECK(value(probe, LAST_TIME) == 1);
  // Reported once until the source is set again.
  CHECK(aud_midi_apple_taps_source_gone(table, 11, 2) == 0);
  CHECK(aud_midi_apple_taps_source_offline(table, 11, 1, 3) == 0);
  CHECK(aud_midi_apple_taps_set_source(table, 1, 41) == 0);
  CHECK(aud_midi_apple_taps_source_offline(table, 41, 1, 4) == 1);
  CHECK(value(probe, GONE_CALLS) == 2);
  CHECK(value(probe, LAST_TIME) == 4);
  // Online clears the mark, the next offline reports again.
  CHECK(aud_midi_apple_taps_source_offline(table, 41, 0, 5) == 0);
  CHECK(aud_midi_apple_taps_source_offline(table, 41, 1, 6) == 1);
  CHECK(value(probe, GONE_CALLS) == 3);
  CHECK(aud_midi_apple_taps_set_source(table, 2, 41) == AUD_MIDI_APPLE_PARAM_ERROR);
  CHECK(aud_midi_apple_taps_detach(table, 1, 100) == 0);
  CHECK(aud_midi_apple_taps_free(table) == 0);
  aud_midi_apple_probe_free(probe);
}

// #############################################################################
// Busy

static AudMidiAppleTapTable *busy_table;
static _Atomic int busy_entered;
static _Atomic int busy_release;

static _Atomic int blocking_gone;

static void blocking_tap(void *user, uint32_t kind, const void *data,
                         uint32_t count, int64_t host_time_ns) {
  (void)user, (void)data, (void)count, (void)host_time_ns;
  if (kind == AUD_MIDI_APPLE_TAP_GONE) {
    atomic_fetch_add(&blocking_gone, 1);
    return;
  }
  atomic_store(&busy_entered, 1);
  while (!atomic_load(&busy_release)) sleep_ms(1);
}

static void *deliver_once(void *argument) {
  (void)argument;
  const uint32_t clock_word = 0x10f80000;
  int32_t ring = 0;
  deliver(busy_table, 1, &clock_word, 1, 0, &ring);
  return NULL;
}

static void test_a_contended_call_drops_and_counts(void) {
  busy_table = aud_midi_apple_taps_create();
  CHECK(aud_midi_apple_taps_attach(busy_table, 1, 11, blocking_tap, NULL, 1) ==
        0);
  pthread_t thread;
  pthread_create(&thread, NULL, deliver_once, NULL);
  while (!atomic_load(&busy_entered)) sleep_ms(1);
  // A second call while the first runs: dropped, the ring still served.
  const uint32_t words[2] = {0x40903c00, 0xc8000000};
  int32_t ring = 0;
  AudMidiAppleTapSlot *slot =
      aud_midi_apple_taps_enter(busy_table, 1, 3, &ring);
  CHECK(slot == NULL);
  CHECK(ring == 1);
  CHECK(aud_midi_apple_taps_take_dropped(busy_table, 1) == 3);
  CHECK(aud_midi_apple_taps_take_dropped(busy_table, 1) == 0);
  CHECK(aud_midi_apple_taps_take_dropped(busy_table, 2) == 0);
  // "gone" ignores the busy flag and runs next to the data call.
  CHECK(aud_midi_apple_taps_source_gone(busy_table, 11, 9) == 1);
  CHECK(atomic_load(&blocking_gone) == 1);
  // The detach waits for the running call and leaks on a timeout.
  CHECK(aud_midi_apple_taps_detach(busy_table, 1, 20) ==
        AUD_MIDI_APPLE_TIMEOUT_ERROR);
  CHECK(aud_midi_apple_taps_count(busy_table) == 1);
  atomic_store(&busy_release, 1);
  pthread_join(thread, NULL);
  CHECK(aud_midi_apple_taps_count(busy_table) == 1);
  CHECK(aud_midi_apple_taps_free(busy_table) == AUD_MIDI_APPLE_PARAM_ERROR);
  CHECK(deliver(busy_table, 1, words, 2, 0, &ring) == 0);
  (void)words;
}

// A detach that timed out leaves the ref con in the leaked slot. A later
// attach of the same ref con lands in another slot, and both the receive
// and the notification thread must find that one, not stop at the leaked
// slot in front of it.
static void test_a_leaked_slot_does_not_hide_the_new_tap(void) {
  atomic_store(&busy_entered, 0);
  atomic_store(&busy_release, 0);
  const int gone_before = atomic_load(&blocking_gone);
  busy_table = aud_midi_apple_taps_create();
  CHECK(aud_midi_apple_taps_attach(busy_table, 1, 11, blocking_tap, NULL, 1) ==
        0);
  pthread_t thread;
  pthread_create(&thread, NULL, deliver_once, NULL);
  while (!atomic_load(&busy_entered)) sleep_ms(1);
  CHECK(aud_midi_apple_taps_detach(busy_table, 1, 20) ==
        AUD_MIDI_APPLE_TIMEOUT_ERROR);
  CHECK(aud_midi_apple_taps_count(busy_table) == 1);
  // The same ref con and source again: a second slot behind the leaked one.
  AudMidiAppleProbe *probe = aud_midi_apple_probe_create();
  CHECK(aud_midi_apple_taps_attach(busy_table, 1, 11,
                                   aud_midi_apple_probe_function(), probe,
                                   0) == 0);
  CHECK(aud_midi_apple_taps_count(busy_table) == 2);
  // Data reaches the new tap, the ring flag is the new slot's.
  const uint32_t note_on[2] = {0x40903c00, 0xc8000000};
  int32_t ring = 1;
  CHECK(deliver(busy_table, 1, note_on, 2, 8, &ring) == 1);
  CHECK(ring == 0);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(value(probe, LAST_TIME) == 8);
  CHECK(aud_midi_apple_taps_take_dropped(busy_table, 1) == 0);
  // GONE reaches the new tap only; the leaked tap is not called again.
  CHECK(aud_midi_apple_taps_source_gone(busy_table, 11, 9) == 1);
  CHECK(value(probe, GONE_CALLS) == 1);
  CHECK(value(probe, LAST_TIME) == 9);
  CHECK(atomic_load(&blocking_gone) == gone_before);
  // The new slot detaches cleanly, the leaked one stays.
  atomic_store(&busy_release, 1);
  pthread_join(thread, NULL);
  CHECK(aud_midi_apple_taps_detach(busy_table, 1, 100) == 0);
  CHECK(aud_midi_apple_taps_count(busy_table) == 1);
  CHECK(deliver(busy_table, 1, note_on, 2, 10, &ring) == 0);
  CHECK(ring == 1);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(aud_midi_apple_taps_free(busy_table) == AUD_MIDI_APPLE_PARAM_ERROR);
  aud_midi_apple_probe_free(probe);
}

// #############################################################################
// Threads

typedef struct {
  AudMidiAppleTapTable *table;
  _Atomic int stop;
  _Atomic int64_t delivered;
} Sender;

static void *send_loop(void *argument) {
  Sender *sender = argument;
  const uint32_t clock_word = 0x10f80000;
  int32_t ring = 0;
  while (!atomic_load(&sender->stop)) {
    if (deliver(sender->table, 1, &clock_word, 1, 0, &ring)) {
      atomic_fetch_add(&sender->delivered, 1);
    }
  }
  return NULL;
}

static _Atomic int64_t slow_calls;
static _Atomic int64_t slow_after_detach;
static _Atomic int detached;

static void slow_tap(void *user, uint32_t kind, const void *data,
                     uint32_t count, int64_t host_time_ns) {
  (void)user, (void)data, (void)count, (void)host_time_ns;
  if (kind == AUD_MIDI_APPLE_TAP_GONE) return;
  if (atomic_load(&detached)) atomic_fetch_add(&slow_after_detach, 1);
  atomic_fetch_add(&slow_calls, 1);
  sleep_ms(1);
}

static void test_detach_waits_for_the_calls_in_flight(void) {
  AudMidiAppleTapTable *table = aud_midi_apple_taps_create();
  Sender sender = {.table = table};
  pthread_t threads[4];
  for (int i = 0; i < 4; i++) {
    pthread_create(&threads[i], NULL, send_loop, &sender);
  }
  for (int round = 0; round < 20; round++) {
    atomic_store(&detached, 0);
    CHECK(aud_midi_apple_taps_attach(table, 1, 11, slow_tap, NULL, 0) == 0);
    sleep_ms(3);
    // "gone" from a third thread meanwhile is fine.
    aud_midi_apple_taps_source_gone(table, 11, 1);
    CHECK(aud_midi_apple_taps_detach(table, 1, 1000) == 0);
    atomic_store(&detached, 1);
    sleep_ms(2);
    CHECK(atomic_load(&slow_after_detach) == 0);
  }
  atomic_store(&sender.stop, 1);
  for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
  CHECK(atomic_load(&slow_calls) > 0);
  CHECK(atomic_load(&sender.delivered) == atomic_load(&slow_calls));
  CHECK(aud_midi_apple_taps_free(table) == 0);
}

// #############################################################################
// Time

static void test_ticks_convert_without_overflow(void) {
  CHECK(aud_midi_apple_taps_ticks_to_ns(0, 125, 3) == 0);
  CHECK(aud_midi_apple_taps_ticks_to_ns(3, 125, 3) == 125);
  CHECK(aud_midi_apple_taps_ticks_to_ns(7, 125, 3) == 291);
  CHECK(aud_midi_apple_taps_ticks_to_ns(UINT64_MAX, 1, 1) == UINT64_MAX);
  // 2^63 ticks of 125/3 ns: the product needs 71 bits.
  const uint64_t big = (uint64_t)1 << 63;
  CHECK(aud_midi_apple_taps_ticks_to_ns(big, 125, 3) ==
        (uint64_t)(((unsigned __int128)big * 125) / 3));
  CHECK(aud_midi_apple_taps_ticks_to_ns(5, 1, 0) == 0);
  // With the timebase of the process the result is the host clock in ns.
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  const uint64_t now = mach_absolute_time();
  const uint64_t ns =
      aud_midi_apple_taps_ticks_to_ns(now, timebase.numer, timebase.denom);
  const uint64_t reference = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  CHECK(ns <= reference && reference - ns < 100000000);
}

// #############################################################################
// Realtime: the receive path never blocks or allocates. Under the realtime
// sanitizer this function is checked for both; with AUD_TEST_RTSAN_PROBE
// set it allocates, which the sanitizer has to catch.

static bool rtsan_probe;

static void receive_path(AudMidiAppleTapTable *table,
                         const uint32_t *words) NONBLOCKING {
  int32_t ring = 0;
  AudMidiAppleTapSlot *slot = aud_midi_apple_taps_enter(table, 1, 1, &ring);
  if (slot != NULL) {
    aud_midi_apple_taps_call(slot, AUD_MIDI_APPLE_TAP_UMP, words, 2, 1);
    aud_midi_apple_taps_leave(slot);
  }
  aud_midi_apple_taps_source_gone(table, 11, 2);
  if (rtsan_probe) {
    volatile char *probe = malloc(16);
    if (probe != NULL) probe[0] = 1;
    free((void *)probe);
  }
}

static void test_receive_path_is_nonblocking(void) {
  AudMidiAppleTapTable *table = aud_midi_apple_taps_create();
  AudMidiAppleProbe *probe = aud_midi_apple_probe_create();
  CHECK(aud_midi_apple_taps_attach(table, 1, 11, aud_midi_apple_probe_function(),
                                   probe, 0) == 0);
  const uint32_t words[2] = {0x40903c00, 0xc8000000};
  receive_path(table, words);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(value(probe, GONE_CALLS) == 1);
  CHECK(aud_midi_apple_taps_detach(table, 1, 100) == 0);
  CHECK(aud_midi_apple_taps_free(table) == 0);
  aud_midi_apple_probe_free(probe);
}

// #############################################################################

int main(void) {
  rtsan_probe = getenv("AUD_TEST_RTSAN_PROBE") != NULL;
  if (rtsan_probe) {
    test_receive_path_is_nonblocking();
    printf("aud_midi_apple_tap_test: the probe allocation passed\n");
    return 0;
  }
  test_packets_reach_the_tap_of_the_ref_con();
  test_attach_refuses_bad_arguments_and_full_tables();
  test_gone_is_reported_once_per_gap();
  test_detach_waits_for_the_calls_in_flight();
  test_ticks_convert_without_overflow();
  test_receive_path_is_nonblocking();
  // Last: they leak a slot on purpose.
  test_a_contended_call_drops_and_counts();
  test_a_leaked_slot_does_not_hide_the_new_tap();
  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  printf("aud_midi_apple_tap_test: all checks passed\n");
  return 0;
}
