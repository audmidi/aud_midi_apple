// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_midi_apple.h"

#include <TargetConditionals.h>

#if TARGET_OS_IOS
#import <CoreAudioKit/CoreAudioKit.h>
#import <UIKit/UIKit.h>

// #############################################################################
/// Wraps Apple's Bluetooth MIDI view controller with a Done button and
/// reports its dismissal once.
@interface AudMidiApplePickerController : UINavigationController
@property(nonatomic, assign) AudMidiAppleSignal done;
@end

@implementation AudMidiApplePickerController

- (void)finish {
  AudMidiAppleSignal done = self.done;
  self.done = NULL;
  if (done != NULL) done(0);
}

- (void)doneTapped {
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             [self finish];
                           }];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  // Also covers an interactive swipe down.
  if (self.isBeingDismissed || self.presentingViewController == nil) {
    [self finish];
  }
}

@end

/// Returns the top view controller of the key window, or nil.
static UIViewController *top_view_controller(void) {
  UIWindow *key = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if (window.isKeyWindow) key = window;
    }
  }
  UIViewController *top = key.rootViewController;
  while (top.presentedViewController != nil) top = top.presentedViewController;
  return top;
}

int32_t aud_midi_apple_show_bluetooth_picker(AudMidiAppleSignal done) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *top = top_view_controller();
    if (top == nil) {
      done(AUD_MIDI_APPLE_UNSUPPORTED_ERROR);
      return;
    }
    CABTMIDICentralViewController *central =
        [[CABTMIDICentralViewController alloc] init];
    AudMidiApplePickerController *navigation =
        [[AudMidiApplePickerController alloc]
            initWithRootViewController:central];
    navigation.done = done;
    central.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:navigation
                             action:@selector(doneTapped)];
    [top presentViewController:navigation animated:YES completion:nil];
  });
  return 0;
}

#else

int32_t aud_midi_apple_show_bluetooth_picker(AudMidiAppleSignal done) {
  (void)done;
  return AUD_MIDI_APPLE_UNSUPPORTED_ERROR;
}

#endif
