/********************************************************************************************/
/*     _____                                                                                */
/*    |  _  |___ ___ ___                                                                    */
/*    |     | -_| . |   |                                                                   */
/*    |__|__|___|___|_|_| Digital signal processing / synthesizer                           */
/*    http://www.assertfail.org                                                             */
/*                                                                                          */
/* Copyright (c) 2013, Nicklas Marelius, Bengt Sjolen                                       */
/* All rights reserved.                                                                     */
/*                                                                                          */
/* Redistribution and use in source and binary forms, with or without modification,         */
/* are permitted provided that the following conditions are met:                            */
/*                                                                                          */
/*     1. Redistributions of source code must retain the above copyright notice,            */
/*        this list of conditions and the following disclaimer.                             */
/*                                                                                          */
/*     2. Redistributions in binary form must reproduce the above copyright notice,         */
/*        this list of conditions and the following disclaimer in the documentation         */
/*        and/or other materials provided with the distribution.                            */
/*                                                                                          */
/*     3. Neither the name assertfail.org nor the names of its                              */
/*        contributors may be used to endorse or promote products derived from this         */
/*        software without specific prior written permission.                               */
/*                                                                                          */
/* THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY      */
/* EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF  */
/* MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL   */
/* THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,     */
/* SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT */
/* OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)*/
/* HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    */
/* OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS    */
/* SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.                             */
/*                                                                                          */
/********************************************************************************************/

#if defined(__IOS_REMOTEIO__)

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>


#include "RtAudio.h"

//------------------------------------------------------------------------------------------------------------

int 
ios_device_count() {
  return 2; // remote io
}

RtAudio::DeviceInfo
ios_device_info(int index) {
  
  static RtAudio::DeviceInfo info;

  AVAudioSession *s = AVAudioSession.sharedInstance;

  info.probed = false;

  switch (index) {
   case 0:
     info.name = "DefaultAudioConfiguration";
     info.uid  =  "iOS:remoteIO:default";
     break ;
   case 1:
     info.name = "UserAudioConfiguration";
     info.uid  = "iOS:remoteIO:user";
     break ;
  }
  
  info.outputChannels = s.maximumOutputNumberOfChannels;
  info.inputChannels  = s.maximumInputNumberOfChannels;
  info.duplexChannels = (info.outputChannels + info.inputChannels);
  info.isDefaultOutput = (index==0);
  info.isDefaultInput  = (index==0);
  info.sampleRates.push_back(8192);
  info.sampleRates.push_back(11025);
  info.sampleRates.push_back(22050);
  info.sampleRates.push_back(24000);
  info.sampleRates.push_back(32000);
  info.sampleRates.push_back(44100);
  info.sampleRates.push_back(48000);
  info.nativeFormats = RTAUDIO_FLOAT32;
  return info;

}

bool
ios_init_session(RtAudio::DeviceInfo info) {

  NSError *err=nil;

  AVAudioSession *s = AVAudioSession.sharedInstance;

  NSString *category = (info.inputChannels > 0 ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryPlayback);
  NSString *mode=AVAudioSessionModeDefault;
  int      options=0x0;    

  [s setCategory:category mode:mode options:options error:&err];

  if (err) {
    NSLog(@"ios_helper: unable to set category %@", err.localizedDescription);
    return false;
  }
  
  err=nil;
  [s setActive:YES error:&err];

  if (err) {
    NSLog(@"ios_helper: failed to activate session: %@", err.localizedDescription);
    return false;
  }

  NSLog(@"ios_helper: AVAudioSession activated\n");

  return true;
  
}

bool                
ios_buffer_size(unsigned int *bufferSize, unsigned int *sampleRate) {

  NSError *err = nil;  
  
  AVAudioSession *s = AVAudioSession.sharedInstance;

  if (sampleRate) {
    
    if (![s setPreferredSampleRate:(double)(*sampleRate) error:&err]) {
      NSLog(@"Error setting samplerate %d reason=%@", (*sampleRate), err.localizedDescription);
      return false;
    }

    NSLog(@"ios_helper: samplerate requested %d recieved %f\n", *sampleRate, s.sampleRate);

    // we want to force our choice of rate
    // this will possible cause RIO to do src for us
    // (*sampleRate) = (unsigned int)s.sampleRate; 

  }

  if (bufferSize) {

    NSTimeInterval duration = ((double)(*bufferSize)) / s.preferredSampleRate;

    err=nil;
    
    if (![s setPreferredIOBufferDuration:duration error:&err]) {
      NSLog(@"Error setting iobuffersize %d reason=%@", (*bufferSize), err.localizedDescription);
      return false;
    }

    NSLog(@"ios_helper: io buffer duration: %f (%f frames)\n", s.IOBufferDuration,
          ceil(s.IOBufferDuration * s.sampleRate));
  
    (*bufferSize) = (unsigned int)ceil(s.IOBufferDuration * s.sampleRate);

  }
  
  return true;
}

/*
  kRtAudioPropertySamplerate,
  kRtAudioPropertyBufferSize,
  kRtAudioPropertyDeviceHasChanged,
  kRtAudioPropertyDeviceIsRunning,
  kRtAudioPropertyDeviceIsAlive
*/

@interface EventHandler : NSObject {
    AudioSessionListener *session;
}
-(id)initWithSession:(AudioSessionListener*)session;
@end

@implementation EventHandler

-(id)initWithSession:(AudioSessionListener*)s {
    if (self = [super init]) {
        session = s;
        
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        
        [nc addObserver:self
               selector:@selector(handleRouteChange:)
               name: AVAudioSessionRouteChangeNotification
               object:nil];

        [nc addObserver:self
               selector:@selector(handleInterruption:)
               name:AVAudioSessionInterruptionNotification
               object:nil];
    }
    return self;
}

-(void)dealloc {
    //NSLog(@"AudioSessionListener.EventHandle.disposed");
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc removeObserver:self];
}
-(void)handleRouteChange:(NSNotification*) notification {
  NSDictionary *info = notification.userInfo;
  NSNumber     *reason = info[AVAudioSessionRouteChangeReasonKey];

  switch(reason.intValue) {
   case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
     break;
   case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
     break ;
  }
  session->audioRouteChanged();
}

-(void)handleInterruption:(NSNotification*) notification {
  NSDictionary *info = notification.userInfo;
  NSNumber     *reason = info[AVAudioSessionInterruptionTypeKey];

  switch(reason.intValue) {
   case AVAudioSessionInterruptionTypeBegan:
          session->audioInterruptionBegan();
     break ;
   case AVAudioSessionInterruptionTypeEnded:
          session->audioInterruptionEnded();
     break ;
  }
}

@end


AudioSessionListener::AudioSessionListener() : events(nullptr) {
}

AudioSessionListener::~AudioSessionListener() {
}

void
AudioSessionListener::enableCallbacks() {
    if (events)
        return ;
#if __has_feature(objc_arc)
    events = (__bridge_retained void *)[EventHandler.alloc initWithSession:this];
#else
    events = [EventHandler.alloc initWithSession:this];
#endif
    //NSLog(@"AudioSessionListener.attached");
}

void
AudioSessionListener::disableCallbacks() {
    if (events) {
# if __has_feature(objc_arc)
        id retained = (__bridge_transfer id)events;
        retained = nil; // release
#else
        [(EventHandler*)events release];
#endif
    }
    events = nullptr;
    //NSLog(@"AudioSessionListener.detached");
}

void
AudioSessionListener::audioRouteChanged() {}
void
AudioSessionListener::audioInterruptionBegan() {}
void
AudioSessionListener::audioInterruptionEnded() {}


double
ios_input_latency_seconds() {
  return (double)AVAudioSession.sharedInstance.inputLatency;
}

double
ios_output_latency_seconds() {
  return (double)AVAudioSession.sharedInstance.outputLatency; 
}

#endif
