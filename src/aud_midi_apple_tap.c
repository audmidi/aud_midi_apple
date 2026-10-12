// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_midi_apple_tap.h"

#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "aud_midi_apple.h"

// #############################################################################
// Slots

enum { SLOT_FREE = 0, SLOT_ACTIVE = 1, SLOT_CLOSING = 2, SLOT_LEAKED = 3 };

struct AudMidiAppleTapSlot {
  _Atomic int32_t state;
  _Atomic uint32_t ref_con;
  _Atomic uint32_t source;
  // Calls inside the slot; a detach waits until it is 0.
  _Atomic int32_t in_flight;
  // A data call owns the slot while it runs; another one drops.
  _Atomic int32_t busy;
  _Atomic int32_t ring;
  // Whether GONE was reported since the source was set.
  _Atomic int32_t gone;
  _Atomic uint64_t dropped;
  AudMidiAppleTapFunction function;
  void *user;
};

struct AudMidiAppleTapTable {
  // Serialises attach and detach; the call path never takes it.
  os_unfair_lock lock;
  _Atomic int32_t attached;
  struct AudMidiAppleTapSlot slots[AUD_MIDI_APPLE_TAP_SLOTS];
};

static void log_leak(uint32_t ref_con) {
  fprintf(stderr,
          "aud_midi_apple: the tap of ref con %u did not return, its slot "
          "leaks\n",
          ref_con);
}

static uint64_t now_ns(void) {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

AudMidiAppleTapTable *aud_midi_apple_taps_create(void) {
  AudMidiAppleTapTable *table = calloc(1, sizeof(AudMidiAppleTapTable));
  table->lock = OS_UNFAIR_LOCK_INIT;
  return table;
}

int32_t aud_midi_apple_taps_free(AudMidiAppleTapTable *table) {
  os_unfair_lock_lock(&table->lock);
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    if (atomic_load(&table->slots[i].state) != SLOT_FREE) {
      os_unfair_lock_unlock(&table->lock);
      return AUD_MIDI_APPLE_PARAM_ERROR;
    }
  }
  os_unfair_lock_unlock(&table->lock);
  free(table);
  return 0;
}

// The active slot of [ref_con], or NULL; under the lock.
static struct AudMidiAppleTapSlot *slot_of(AudMidiAppleTapTable *table,
                                           uint32_t ref_con) {
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    struct AudMidiAppleTapSlot *slot = &table->slots[i];
    if (atomic_load(&slot->state) == SLOT_ACTIVE &&
        atomic_load(&slot->ref_con) == ref_con) {
      return slot;
    }
  }
  return NULL;
}

int32_t aud_midi_apple_taps_attach(AudMidiAppleTapTable *table,
                                   uint32_t ref_con, uint32_t source,
                                   AudMidiAppleTapFunction function,
                                   void *user, int32_t ring) {
  if (ref_con == 0 || function == NULL) return AUD_MIDI_APPLE_PARAM_ERROR;
  os_unfair_lock_lock(&table->lock);
  if (slot_of(table, ref_con) != NULL) {
    os_unfair_lock_unlock(&table->lock);
    return AUD_MIDI_APPLE_PARAM_ERROR;
  }
  int32_t result = AUD_MIDI_APPLE_TAP_FULL_ERROR;
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    struct AudMidiAppleTapSlot *slot = &table->slots[i];
    if (atomic_load(&slot->state) != SLOT_FREE) continue;
    slot->function = function;
    slot->user = user;
    atomic_store(&slot->source, source);
    atomic_store(&slot->ring, ring != 0);
    atomic_store(&slot->gone, 0);
    atomic_store(&slot->busy, 0);
    atomic_store(&slot->dropped, 0);
    atomic_store(&slot->ref_con, ref_con);
    atomic_store(&slot->state, SLOT_ACTIVE);
    atomic_fetch_add(&table->attached, 1);
    result = 0;
    break;
  }
  os_unfair_lock_unlock(&table->lock);
  return result;
}

int32_t aud_midi_apple_taps_detach(AudMidiAppleTapTable *table,
                                   uint32_t ref_con, int32_t timeout_ms) {
  os_unfair_lock_lock(&table->lock);
  struct AudMidiAppleTapSlot *slot = slot_of(table, ref_con);
  if (slot == NULL) {
    os_unfair_lock_unlock(&table->lock);
    return AUD_MIDI_APPLE_PARAM_ERROR;
  }
  atomic_store(&slot->state, SLOT_CLOSING);
  atomic_fetch_sub(&table->attached, 1);
  os_unfair_lock_unlock(&table->lock);

  const uint64_t deadline = now_ns() + (uint64_t)timeout_ms * 1000000;
  bool drained = true;
  while (atomic_load(&slot->in_flight) != 0) {
    if (now_ns() > deadline) {
      drained = false;
      break;
    }
    const struct timespec pause = {0, 50000};
    nanosleep(&pause, NULL);
  }

  os_unfair_lock_lock(&table->lock);
  if (drained) {
    slot->function = NULL;
    slot->user = NULL;
    atomic_store(&slot->ref_con, 0);
    atomic_store(&slot->state, SLOT_FREE);
  } else {
    // The call may still touch the function and the user; the slot stays
    // as it is, never reused.
    atomic_store(&slot->state, SLOT_LEAKED);
    log_leak(ref_con);
  }
  os_unfair_lock_unlock(&table->lock);
  return drained ? 0 : AUD_MIDI_APPLE_TIMEOUT_ERROR;
}

int32_t aud_midi_apple_taps_set_ring(AudMidiAppleTapTable *table,
                                     uint32_t ref_con, int32_t ring) {
  os_unfair_lock_lock(&table->lock);
  struct AudMidiAppleTapSlot *slot = slot_of(table, ref_con);
  if (slot != NULL) atomic_store(&slot->ring, ring != 0);
  os_unfair_lock_unlock(&table->lock);
  return slot != NULL ? 0 : AUD_MIDI_APPLE_PARAM_ERROR;
}

int32_t aud_midi_apple_taps_set_source(AudMidiAppleTapTable *table,
                                       uint32_t ref_con, uint32_t source) {
  os_unfair_lock_lock(&table->lock);
  struct AudMidiAppleTapSlot *slot = slot_of(table, ref_con);
  if (slot != NULL) {
    atomic_store(&slot->source, source);
    atomic_store(&slot->gone, 0);
  }
  os_unfair_lock_unlock(&table->lock);
  return slot != NULL ? 0 : AUD_MIDI_APPLE_PARAM_ERROR;
}

uint64_t aud_midi_apple_taps_take_dropped(AudMidiAppleTapTable *table,
                                          uint32_t ref_con) {
  os_unfair_lock_lock(&table->lock);
  struct AudMidiAppleTapSlot *slot = slot_of(table, ref_con);
  const uint64_t dropped =
      slot != NULL ? atomic_exchange(&slot->dropped, 0) : 0;
  os_unfair_lock_unlock(&table->lock);
  return dropped;
}

uint32_t aud_midi_apple_taps_sources(AudMidiAppleTapTable *table,
                                     uint32_t *out, uint32_t capacity) {
  uint32_t count = 0;
  os_unfair_lock_lock(&table->lock);
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS && count < capacity; i++) {
    struct AudMidiAppleTapSlot *slot = &table->slots[i];
    if (atomic_load(&slot->state) == SLOT_ACTIVE) {
      out[count++] = atomic_load(&slot->source);
    }
  }
  os_unfair_lock_unlock(&table->lock);
  return count;
}

int32_t aud_midi_apple_taps_count(const AudMidiAppleTapTable *table) {
  int32_t count = 0;
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    if (atomic_load(&table->slots[i].state) != SLOT_FREE) count++;
  }
  return count;
}

// #############################################################################
// The receive thread

// Counts the caller into [slot] when it is active for [ref_con]; a detach
// that saw the count at 0 cannot complete while the caller is inside, one
// that set the state to closing first is seen here.
static bool enter(struct AudMidiAppleTapSlot *slot, uint32_t ref_con) {
  atomic_fetch_add(&slot->in_flight, 1);
  if (atomic_load(&slot->state) != SLOT_ACTIVE ||
      atomic_load(&slot->ref_con) != ref_con) {
    atomic_fetch_sub(&slot->in_flight, 1);
    return false;
  }
  return true;
}

AudMidiAppleTapSlot *aud_midi_apple_taps_enter(AudMidiAppleTapTable *table,
                                               uint32_t ref_con,
                                               uint32_t packets,
                                               int32_t *ring_out) {
  *ring_out = 1;
  if (atomic_load(&table->attached) == 0) return NULL;
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    struct AudMidiAppleTapSlot *slot = &table->slots[i];
    if (atomic_load(&slot->ref_con) != ref_con) continue;
    if (!enter(slot, ref_con)) return NULL;
    *ring_out = atomic_load(&slot->ring);
    if (atomic_exchange(&slot->busy, 1) != 0) {
      atomic_fetch_add(&slot->dropped, packets);
      atomic_fetch_sub(&slot->in_flight, 1);
      return NULL;
    }
    return slot;
  }
  return NULL;
}

void aud_midi_apple_taps_call(AudMidiAppleTapSlot *slot, uint32_t kind,
                              const void *data, uint32_t count,
                              int64_t host_time_ns) {
  slot->function(slot->user, kind, data, count, host_time_ns);
}

void aud_midi_apple_taps_leave(AudMidiAppleTapSlot *slot) {
  atomic_store(&slot->busy, 0);
  atomic_fetch_sub(&slot->in_flight, 1);
}

// #############################################################################
// The notification thread

// Reports GONE to the slots of [source]; [once] skips slots that are gone
// already and marks the reported ones.
static int32_t report_gone(AudMidiAppleTapTable *table, uint32_t source,
                           int64_t host_time_ns, bool once) {
  int32_t called = 0;
  if (atomic_load(&table->attached) == 0) return 0;
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    struct AudMidiAppleTapSlot *slot = &table->slots[i];
    if (atomic_load(&slot->source) != source) continue;
    const uint32_t ref_con = atomic_load(&slot->ref_con);
    if (ref_con == 0 || !enter(slot, ref_con)) continue;
    if (!once || atomic_exchange(&slot->gone, 1) == 0) {
      slot->function(slot->user, AUD_MIDI_APPLE_TAP_GONE, NULL, 0,
                     host_time_ns);
      called++;
    }
    atomic_fetch_sub(&slot->in_flight, 1);
  }
  return called;
}

int32_t aud_midi_apple_taps_source_gone(AudMidiAppleTapTable *table,
                                        uint32_t source,
                                        int64_t host_time_ns) {
  return report_gone(table, source, host_time_ns, true);
}

int32_t aud_midi_apple_taps_source_offline(AudMidiAppleTapTable *table,
                                           uint32_t source, int32_t offline,
                                           int64_t host_time_ns) {
  if (offline) return report_gone(table, source, host_time_ns, true);
  for (int i = 0; i < AUD_MIDI_APPLE_TAP_SLOTS; i++) {
    struct AudMidiAppleTapSlot *slot = &table->slots[i];
    if (atomic_load(&slot->source) == source) atomic_store(&slot->gone, 0);
  }
  return 0;
}

// #############################################################################
// Time

uint64_t aud_midi_apple_taps_ticks_to_ns(uint64_t ticks, uint32_t numer,
                                         uint32_t denom) {
  if (denom == 0) return 0;
  if (numer == denom) return ticks;
  const unsigned __int128 product = (unsigned __int128)ticks * numer;
  return (uint64_t)(product / denom);
}

// #############################################################################
// Probe

struct AudMidiAppleProbe {
  _Atomic int64_t ump_calls;
  _Atomic int64_t byte_calls;
  _Atomic int64_t gone_calls;
  _Atomic int64_t words;
  _Atomic int64_t bytes;
  _Atomic int64_t last_time;
  _Atomic int64_t sum;
  _Atomic int64_t first;
  _Atomic int64_t overlaps;
  _Atomic int64_t min_delay;
  _Atomic int32_t inside;
};

static void probe_tap(void *user, uint32_t kind, const void *data,
                      uint32_t count, int64_t host_time_ns) {
  AudMidiAppleProbe *probe = user;
  if (atomic_fetch_add(&probe->inside, 1) != 0) {
    atomic_fetch_add(&probe->overlaps, 1);
  }
  atomic_store(&probe->last_time, host_time_ns);
  if (kind == AUD_MIDI_APPLE_TAP_GONE) {
    atomic_fetch_add(&probe->gone_calls, 1);
  } else {
    const int64_t delay = (int64_t)now_ns() - host_time_ns;
    if (delay < atomic_load(&probe->min_delay)) {
      atomic_store(&probe->min_delay, delay);
    }
    int64_t sum = 0;
    if (kind == AUD_MIDI_APPLE_TAP_UMP) {
      const uint32_t *words = data;
      for (uint32_t i = 0; i < count; i++) sum += words[i];
      atomic_fetch_add(&probe->ump_calls, 1);
      atomic_fetch_add(&probe->words, count);
      if (count > 0) atomic_store(&probe->first, words[0]);
    } else {
      const uint8_t *bytes = data;
      for (uint32_t i = 0; i < count; i++) sum += bytes[i];
      atomic_fetch_add(&probe->byte_calls, 1);
      atomic_fetch_add(&probe->bytes, count);
      if (count > 0) atomic_store(&probe->first, bytes[0]);
    }
    atomic_fetch_add(&probe->sum, sum);
  }
  atomic_fetch_sub(&probe->inside, 1);
}

AudMidiAppleProbe *aud_midi_apple_probe_create(void) {
  AudMidiAppleProbe *probe = calloc(1, sizeof(AudMidiAppleProbe));
  atomic_store(&probe->min_delay, INT64_MAX);
  return probe;
}

void aud_midi_apple_probe_free(AudMidiAppleProbe *probe) { free(probe); }

AudMidiAppleTapFunction aud_midi_apple_probe_function(void) {
  return probe_tap;
}

void aud_midi_apple_probe_read(const AudMidiAppleProbe *probe, int64_t *out,
                               uint32_t capacity) {
  const int64_t values[AUD_MIDI_APPLE_PROBE_VALUES] = {
      atomic_load(&probe->ump_calls), atomic_load(&probe->byte_calls),
      atomic_load(&probe->gone_calls), atomic_load(&probe->words),
      atomic_load(&probe->bytes),     atomic_load(&probe->last_time),
      atomic_load(&probe->sum),       atomic_load(&probe->first),
      atomic_load(&probe->overlaps),  atomic_load(&probe->min_delay),
  };
  if (capacity > AUD_MIDI_APPLE_PROBE_VALUES) {
    capacity = AUD_MIDI_APPLE_PROBE_VALUES;
  }
  memcpy(out, values, capacity * sizeof(int64_t));
}
