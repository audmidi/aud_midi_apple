// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_midi_apple.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <dns_sd.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// #############################################################################
// Client

#define NOTIFICATION_CAPACITY 256

struct AudMidiAppleClient {
  MIDIClientRef client;
  MIDIPortRef input_midi1;
  MIDIPortRef input_midi2;
  MIDIPortRef output;
  AudMidiAppleSignal signal;

  // Close handshake: callbacks count themselves in flight and return
  // immediately once closed is set.
  _Atomic int32_t closed;
  _Atomic int32_t in_flight;
  _Atomic int32_t pending;

  // Packet ring buffer: producers serialise on ring_lock, the consumer
  // reads lock-free.
  os_unfair_lock ring_lock;
  uint32_t *data;
  uint64_t mask;
  uint64_t capacity;
  _Atomic uint64_t head;
  _Atomic uint64_t tail;
  _Atomic uint64_t dropped;

  // Notification queue, rare and small.
  os_unfair_lock notification_lock;
  uint32_t notifications[NOTIFICATION_CAPACITY]
                       [AUD_MIDI_APPLE_NOTIFICATION_WORDS];
  uint32_t notification_count;
  bool notifications_lost;

  // The native taps of the connected sources.
  AudMidiAppleTapTable *taps;
};

// The mach timebase of the process, read once.
static pthread_once_t timebase_once = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t timebase_info;

static void read_timebase(void) { mach_timebase_info(&timebase_info); }

uint64_t aud_midi_apple_ticks_to_ns(uint64_t ticks) {
  pthread_once(&timebase_once, read_timebase);
  return aud_midi_apple_taps_ticks_to_ns(ticks, timebase_info.numer,
                                         timebase_info.denom);
}

// #############################################################################
// Run loop thread

static pthread_once_t run_loop_once = PTHREAD_ONCE_INIT;
static CFRunLoopRef run_loop = NULL;
static MIDIClientRef anchor_client = 0;
static dispatch_semaphore_t run_loop_ready = NULL;

static void keep_alive_perform(void *info) { (void)info; }

static void *run_loop_main(void *argument) {
  (void)argument;
  pthread_setname_np("aud_midi_apple.coremidi");
  run_loop = CFRunLoopGetCurrent();
  CFRetain(run_loop);

  // A run loop without sources returns at once; this one never fires.
  CFRunLoopSourceContext context = {0};
  context.perform = keep_alive_perform;
  CFRunLoopSourceRef keep_alive = CFRunLoopSourceCreate(NULL, 0, &context);
  CFRunLoopAddSource(run_loop, keep_alive, kCFRunLoopCommonModes);

  // The first client of a process decides the run loop of all
  // notifications, and disposing the last client may end the connection
  // to the MIDI server. This anchor client is created here and never
  // disposed.
  MIDIClientCreateWithBlock(CFSTR("aud_midi_apple"), &anchor_client, NULL);

  dispatch_semaphore_signal(run_loop_ready);
  CFRunLoopRun();
  return NULL;
}

static void start_run_loop(void) {
  run_loop_ready = dispatch_semaphore_create(0);
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
  pthread_t thread;
  pthread_create(&thread, &attributes, run_loop_main, NULL);
  pthread_attr_destroy(&attributes);
  dispatch_semaphore_wait(run_loop_ready, DISPATCH_TIME_FOREVER);
}

// Runs [block] on the run loop thread and waits for it.
static void run_sync(void (^block)(void)) {
  pthread_once(&run_loop_once, start_run_loop);
  if (CFRunLoopGetCurrent() == run_loop) {
    block();
    return;
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  CFRunLoopPerformBlock(run_loop, kCFRunLoopCommonModes, ^{
    block();
    dispatch_semaphore_signal(done);
  });
  CFRunLoopWakeUp(run_loop);
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  dispatch_release(done);
}

// #############################################################################
// Callbacks

static bool enter_callback(AudMidiAppleClient *client) {
  atomic_fetch_add(&client->in_flight, 1);
  if (atomic_load(&client->closed)) {
    atomic_fetch_sub(&client->in_flight, 1);
    return false;
  }
  return true;
}

static void leave_callback(AudMidiAppleClient *client) {
  atomic_fetch_sub(&client->in_flight, 1);
}

static void raise_signal(AudMidiAppleClient *client, int32_t bit) {
  if ((atomic_fetch_or(&client->pending, bit) & bit) == 0) {
    client->signal(bit);
  }
}

static void put_word(AudMidiAppleClient *client, uint64_t position,
                     uint32_t value) {
  client->data[position & client->mask] = value;
}

static void on_receive(AudMidiAppleClient *client, const MIDIEventList *list,
                       void *ref_con) {
  if (!enter_callback(client)) return;

  const uint64_t arrival = mach_absolute_time();

  // The native tap first: one call per packet, timestamps in nanoseconds.
  int32_t ring = 1;
  AudMidiAppleTapSlot *slot = aud_midi_apple_taps_enter(
      client->taps, (uint32_t)(uintptr_t)ref_con, list->numPackets, &ring);
  if (slot != NULL) {
    const MIDIEventPacket *tapped = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
      const uint64_t time =
          tapped->timeStamp != 0 ? tapped->timeStamp : arrival;
      aud_midi_apple_taps_call(slot, AUD_MIDI_APPLE_TAP_UMP, tapped->words,
                               tapped->wordCount,
                               (int64_t)aud_midi_apple_ticks_to_ns(time));
      tapped = MIDIEventPacketNext(tapped);
    }
    aud_midi_apple_taps_leave(slot);
  }
  if (!ring) {
    leave_callback(client);
    return;
  }

  uint64_t needed = 0;
  const MIDIEventPacket *packet = &list->packet[0];
  for (UInt32 i = 0; i < list->numPackets; i++) {
    needed += AUD_MIDI_APPLE_RECORD_HEADER_WORDS + packet->wordCount;
    packet = MIDIEventPacketNext(packet);
  }

  os_unfair_lock_lock(&client->ring_lock);
  uint64_t head = atomic_load_explicit(&client->head, memory_order_relaxed);
  const uint64_t tail =
      atomic_load_explicit(&client->tail, memory_order_acquire);
  if (needed <= client->capacity - (head - tail)) {
    packet = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
      const uint64_t time =
          packet->timeStamp != 0 ? packet->timeStamp : arrival;
      put_word(client, head++, (uint32_t)(uintptr_t)ref_con);
      put_word(client, head++, (uint32_t)list->protocol);
      put_word(client, head++, (uint32_t)time);
      put_word(client, head++, (uint32_t)(time >> 32));
      put_word(client, head++, (uint32_t)arrival);
      put_word(client, head++, (uint32_t)(arrival >> 32));
      put_word(client, head++, packet->wordCount);
      for (UInt32 w = 0; w < packet->wordCount; w++) {
        put_word(client, head++, packet->words[w]);
      }
      packet = MIDIEventPacketNext(packet);
    }
    atomic_store_explicit(&client->head, head, memory_order_release);
  } else {
    atomic_fetch_add(&client->dropped, list->numPackets);
  }
  os_unfair_lock_unlock(&client->ring_lock);

  raise_signal(client, AUD_MIDI_APPLE_SIGNAL_PACKETS);
  leave_callback(client);
}

// Reports "gone" to the taps of a source that was removed, and of the
// sources that went offline after a property change; runs on the run loop
// thread, where reading the property is fine.
static void notify_taps(AudMidiAppleClient *client,
                        const MIDINotification *message) {
  const int64_t now = (int64_t)aud_midi_apple_ticks_to_ns(mach_absolute_time());
  if (message->messageID == kMIDIMsgObjectRemoved) {
    const MIDIObjectAddRemoveNotification *change =
        (const MIDIObjectAddRemoveNotification *)message;
    if (change->childType == kMIDIObjectType_Source ||
        change->childType == kMIDIObjectType_ExternalSource) {
      aud_midi_apple_taps_source_gone(client->taps, change->child, now);
    }
    return;
  }
  if (message->messageID != kMIDIMsgPropertyChanged) return;
  const MIDIObjectPropertyChangeNotification *change =
      (const MIDIObjectPropertyChangeNotification *)message;
  if (change->propertyName == NULL ||
      !CFEqual(change->propertyName, kMIDIPropertyOffline)) {
    return;
  }
  uint32_t sources[AUD_MIDI_APPLE_TAP_SLOTS];
  const uint32_t count = aud_midi_apple_taps_sources(
      client->taps, sources, AUD_MIDI_APPLE_TAP_SLOTS);
  for (uint32_t i = 0; i < count; i++) {
    SInt32 offline = 0;
    const OSStatus status = MIDIObjectGetIntegerProperty(
        sources[i], kMIDIPropertyOffline, &offline);
    if (status == noErr) {
      aud_midi_apple_taps_source_offline(client->taps, sources[i],
                                         offline != 0, now);
    }
  }
}

static void on_notification(AudMidiAppleClient *client,
                            const MIDINotification *message) {
  if (!enter_callback(client)) return;

  notify_taps(client, message);

  uint32_t record[AUD_MIDI_APPLE_NOTIFICATION_WORDS] = {0};
  record[0] = (uint32_t)message->messageID;
  switch (message->messageID) {
    case kMIDIMsgObjectAdded:
    case kMIDIMsgObjectRemoved: {
      const MIDIObjectAddRemoveNotification *change =
          (const MIDIObjectAddRemoveNotification *)message;
      record[1] = change->parent;
      record[2] = (uint32_t)change->parentType;
      record[3] = change->child;
      record[4] = (uint32_t)change->childType;
      break;
    }
    case kMIDIMsgPropertyChanged: {
      const MIDIObjectPropertyChangeNotification *change =
          (const MIDIObjectPropertyChangeNotification *)message;
      record[1] = change->object;
      record[2] = (uint32_t)change->objectType;
      break;
    }
    case kMIDIMsgIOError: {
      const MIDIIOErrorNotification *error =
          (const MIDIIOErrorNotification *)message;
      record[1] = error->driverDevice;
      record[2] = (uint32_t)error->errorCode;
      break;
    }
    default:
      break;
  }

  os_unfair_lock_lock(&client->notification_lock);
  if (client->notification_count < NOTIFICATION_CAPACITY) {
    memcpy(client->notifications[client->notification_count++], record,
           sizeof(record));
  } else {
    client->notifications_lost = true;
  }
  os_unfair_lock_unlock(&client->notification_lock);

  raise_signal(client, AUD_MIDI_APPLE_SIGNAL_NOTIFICATIONS);
  leave_callback(client);
}

// #############################################################################
// Client lifecycle

// CoreMIDI aborts the process for unknown protocols in some calls.
static bool is_protocol(int32_t protocol) {
  return protocol == kMIDIProtocol_1_0 || protocol == kMIDIProtocol_2_0;
}

static CFStringRef create_string(const char *utf8) {
  return CFStringCreateWithCString(NULL, utf8 != NULL ? utf8 : "",
                                   kCFStringEncodingUTF8);
}

static uint64_t power_of_two(uint32_t value) {
  uint64_t result = 1024;
  while (result < value) result <<= 1;
  return result;
}

int32_t aud_midi_apple_client_create(const char *name,
                                     AudMidiAppleSignal signal,
                                     uint32_t capacity_words,
                                     AudMidiAppleClient **out_client) {
  if (signal == NULL || out_client == NULL) return AUD_MIDI_APPLE_PARAM_ERROR;

  AudMidiAppleClient *client = calloc(1, sizeof(AudMidiAppleClient));
  client->signal = signal;
  client->capacity = power_of_two(capacity_words);
  client->mask = client->capacity - 1;
  client->data = calloc(client->capacity, sizeof(uint32_t));
  client->ring_lock = OS_UNFAIR_LOCK_INIT;
  client->notification_lock = OS_UNFAIR_LOCK_INIT;
  client->taps = aud_midi_apple_taps_create();

  CFStringRef client_name = create_string(name);
  __block OSStatus status = noErr;
  run_sync(^{
    status = MIDIClientCreateWithBlock(
        client_name, &client->client, ^(const MIDINotification *message) {
          on_notification(client, message);
        });
  });

  MIDIReceiveBlock receive = ^(const MIDIEventList *list, void *ref_con) {
    on_receive(client, list, ref_con);
  };
  if (status == noErr) {
    status = MIDIInputPortCreateWithProtocol(client->client, client_name,
                                             kMIDIProtocol_1_0,
                                             &client->input_midi1, receive);
  }
  if (status == noErr) {
    status = MIDIInputPortCreateWithProtocol(client->client, client_name,
                                             kMIDIProtocol_2_0,
                                             &client->input_midi2, receive);
  }
  if (status == noErr) {
    status =
        MIDIOutputPortCreate(client->client, client_name, &client->output);
  }
  CFRelease(client_name);

  if (status != noErr) {
    aud_midi_apple_client_dispose(client);
    return status;
  }
  *out_client = client;
  return noErr;
}

uint32_t aud_midi_apple_client_ref(const AudMidiAppleClient *client) {
  return client->client;
}

uint32_t aud_midi_apple_output_port(const AudMidiAppleClient *client) {
  return client->output;
}

uint32_t aud_midi_apple_input_port(const AudMidiAppleClient *client,
                                   int32_t protocol) {
  switch (protocol) {
    case kMIDIProtocol_1_0:
      return client->input_midi1;
    case kMIDIProtocol_2_0:
      return client->input_midi2;
    default:
      return 0;
  }
}

int32_t aud_midi_apple_destination_create(AudMidiAppleClient *client,
                                          const char *name, int32_t protocol,
                                          uint32_t ref_con,
                                          uint32_t *out_destination) {
  if (out_destination == NULL || !is_protocol(protocol)) {
    return AUD_MIDI_APPLE_PARAM_ERROR;
  }
  CFStringRef endpoint_name = create_string(name);
  MIDIEndpointRef destination = 0;
  const OSStatus status = MIDIDestinationCreateWithProtocol(
      client->client, endpoint_name, (MIDIProtocolID)protocol, &destination,
      ^(const MIDIEventList *list, void *unused) {
        (void)unused;
        on_receive(client, list, (void *)(uintptr_t)ref_con);
      });
  CFRelease(endpoint_name);
  if (status == noErr) *out_destination = destination;
  return status;
}

uint32_t aud_midi_apple_read_packets(AudMidiAppleClient *client,
                                     uint32_t *buffer,
                                     uint32_t capacity_words) {
  atomic_fetch_and(&client->pending, ~AUD_MIDI_APPLE_SIGNAL_PACKETS);
  uint64_t tail = atomic_load_explicit(&client->tail, memory_order_relaxed);
  const uint64_t head =
      atomic_load_explicit(&client->head, memory_order_acquire);
  uint32_t copied = 0;
  while (tail < head) {
    const uint32_t size =
        AUD_MIDI_APPLE_RECORD_HEADER_WORDS +
        client->data[(tail + AUD_MIDI_APPLE_RECORD_HEADER_WORDS - 1) &
                     client->mask];
    if ((uint64_t)copied + size > capacity_words) break;
    for (uint32_t i = 0; i < size; i++) {
      buffer[copied++] = client->data[(tail++) & client->mask];
    }
  }
  atomic_store_explicit(&client->tail, tail, memory_order_release);
  return copied;
}

uint32_t aud_midi_apple_read_notifications(AudMidiAppleClient *client,
                                           uint32_t *buffer,
                                           uint32_t capacity_records) {
  atomic_fetch_and(&client->pending, ~AUD_MIDI_APPLE_SIGNAL_NOTIFICATIONS);
  os_unfair_lock_lock(&client->notification_lock);
  uint32_t count = 0;
  if (client->notifications_lost && capacity_records > 0) {
    memset(buffer, 0, AUD_MIDI_APPLE_NOTIFICATION_WORDS * sizeof(uint32_t));
    buffer[0] = AUD_MIDI_APPLE_NOTIFICATIONS_LOST;
    client->notifications_lost = false;
    count = 1;
  }
  uint32_t taken = 0;
  while (taken < client->notification_count && count < capacity_records) {
    memcpy(&buffer[count * AUD_MIDI_APPLE_NOTIFICATION_WORDS],
           client->notifications[taken],
           AUD_MIDI_APPLE_NOTIFICATION_WORDS * sizeof(uint32_t));
    taken++;
    count++;
  }
  memmove(client->notifications, client->notifications[taken],
          (client->notification_count - taken) *
              sizeof(client->notifications[0]));
  client->notification_count -= taken;
  os_unfair_lock_unlock(&client->notification_lock);
  return count;
}

uint64_t aud_midi_apple_take_dropped(AudMidiAppleClient *client) {
  return atomic_exchange(&client->dropped, 0);
}

int32_t aud_midi_apple_client_close(AudMidiAppleClient *client,
                                    int32_t timeout_ms) {
  atomic_store(&client->closed, 1);
  const uint64_t deadline =
      clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)timeout_ms * 1000000;
  while (atomic_load(&client->in_flight) != 0) {
    if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > deadline) {
      return AUD_MIDI_APPLE_TIMEOUT_ERROR;
    }
    const struct timespec pause = {0, 50000};
    nanosleep(&pause, NULL);
  }
  return noErr;
}

void aud_midi_apple_client_dispose(AudMidiAppleClient *client) {
  aud_midi_apple_client_close(client, 1000);
  const MIDIClientRef midi_client = client->client;
  if (midi_client != 0) {
    // Notifications run on the run loop thread; disposing there makes sure
    // that none of them is running.
    run_sync(^{
      MIDIClientDispose(midi_client);
    });
  }
  free(client->data);
  client->data = NULL;
  // A receive block that CoreMIDI started just before the disposal may still
  // read the closed flag; the memory goes later. A tap table with a leaked
  // slot stays.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                   aud_midi_apple_taps_free(client->taps);
                   free(client);
                 });
}

// #############################################################################
// Native taps

int32_t aud_midi_apple_tap_attach(AudMidiAppleClient *client,
                                  uint32_t ref_con, uint32_t source,
                                  AudMidiAppleTapFunction function,
                                  void *user, int32_t ring) {
  return aud_midi_apple_taps_attach(client->taps, ref_con, source, function,
                                    user, ring);
}

int32_t aud_midi_apple_tap_detach(AudMidiAppleClient *client,
                                  uint32_t ref_con, int32_t timeout_ms) {
  return aud_midi_apple_taps_detach(client->taps, ref_con, timeout_ms);
}

int32_t aud_midi_apple_tap_set_ring(AudMidiAppleClient *client,
                                    uint32_t ref_con, int32_t ring) {
  return aud_midi_apple_taps_set_ring(client->taps, ref_con, ring);
}

int32_t aud_midi_apple_tap_set_source(AudMidiAppleClient *client,
                                      uint32_t ref_con, uint32_t source) {
  return aud_midi_apple_taps_set_source(client->taps, ref_con, source);
}

uint64_t aud_midi_apple_tap_take_dropped(AudMidiAppleClient *client,
                                         uint32_t ref_con) {
  return aud_midi_apple_taps_take_dropped(client->taps, ref_con);
}

// #############################################################################
// Sending

uint32_t aud_midi_apple_ump_size(uint32_t word) {
  static const uint32_t sizes[16] = {1, 1, 1, 2, 2, 4, 1, 1,
                                     2, 2, 2, 3, 3, 4, 4, 4};
  return sizes[word >> 28];
}

static int32_t emit(uint32_t port, uint32_t endpoint, int32_t protocol,
                    uint64_t timestamp, const uint32_t *words,
                    uint32_t word_count, bool received) {
  uint32_t position = 0;
  while (position < word_count) {
    position += aud_midi_apple_ump_size(words[position]);
  }
  if (position != word_count || (word_count > 0 && words == NULL) ||
      !is_protocol(protocol)) {
    return AUD_MIDI_APPLE_PARAM_ERROR;
  }
  if (word_count == 0) return noErr;

  uint64_t bytes = 1024 + (uint64_t)word_count * 16;
  if (bytes > AUD_MIDI_APPLE_MAX_LIST_BYTES) {
    bytes = AUD_MIDI_APPLE_MAX_LIST_BYTES;
  }
  MIDIEventList *list = malloc(bytes);
  MIDIEventPacket *packet = MIDIEventListInit(list, (MIDIProtocolID)protocol);
  OSStatus status = noErr;
  position = 0;
  while (status == noErr && position < word_count) {
    const uint32_t size = aud_midi_apple_ump_size(words[position]);
    MIDIEventPacket *next = MIDIEventListAdd(list, bytes, packet, timestamp,
                                             size, &words[position]);
    if (next == NULL) {
      if (list->numPackets == 0) {
        status = AUD_MIDI_APPLE_PARAM_ERROR;
        break;
      }
      status = received ? MIDIReceivedEventList(endpoint, list)
                        : MIDISendEventList(port, endpoint, list);
      packet = MIDIEventListInit(list, (MIDIProtocolID)protocol);
      continue;
    }
    packet = next;
    position += size;
  }
  if (status == noErr && list->numPackets > 0) {
    status = received ? MIDIReceivedEventList(endpoint, list)
                      : MIDISendEventList(port, endpoint, list);
  }
  free(list);
  return status;
}

int32_t aud_midi_apple_send(uint32_t port, uint32_t destination,
                            int32_t protocol, uint64_t timestamp,
                            const uint32_t *words, uint32_t word_count) {
  return emit(port, destination, protocol, timestamp, words, word_count,
              false);
}

int32_t aud_midi_apple_receive(uint32_t source, int32_t protocol,
                               uint64_t timestamp, const uint32_t *words,
                               uint32_t word_count) {
  if (timestamp == 0) timestamp = mach_absolute_time();
  return emit(0, source, protocol, timestamp, words, word_count, true);
}

// #############################################################################
// APIs newer than the deployment target

const void *aud_midi_apple_property_ump_active_group_bitmap(void) {
  if (__builtin_available(macOS 14.0, iOS 17.0, *)) {
    return kMIDIPropertyUMPActiveGroupBitmap;
  }
  return NULL;
}

const void *aud_midi_apple_property_ump_can_transmit_groupless(void) {
  if (__builtin_available(macOS 14.0, iOS 17.0, *)) {
    return kMIDIPropertyUMPCanTransmitGroupless;
  }
  return NULL;
}

int32_t aud_midi_apple_bluetooth_available(void) {
  if (__builtin_available(macOS 13.0, iOS 16.0, *)) return 1;
  return 0;
}

int32_t aud_midi_apple_bluetooth_activate_all(void) {
  if (__builtin_available(macOS 13.0, iOS 16.0, *)) {
    return MIDIBluetoothDriverActivateAllConnections();
  }
  return AUD_MIDI_APPLE_UNSUPPORTED_ERROR;
}

int32_t aud_midi_apple_bluetooth_disconnect(const char *uuid) {
  if (__builtin_available(macOS 13.0, iOS 16.0, *)) {
    CFStringRef string = create_string(uuid);
    const OSStatus status = MIDIBluetoothDriverDisconnect(string);
    CFRelease(string);
    return status;
  }
  return AUD_MIDI_APPLE_UNSUPPORTED_ERROR;
}

// #############################################################################
// Bonjour (DNS-SD)

#define MAX_RESOLVES 64

typedef struct {
  AudMidiAppleBrowser *browser;
  int slot;
  char *name;
} Resolve;

struct AudMidiAppleBrowser {
  dispatch_queue_t queue;
  DNSServiceRef browse;
  AudMidiAppleBrowseCallback callback;
  // The number of interfaces a service name was found on.
  CFMutableDictionaryRef counts;
  DNSServiceRef resolves[MAX_RESOLVES];
  Resolve *contexts[MAX_RESOLVES];
};

static char *copy_string(const char *value) {
  return value != NULL ? strdup(value) : NULL;
}

static CFIndex add_count(AudMidiAppleBrowser *browser, const char *name,
                         CFIndex delta) {
  CFStringRef key = create_string(name);
  CFIndex count = 0;
  CFNumberRef old = CFDictionaryGetValue(browser->counts, key);
  if (old != NULL) CFNumberGetValue(old, kCFNumberCFIndexType, &count);
  count += delta;
  if (count > 0) {
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberCFIndexType, &count);
    CFDictionarySetValue(browser->counts, key, value);
    CFRelease(value);
  } else {
    CFDictionaryRemoveValue(browser->counts, key);
  }
  CFRelease(key);
  return count;
}

static void end_resolve(Resolve *resolve) {
  AudMidiAppleBrowser *browser = resolve->browser;
  DNSServiceRefDeallocate(browser->resolves[resolve->slot]);
  browser->resolves[resolve->slot] = NULL;
  browser->contexts[resolve->slot] = NULL;
  free(resolve->name);
  free(resolve);
}

static void on_resolved(DNSServiceRef ref, DNSServiceFlags flags,
                        uint32_t interface, DNSServiceErrorType error,
                        const char *full_name, const char *host,
                        uint16_t port, uint16_t txt_length,
                        const unsigned char *txt, void *context) {
  (void)ref, (void)flags, (void)interface, (void)full_name, (void)txt_length,
      (void)txt;
  Resolve *resolve = context;
  AudMidiAppleBrowser *browser = resolve->browser;
  CFStringRef key = create_string(resolve->name);
  const bool present = CFDictionaryContainsKey(browser->counts, key);
  CFRelease(key);
  if (error == kDNSServiceErr_NoError && present) {
    browser->callback(AUD_MIDI_APPLE_BROWSE_FOUND, copy_string(resolve->name),
                      copy_string(host), ntohs(port));
  }
  end_resolve(resolve);
}

static void start_resolve(AudMidiAppleBrowser *browser, uint32_t interface,
                          const char *name, const char *type,
                          const char *domain) {
  int slot = 0;
  while (slot < MAX_RESOLVES && browser->resolves[slot] != NULL) slot++;
  if (slot == MAX_RESOLVES) return;
  Resolve *resolve = calloc(1, sizeof(Resolve));
  resolve->browser = browser;
  resolve->slot = slot;
  resolve->name = strdup(name);
  DNSServiceRef ref = NULL;
  if (DNSServiceResolve(&ref, 0, interface, name, type, domain, on_resolved,
                        resolve) != kDNSServiceErr_NoError) {
    free(resolve->name);
    free(resolve);
    return;
  }
  browser->resolves[slot] = ref;
  browser->contexts[slot] = resolve;
  DNSServiceSetDispatchQueue(ref, browser->queue);
}

static void on_browsed(DNSServiceRef ref, DNSServiceFlags flags,
                       uint32_t interface, DNSServiceErrorType error,
                       const char *name, const char *type, const char *domain,
                       void *context) {
  (void)ref;
  AudMidiAppleBrowser *browser = context;
  if (error != kDNSServiceErr_NoError) {
    browser->callback(AUD_MIDI_APPLE_BROWSE_ERROR, NULL, NULL, error);
    return;
  }
  if (flags & kDNSServiceFlagsAdd) {
    add_count(browser, name, 1);
    start_resolve(browser, interface, name, type, domain);
  } else if (add_count(browser, name, -1) == 0) {
    browser->callback(AUD_MIDI_APPLE_BROWSE_LOST, copy_string(name), NULL, 0);
  }
}

int32_t aud_midi_apple_browse_start(const char *type,
                                    AudMidiAppleBrowseCallback callback,
                                    AudMidiAppleBrowser **out_browser) {
  if (type == NULL || callback == NULL || out_browser == NULL) {
    return kDNSServiceErr_BadParam;
  }
  AudMidiAppleBrowser *browser = calloc(1, sizeof(AudMidiAppleBrowser));
  browser->callback = callback;
  browser->queue =
      dispatch_queue_create("aud_midi_apple.bonjour", DISPATCH_QUEUE_SERIAL);
  browser->counts = CFDictionaryCreateMutable(
      NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const DNSServiceErrorType error = DNSServiceBrowse(
      &browser->browse, 0, 0, type, NULL, on_browsed, browser);
  if (error != kDNSServiceErr_NoError) {
    browser->browse = NULL;
    aud_midi_apple_browse_stop(browser);
    return error;
  }
  DNSServiceSetDispatchQueue(browser->browse, browser->queue);
  *out_browser = browser;
  return kDNSServiceErr_NoError;
}

void aud_midi_apple_browse_stop(AudMidiAppleBrowser *browser) {
  dispatch_sync(browser->queue, ^{
    if (browser->browse != NULL) DNSServiceRefDeallocate(browser->browse);
    for (int slot = 0; slot < MAX_RESOLVES; slot++) {
      if (browser->contexts[slot] != NULL) end_resolve(browser->contexts[slot]);
    }
  });
  dispatch_release(browser->queue);
  CFRelease(browser->counts);
  free(browser);
}

struct AudMidiAppleService {
  dispatch_queue_t queue;
  DNSServiceRef ref;
  dispatch_semaphore_t registered;
  DNSServiceErrorType error;
  char name[256];
};

static void on_registered(DNSServiceRef ref, DNSServiceFlags flags,
                          DNSServiceErrorType error, const char *name,
                          const char *type, const char *domain,
                          void *context) {
  (void)ref, (void)flags, (void)type, (void)domain;
  AudMidiAppleService *service = context;
  if (service->registered == NULL) return;
  service->error = error;
  if (name != NULL) {
    strlcpy(service->name, name, sizeof(service->name));
  }
  dispatch_semaphore_signal(service->registered);
}

int32_t aud_midi_apple_service_register(const char *name, const char *type,
                                        uint16_t port, const uint8_t *txt,
                                        uint16_t txt_length,
                                        int32_t timeout_ms, char *out_name,
                                        uint32_t name_capacity,
                                        AudMidiAppleService **out_service) {
  if (type == NULL || out_service == NULL) return kDNSServiceErr_BadParam;
  AudMidiAppleService *service = calloc(1, sizeof(AudMidiAppleService));
  service->queue =
      dispatch_queue_create("aud_midi_apple.register", DISPATCH_QUEUE_SERIAL);
  service->registered = dispatch_semaphore_create(0);
  service->error = kDNSServiceErr_Timeout;
  DNSServiceErrorType error = DNSServiceRegister(
      &service->ref, 0, 0, name, type, NULL, NULL, htons(port), txt_length,
      txt, on_registered, service);
  if (error == kDNSServiceErr_NoError) {
    DNSServiceSetDispatchQueue(service->ref, service->queue);
    dispatch_semaphore_wait(
        service->registered,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC));
    error = service->error;
  } else {
    service->ref = NULL;
  }
  if (error != kDNSServiceErr_NoError) {
    aud_midi_apple_service_unregister(service);
    return error;
  }
  if (out_name != NULL && name_capacity > 0) {
    strlcpy(out_name, service->name, name_capacity);
  }
  *out_service = service;
  return kDNSServiceErr_NoError;
}

void aud_midi_apple_service_unregister(AudMidiAppleService *service) {
  dispatch_sync(service->queue, ^{
    if (service->ref != NULL) DNSServiceRefDeallocate(service->ref);
    dispatch_release(service->registered);
    service->registered = NULL;
  });
  dispatch_release(service->queue);
  free(service);
}

// #############################################################################
// Clock

uint64_t aud_midi_apple_now(void) { return mach_absolute_time(); }

void aud_midi_apple_timebase(uint32_t *numer, uint32_t *denom) {
  mach_timebase_info_data_t info;
  mach_timebase_info(&info);
  *numer = info.numer;
  *denom = info.denom;
}
