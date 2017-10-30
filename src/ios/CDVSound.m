/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

@import AVFoundation;
@import Foundation;

#import "CDVSound.h"
#import "CDVFile.h"
#include <math.h>

#define DOCUMENTS_SCHEME_PREFIX @"documents://"
#define HTTP_SCHEME_PREFIX @"http://"
#define HTTPS_SCHEME_PREFIX @"https://"
#define CDVFILE_PREFIX @"cdvfile://"
#define RECORDING_WAV @"wav"

@implementation CDVSound

@synthesize soundCache, avSession, currMediaId, backgroundAudioPlayer;

AVAudioSession* session;
BOOL _isPlaying;

- (void) pluginInitialize {
    [super pluginInitialize];
    [self configureBackgroundAudioPlayer];
    [self configureSession];
    [self observeBackgroundModeLifeCycle];
}

// Maps a url for a resource path for recording
- (NSURL*)urlForRecording:(NSString*)resourcePath
{
    NSURL* resourceURL = nil;
    NSString* filePath = nil;
    NSString* docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];

    // first check for correct extension
    if ([[resourcePath pathExtension] caseInsensitiveCompare:RECORDING_WAV] != NSOrderedSame) {
        resourceURL = nil;
        NSLog(@"Resource for recording must have %@ extension", RECORDING_WAV);
    } else if ([resourcePath hasPrefix:DOCUMENTS_SCHEME_PREFIX]) {
        // try to find Documents:// resources
        filePath = [resourcePath stringByReplacingOccurrencesOfString:DOCUMENTS_SCHEME_PREFIX withString:[NSString stringWithFormat:@"%@/", docsPath]];
        NSLog(@"Will use resource '%@' from the documents folder with path = %@", resourcePath, filePath);
    } else if ([resourcePath hasPrefix:CDVFILE_PREFIX]) {
        CDVFile *filePlugin = [self.commandDelegate getCommandInstance:@"File"];
        CDVFilesystemURL *url = [CDVFilesystemURL fileSystemURLWithString:resourcePath];
        filePath = [filePlugin filesystemPathForURL:url];
        if (filePath == nil) {
            resourceURL = [NSURL URLWithString:resourcePath];
        }
    } else {
        // if resourcePath is not from FileSystem put in tmp dir, else attempt to use provided resource path
        NSString* tmpPath = [NSTemporaryDirectory()stringByStandardizingPath];
        BOOL isTmp = [resourcePath rangeOfString:tmpPath].location != NSNotFound;
        BOOL isDoc = [resourcePath rangeOfString:docsPath].location != NSNotFound;
        if (!isTmp && !isDoc) {
            // put in temp dir
            filePath = [NSString stringWithFormat:@"%@/%@", tmpPath, resourcePath];
        } else {
            filePath = resourcePath;
        }
    }

    if (filePath != nil) {
        // create resourceURL
        resourceURL = [NSURL fileURLWithPath:filePath];
    }
    return resourceURL;
}

// Maps a url for a resource path for playing
// "Naked" resource paths are assumed to be from the www folder as its base
- (NSURL*)urlForPlaying:(NSString*)resourcePath
{
    NSURL* resourceURL = nil;
    NSString* filePath = nil;

    // first try to find HTTP:// or Documents:// resources

    if ([resourcePath hasPrefix:HTTP_SCHEME_PREFIX] || [resourcePath hasPrefix:HTTPS_SCHEME_PREFIX]) {
        // if it is a http url, use it
//        NSLog(@"Will use resource '%@' from the Internet.", resourcePath);
        resourceURL = [NSURL URLWithString:resourcePath];
    } else if ([resourcePath hasPrefix:DOCUMENTS_SCHEME_PREFIX]) {
        NSString* docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        filePath = [resourcePath stringByReplacingOccurrencesOfString:DOCUMENTS_SCHEME_PREFIX withString:[NSString stringWithFormat:@"%@/", docsPath]];
        NSLog(@"Will use resource '%@' from the documents folder with path = %@", resourcePath, filePath);
    } else if ([resourcePath hasPrefix:CDVFILE_PREFIX]) {
        CDVFile *filePlugin = [self.commandDelegate getCommandInstance:@"File"];
        CDVFilesystemURL *url = [CDVFilesystemURL fileSystemURLWithString:resourcePath];
        filePath = [filePlugin filesystemPathForURL:url];
        if (filePath == nil) {
            resourceURL = [NSURL URLWithString:resourcePath];
        }
    } else {
        // attempt to find file path in www directory or LocalFileSystem.TEMPORARY directory
        filePath = [self.commandDelegate pathForResource:resourcePath];
        if (filePath == nil) {
            // see if this exists in the documents/temp directory from a previous recording
            NSString* testPath = [NSString stringWithFormat:@"%@/%@", [NSTemporaryDirectory()stringByStandardizingPath], resourcePath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:testPath]) {
                // inefficient as existence will be checked again below but only way to determine if file exists from previous recording
                filePath = testPath;
                NSLog(@"Will attempt to use file resource from LocalFileSystem.TEMPORARY directory");
            } else {
                // attempt to use path provided
                filePath = resourcePath;
                NSLog(@"Will attempt to use file resource '%@'", filePath);
            }
        } else {
            NSLog(@"Found resource '%@' in the web folder.", filePath);
        }
    }
    // if the resourcePath resolved to a file path, check that file exists
    if (filePath != nil) {
        // create resourceURL
        resourceURL = [NSURL fileURLWithPath:filePath];
        // try to access file
        NSFileManager* fMgr = [NSFileManager defaultManager];
        if (![fMgr fileExistsAtPath:filePath]) {
            resourceURL = nil;
            NSLog(@"Unknown resource '%@'", resourcePath);
        }
    }

    return resourceURL;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile*)audioFileForResource:(NSString*)resourcePath withId:(NSString*)mediaId doValidation:(BOOL)bValidate forRecording:(BOOL)bRecord suppressValidationErrors:(BOOL)bSuppress
{
    BOOL bError = NO;
    CDVMediaError errcode = MEDIA_ERR_NONE_SUPPORTED;
    NSString* errMsg = @"";
    NSString* jsString = nil;
    CDVAudioFile* audioFile = nil;
    NSURL* resourceURL = nil;

    if ([self soundCache] == nil) {
        [self setSoundCache:[NSMutableDictionary dictionaryWithCapacity:1]];
    } else {
        audioFile = [[self soundCache] objectForKey:mediaId];
    }
    if (audioFile == nil) {
        // validate resourcePath and create
        if ((resourcePath == nil) || ![resourcePath isKindOfClass:[NSString class]] || [resourcePath isEqualToString:@""]) {
            bError = YES;
            errcode = MEDIA_ERR_ABORTED;
            errMsg = @"invalid media src argument";
        } else {
            audioFile = [[CDVAudioFile alloc] init];
            audioFile.resourcePath = resourcePath;
            audioFile.resourceURL = nil;  // validate resourceURL when actually play or record
            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }
    if (bValidate && (audioFile.resourceURL == nil)) {
        if (bRecord) {
            resourceURL = [self urlForRecording:resourcePath];
        } else {
            resourceURL = [self urlForPlaying:resourcePath];
        }
        if ((resourceURL == nil) && !bSuppress) {
            bError = YES;
            errcode = MEDIA_ERR_ABORTED;
            errMsg = [NSString stringWithFormat:@"Cannot use audio file from resource '%@'", resourcePath];
        } else {
            audioFile.resourceURL = resourceURL;
        }
    }

    if (bError) {
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:errcode message:errMsg]];
        [self.commandDelegate evalJs:jsString];
    }

    return audioFile;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile*)audioFileForResource:(NSString*)resourcePath withId:(NSString*)mediaId doValidation:(BOOL)bValidate forRecording:(BOOL)bRecord
{
    return [self audioFileForResource:resourcePath withId:mediaId doValidation:bValidate forRecording:bRecord suppressValidationErrors:NO];
}

// returns whether or not audioSession is available - creates it if necessary
- (BOOL)hasAudioSession
{
    BOOL bSession = NO;

//    if (!self.avSession) {
//        NSError* error = nil;
//
//        self.avSession = [AVAudioSession sharedInstance];
//        if (error) {
//            // is not fatal if can't get AVAudioSession , just log the error
//            NSLog(@"error creating audio session: %@", [[error userInfo] description]);
//            self.avSession = nil;
//            bSession = NO;
//        }
//    }
    return bSession;
}

// helper function to create a error object string
- (NSString*)createMediaErrorWithCode:(CDVMediaError)code message:(NSString*)message
{
    NSMutableDictionary* errorDict = [NSMutableDictionary dictionaryWithCapacity:2];

    [errorDict setObject:[NSNumber numberWithUnsignedInteger:code] forKey:@"code"];
    [errorDict setObject:message ? message:@"" forKey:@"message"];

    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:errorDict options:0 error:nil];
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (void)create:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    NSString* resourcePath = [command argumentAtIndex:1];

    CDVAudioFile* audioFile = [self audioFileForResource:resourcePath withId:mediaId doValidation:YES forRecording:NO suppressValidationErrors:YES];

    if (audioFile == nil) {
        NSString* errorMessage = [NSString stringWithFormat:@"Failed to initialize Media file with path %@", resourcePath];
        NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMessage]];
        [self.commandDelegate evalJs:jsString];
    } else {
        NSURL* resourceUrl = audioFile.resourceURL;

        if (![resourceUrl isFileURL] && ![resourcePath hasPrefix:CDVFILE_PREFIX]) {
            // First create an AVPlayerItem
            AVPlayerItem* playerItem = [AVPlayerItem playerItemWithURL:resourceUrl];

            // Subscribe to the AVPlayerItem's DidPlayToEndTime notification.
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidFinishPlaying:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];

            // Subscribe to the AVPlayerItem's PlaybackStalledNotification notification.
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemStalledPlaying:) name:AVPlayerItemPlaybackStalledNotification object:playerItem];
            
            // Subscribe to the AVPlayerItem's other notifications
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemLogEntryNotification:) name:AVPlayerItemNewAccessLogEntryNotification object:playerItem];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemLogEntryNotification:) name:AVPlayerItemNewErrorLogEntryNotification object:playerItem];
            
            
            // Unsubscribe to current AVPlayerItem's status if there is one
            if (avPlayer != nil) {
                if (avPlayer.currentItem != nil)
                    [avPlayer.currentItem removeObserver:self forKeyPath:@"status" context:nil];
            }
            
            // Subscribe to the AVPlayerItem's status
            [playerItem addObserver:self
                         forKeyPath:@"status"
                            options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                            context:nil];

            // Pass the AVPlayerItem to a new player
            if (avPlayer == nil) {
                avPlayer = [[CDVAudioPlayer alloc] initWithPlayerItem:playerItem];
                [self sendEventToApp:@"initializeaudioplayer"];
            } else {
                [avPlayer replaceCurrentItemWithPlayerItem:playerItem];
                [self sendEventToApp:@"updatesongonaudioplayer"];
            }

            //avPlayer = [[AVPlayer alloc] initWithURL:resourceUrl];
        }

        self.currMediaId = mediaId;

        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        
//        NSLog(@"%@",resourceURL);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"status"]) {
        AVPlayerItemStatus status = AVPlayerItemStatusUnknown;
        NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
        if ([statusNumber isKindOfClass:[NSNumber class]]) {
            status = statusNumber.integerValue;
        }
        // Switch over the status
        switch (status) {
            case AVPlayerItemStatusReadyToPlay:
//                NSLog(@"[CDVSoundFork] Item is ready to play");
                [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:@"CDVSoundObjectAudioReadyToPlay" object:nil]];
                [self sendEventToApp:@"audiostatusreadytoplay"];
                if (_isPlaying) {
                    [avPlayer play];
                }
                break;
            case AVPlayerItemStatusFailed:
                [self sendEventToApp:@"audiostatusfailed"];
                NSLog(@"[CDVSoundFork] Item failed!");
                break;
            case AVPlayerItemStatusUnknown:
                NSLog(@"[CDVSoundFork] Item unknownn or not  ready to play ");
                [self sendEventToApp:@"audiostatusnknown"];
                break;
        }
    }
}

- (void)setVolume:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)
    NSString* mediaId = [command argumentAtIndex:0];
    NSNumber* volume = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];

    if ([self soundCache] != nil) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        if (audioFile != nil) {
            audioFile.volume = volume;
            if (audioFile.player) {
                audioFile.player.volume = [volume floatValue];
            }
            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }

    // don't care for any callbacks
}

- (void)setRate:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)
    NSString* mediaId = [command argumentAtIndex:0];
    NSNumber* rate = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];

    if ([self soundCache] != nil) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        if (audioFile != nil) {
            audioFile.rate = rate;
            if (audioFile.player) {
//                audioFile.player.enableRate = YES;
//                audioFile.player.rate = [rate floatValue];
            }
            if (avPlayer.currentItem && avPlayer.currentItem.asset){
                float customRate = [rate floatValue];
                [avPlayer setRate:customRate];
            }

            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }

    // don't care for any callbacks
}

- (float)getDurationOf:(AVPlayerItem*) playerItem {
    return (playerItem.duration.value / playerItem.duration.timescale);
}

- (void)startPlayingAudio:(CDVInvokedUrlCommand*)command
{
    _isPlaying = YES;
    [self.commandDelegate runInBackground:^{

    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)
    NSString* mediaId = [command argumentAtIndex:0];
    NSString* resourcePath = [command argumentAtIndex:1];
    NSDictionary* options = [command argumentAtIndex:2 withDefault:nil];

    BOOL bError = NO;
    NSString* jsString = nil;

    CDVAudioFile* audioFile = [self audioFileForResource:resourcePath withId:mediaId doValidation:YES forRecording:NO];
        

    if ((audioFile != nil) && (audioFile.resourceURL != nil)) {
        if (audioFile.player == nil) {
            bError = [self prepareToPlay:audioFile withId:mediaId];
        }
        if (!bError) {
            //self.currMediaId = audioFile.player.mediaId;
            self.currMediaId = mediaId;

            // audioFile.player != nil  or player was successfully created
            // get the audioSession and set the category to allow Playing when device is locked or ring/silent switch engaged
            
            [self keepAwake];
            if (!bError) {
//                NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
                double duration = 0;
                if (avPlayer.currentItem && avPlayer.currentItem.asset) {
                    CMTime time = avPlayer.currentItem.asset.duration;
                    duration = CMTimeGetSeconds(time);
                    if (isnan(duration)) {
                        NSLog(@"Duration is infifnite, setting it to -1");
                        duration = -1;
                    }

//                    NSLog(@"Playing stream with AVPlayer & default rate");
                    if ([avPlayer respondsToSelector:NSSelectorFromString(@"playImmediatelyAtRate:")]) {
                        [avPlayer playImmediatelyAtRate:1.0f];
                    } else {
                        [avPlayer play];
                    }
                    [self sendEventToApp:@"audiostarted1"];

                } else {

                    NSNumber* loopOption = [options objectForKey:@"numberOfLoops"];
                    NSInteger numberOfLoops = 0;
                    if (loopOption != nil) {
                        numberOfLoops = [loopOption intValue] - 1;
                    }
                    if (audioFile.player.rate == 1.0f) {
                        [audioFile.player pause];
                        [audioFile.player seekToTime:CMTimeMake(0,0)];
                    }
                    if (audioFile.volume != nil) {
                        audioFile.player.volume = [audioFile.volume floatValue];
                    }

                    if ([avPlayer respondsToSelector:NSSelectorFromString(@"playImmediatelyAtRate:")]) {
                        [avPlayer playImmediatelyAtRate:1.0f];
                    } else {
                        [avPlayer play];
                    }

                    [self sendEventToApp:@"audiostarted2"];
                    duration = round([self getDurationOf:audioFile.player.currentItem] * 1000) / 1000;
                }

                jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);\n%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_DURATION, duration, @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_RUNNING];
                [self.commandDelegate evalJs:jsString];
            }
        }
        if (bError) {
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_NONE_SUPPORTED message:nil]];
            [self.commandDelegate evalJs:jsString];
        }
    }
    // else audioFile was nil - error already returned from audioFile for resource
    return;

    }];
}

- (BOOL)prepareToPlay:(CDVAudioFile*)audioFile withId:(NSString*)mediaId
{
    
    BOOL bError = NO;
    NSError* __autoreleasing playerError = nil;

    // create the player
//    NSURL* resourceURL = audioFile.resourceURL;

    if (playerError != nil) {
        NSLog(@"Failed to initialize AVAudioPlayer: %@\n", [playerError localizedDescription]);
        [self sendEventToApp:@"preparetoplayerror"];
        audioFile.player = nil;
//        if (self.avSession) {
//            [self.avSession setActive:NO error:nil];
//        }
        bError = YES;
    } else {
        audioFile.player.mediaId = mediaId;
//        audioFile.player.delegate = self;
        if (avPlayer == nil)
            bError = audioFile.player.rate == 0;
        if (bError) {
            [self sendEventToApp:@"preparetoplayerror"];
        } else {
            [self sendEventToApp:@"preparetoplay"];
        }
    }
    
    return bError;
}

- (void)stopPlayingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    NSString* jsString = nil;
    _isPlaying = NO;

    if ((audioFile != nil) && (audioFile.player != nil)) {
        NSLog(@"Stopped playing audio sample '%@'", audioFile.resourcePath);
        [audioFile.player pause];
        [audioFile.player seekToTime:CMTimeMake(0,0)];
        [self sendEventToApp:@"audiostop"];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
    }
    // seek to start and pause
    if (avPlayer.currentItem && avPlayer.currentItem.asset) {
        BOOL isReadyToSeek = (avPlayer.status == AVPlayerStatusReadyToPlay) && (avPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay);
        if (isReadyToSeek) {
            [avPlayer seekToTime: kCMTimeZero
                 toleranceBefore: kCMTimeZero
                  toleranceAfter: kCMTimeZero
               completionHandler: ^(BOOL finished){
                   if (finished) [avPlayer pause];
               }];
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
        } else {
            // cannot seek, wrong state
            CDVMediaError errcode = MEDIA_ERR_NONE_ACTIVE;
            NSString* errMsg = @"Cannot service stop request until the avPlayer is in 'AVPlayerStatusReadyToPlay' state.";
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:errcode message:errMsg]];
        }
    }
    [self stopKeepingAwake];
    // ignore if no media playing
    if (jsString) {
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)pausePlayingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    NSString* jsString = nil;
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    _isPlaying = NO;
    
//    [self stopKeepingAwake];

    if ((audioFile != nil) && ((audioFile.player != nil) || (avPlayer != nil))) {
//        NSLog(@"Paused playing audio sample '%@'", audioFile.resourcePath);
        if (audioFile.player != nil) {
            [audioFile.player pause];
        } else if (avPlayer != nil) {
            [avPlayer pause];
        }

        [self sendEventToApp:@"audiopause"];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_PAUSED];
    }
    // ignore if no media playing

    if (jsString) {
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)seekToAudio:(CDVInvokedUrlCommand*)command
{
    // args:
    // 0 = Media id
    // 1 = seek to location in milliseconds

    NSString* mediaId = [command argumentAtIndex:0];

    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    double position = [[command argumentAtIndex:1] doubleValue];
    double posInSeconds = position / 1000;
    NSString* jsString;

    if ((audioFile != nil) && (audioFile.player != nil)) {

        if (posInSeconds >= [self getDurationOf:audioFile.player.currentItem]) {
            // The seek is past the end of file.  Stop media and reset to beginning instead of seeking past the end.
            [audioFile.player pause];
            [audioFile.player seekToTime:CMTimeMake(0,0)];
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);\n%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_POSITION, 0.0, @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
            // NSLog(@"seekToEndJsString=%@",jsString);
        } else {
//            audioFile.player.currentTime = posInSeconds;
            [audioFile.player seekToTime:CMTimeMake(posInSeconds * 10000, 10000)];
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%f);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_POSITION, posInSeconds];
            // NSLog(@"seekJsString=%@",jsString);
        }

    } else if (avPlayer != nil && avPlayer.currentItem != nil) {
        int32_t timeScale = avPlayer.currentItem.asset.duration.timescale;
        CMTime timeToSeek = CMTimeMakeWithSeconds(posInSeconds, timeScale);

        BOOL isPlaying = (avPlayer.rate > 0 && !avPlayer.error);
        BOOL isReadyToSeek = (avPlayer.status == AVPlayerStatusReadyToPlay) && (avPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay);

        // CB-10535:
        // When dealing with remote files, we can get into a situation where we start playing before AVPlayer has had the time to buffer the file to be played.
        // To avoid the app crashing in such a situation, we only seek if both the player and the player item are ready to play. If not ready, we send an error back to JS land.
        if(isReadyToSeek) {
            [avPlayer seekToTime: timeToSeek
                 toleranceBefore: kCMTimeZero
                  toleranceAfter: kCMTimeZero
               completionHandler: ^(BOOL finished) {
                   if (isPlaying) [avPlayer play];
               }];
        } else {
            CDVMediaError errcode = MEDIA_ERR_ABORTED;
            NSString* errMsg = @"AVPlayerItem cannot service a seek request with a completion handler until its status is AVPlayerItemStatusReadyToPlay.";
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:errcode message:errMsg]];
        }
    }

    [self.commandDelegate evalJs:jsString];
}


- (void)release:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    //NSString* mediaId = self.currMediaId;

    if (mediaId != nil) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];

        if (audioFile != nil) {
            if (audioFile.player && [audioFile.player rate] != 0) {
                [audioFile.player pause];
            }
            if (audioFile.recorder && [audioFile.recorder isRecording]) {
                [audioFile.recorder stop];
            }
            if (avPlayer != nil) {
                [avPlayer pause];
                avPlayer = nil;
            }
//            if (self.avSession) {
//                [self.avSession setActive:NO error:nil];
//                self.avSession = nil;
//            }
            [[self soundCache] removeObjectForKey:mediaId];
            NSLog(@"Media with id %@ released", mediaId);
            [self sendEventToApp:@"audiorelease"];
        }
    }
}

- (void)getCurrentPositionAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSString* mediaId = [command argumentAtIndex:0];

#pragma unused(mediaId)
//    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    double position = -1;

    if (avPlayer) {
       CMTime time = [avPlayer currentTime];
       position = CMTimeGetSeconds(time);
        if (isnan(position)) {
//            NSLog(@"Couldn't get position - position was nan.");
            position = 0.0f;
        }
    }

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:position];

    NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_POSITION, position];
    [self.commandDelegate evalJs:jsString];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)startRecordingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)

    NSString* mediaId = [command argumentAtIndex:0];
    CDVAudioFile* audioFile = [self audioFileForResource:[command argumentAtIndex:1] withId:mediaId doValidation:YES forRecording:YES];
    __block NSString* jsString = nil;
    __block NSString* errorMsg = @"";

    if ((audioFile != nil) && (audioFile.resourceURL != nil)) {

        __weak CDVSound* weakSelf = self;

        void (^startRecording)(void) = ^{
            NSError* __autoreleasing error = nil;

            if (audioFile.recorder != nil) {
                [audioFile.recorder stop];
                audioFile.recorder = nil;
            }
            // get the audioSession and set the category to allow recording when device is locked or ring/silent switch engaged
            if ([weakSelf hasAudioSession]) {
                if (![weakSelf.avSession.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
                    [weakSelf.avSession setCategory:AVAudioSessionCategoryRecord error:nil];
                }

                if (![weakSelf.avSession setActive:YES error:&error]) {
                    // other audio with higher priority that does not allow mixing could cause this to fail
                    errorMsg = [NSString stringWithFormat:@"Unable to record audio: %@", [error localizedFailureReason]];
                    // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, MEDIA_ERR_ABORTED];
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [weakSelf createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMsg]];
                    [weakSelf.commandDelegate evalJs:jsString];
                    return;
                }
            }

            // create a new recorder for each start record
            NSDictionary *audioSettings = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                                             AVSampleRateKey: @(44100),
                                             AVNumberOfChannelsKey: @(1),
                                             AVEncoderAudioQualityKey: @(AVAudioQualityMedium)
                                             };
            audioFile.recorder = [[CDVAudioRecorder alloc] initWithURL:audioFile.resourceURL settings:nil error:&error];

            bool recordingSuccess = NO;
            if (error == nil) {
                audioFile.recorder.delegate = weakSelf;
                audioFile.recorder.mediaId = mediaId;
                audioFile.recorder.meteringEnabled = YES;
                recordingSuccess = [audioFile.recorder record];
                if (recordingSuccess) {
                    NSLog(@"Started recording audio sample '%@'", audioFile.resourcePath);
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_RUNNING];
                    [weakSelf.commandDelegate evalJs:jsString];
                }
            }

            if ((error != nil) || (recordingSuccess == NO)) {
                if (error != nil) {
                    errorMsg = [NSString stringWithFormat:@"Failed to initialize AVAudioRecorder: %@\n", [error localizedFailureReason]];
                } else {
                    errorMsg = @"Failed to start recording using AVAudioRecorder";
                }
                audioFile.recorder = nil;
                if (weakSelf.avSession) {
                    [weakSelf.avSession setActive:NO error:nil];
                }
                jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [weakSelf createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMsg]];
                [weakSelf.commandDelegate evalJs:jsString];
            }
        };

        SEL rrpSel = NSSelectorFromString(@"requestRecordPermission:");
        if ([self hasAudioSession] && [self.avSession respondsToSelector:rrpSel])
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.avSession performSelector:rrpSel withObject:^(BOOL granted){
                if (granted) {
                    startRecording();
                } else {
                    NSString* msg = @"Error creating audio session, microphone permission denied.";
                    NSLog(@"%@", msg);
                    audioFile.recorder = nil;
                    if (weakSelf.avSession) {
                        [weakSelf.avSession setActive:NO error:nil];
                    }
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:msg]];
                    [weakSelf.commandDelegate evalJs:jsString];
                }
            }];
#pragma clang diagnostic pop
        } else {
            startRecording();
        }

    } else {
        // file did not validate
        NSString* errorMsg = [NSString stringWithFormat:@"Could not record audio at '%@'", audioFile.resourcePath];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMsg]];
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)stopRecordingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];

    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    NSString* jsString = nil;

    if ((audioFile != nil) && (audioFile.recorder != nil)) {
        NSLog(@"Stopped recording audio sample '%@'", audioFile.resourcePath);
        [audioFile.recorder stop];
        // no callback - that will happen in audioRecorderDidFinishRecording
    }
    // ignore if no media recording
    if (jsString) {
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder*)recorder successfully:(BOOL)flag
{
    CDVAudioRecorder* aRecorder = (CDVAudioRecorder*)recorder;
    NSString* mediaId = aRecorder.mediaId;
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    NSString* jsString = nil;

    if (audioFile != nil) {
        NSLog(@"Finished recording audio sample '%@'", audioFile.resourcePath);
    }
    if (flag) {
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
    } else {
        // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, MEDIA_ERR_DECODE];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
    }
    if (self.avSession) {
        [self.avSession setActive:NO error:nil];
    }
    [self.commandDelegate evalJs:jsString];
}

//- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer*)player successfully:(BOOL)flag
//{
//    //commented as unused
//    CDVAudioPlayer* aPlayer = (CDVAudioPlayer*)player;
//    NSString* mediaId = aPlayer.mediaId;
//    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
//    NSString* jsString = nil;
//
//    if (audioFile != nil) {
//        NSLog(@"Finished playing audio sample '%@'", audioFile.resourcePath);
//    }
//    if (flag) {
////        audioFile.player.currentTime = 0;
//        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
//    } else {
//        // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, MEDIA_ERR_DECODE];
//        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
//    }
//    if (self.avSession) {
//        [self.avSession setActive:NO error:nil];
//    }
//    [self.commandDelegate evalJs:jsString];
//}

-(void)itemDidFinishPlaying:(NSNotification *) notification {
    // Will be called when AVPlayer finishes playing playerItem
    NSString* mediaId = self.currMediaId;
    NSString* jsString = nil;
    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];

    [avPlayer.currentItem removeObserver:self forKeyPath:@"status" context:nil];

//    if (self.avSession) {
//        [self.avSession setActive:NO error:nil];
//    }
    NSLog(@"Item did finish playing");
    [self.commandDelegate evalJs:jsString];

}

-(void)itemStalledPlaying:(NSNotification *) notification {
    // Will be called when playback stalls due to buffer empty
    NSLog(@"Stalled playback");
}
-(void)itemLogEntryNotification:(NSNotification *) notification {
    AVPlayerItemAccessLog* acc = avPlayer.currentItem.accessLog;
    AVPlayerItemErrorLog* err = avPlayer.currentItem.errorLog;
}

- (void)onMemoryWarning
{
    [[self soundCache] removeAllObjects];
    [self setSoundCache:nil];
    [self setAvSession:nil];
    session = nil;

    [super onMemoryWarning];
}

- (void)dealloc
{
    [[self soundCache] removeAllObjects];
}
- (void) sendEventToApp:(NSString*)message {
    // [self.commandDelegate evalJs:[NSString stringWithFormat:@"setTimeout(function(){window.ev = new Event('%@');document.dispatchEvent(ev);},0);",message]];
}

- (void)onReset
{
    for (CDVAudioFile* audioFile in [[self soundCache] allValues]) {
        if (audioFile != nil) {
            if (audioFile.player != nil) {
                [audioFile.player pause];
                [audioFile.player seekToTime:CMTimeMake(0,0)];
            }
            if (audioFile.recorder != nil) {
                [audioFile.recorder stop];
            }
        }
    }

    [[self soundCache] removeAllObjects];
}

- (void)getCurrentAmplitudeAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSString* mediaId = [command argumentAtIndex:0];

#pragma unused(mediaId)
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    float amplitude = 0; // The linear 0.0 .. 1.0 value

    if ((audioFile != nil) && (audioFile.recorder != nil) && [audioFile.recorder isRecording]) {
        [audioFile.recorder updateMeters];
        float minDecibels = -60.0f; // Or use -60dB, which I measured in a silent room.
        float decibels    = [audioFile.recorder averagePowerForChannel:0];
        if (decibels < minDecibels) {
            amplitude = 0.0f;
        } else if (decibels >= 0.0f) {
            amplitude = 1.0f;
        } else {
            float root            = 2.0f;
            float minAmp          = powf(10.0f, 0.05f * minDecibels);
            float inverseAmpRange = 1.0f / (1.0f - minAmp);
            float amp             = powf(10.0f, 0.05f * decibels);
            float adjAmp          = (amp - minAmp) * inverseAmpRange;
            amplitude = powf(adjAmp, 1.0f / root);
        }
    }
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:amplitude];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
 }

 - (void)resumeRecordingAudio:(CDVInvokedUrlCommand*)command
  {
     NSString* mediaId = [command argumentAtIndex:0];

     CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
     NSString* jsString = nil;

     if ((audioFile != nil) && (audioFile.recorder != nil)) {
         NSLog(@"Resumed recording audio sample '%@'", audioFile.resourcePath);
         [audioFile.recorder record];
         // no callback - that will happen in audioRecorderDidFinishRecording
         jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_RUNNING];
     }

    // ignore if no media recording
    if (jsString) {
        [self.commandDelegate evalJs:jsString];
    }
}

 - (void)pauseRecordingAudio:(CDVInvokedUrlCommand*)command
  {
     NSString* mediaId = [command argumentAtIndex:0];

     CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
     NSString* jsString = nil;

     if ((audioFile != nil) && (audioFile.recorder != nil)) {
         NSLog(@"Pause ad recording audio sample '%@'", audioFile.resourcePath);
         [audioFile.recorder pause];
         // no callback - that will happen in audioRecorderDidFinishRecording
         // no callback - that will happen in audioRecorderDidFinishRecording
         jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cdvsound-ios-fork.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_PAUSED];
     }

      // ignore if no media recording
      if (jsString) {
          [self.commandDelegate evalJs:jsString];
      }
      
 }

#pragma mark -
#pragma mark Background Mode®

- (void) observeBackgroundModeLifeCycle
{
    NSNotificationCenter* listener = [NSNotificationCenter defaultCenter];
    
    [listener addObserver:self
                 selector:@selector(keepAwake)
                     name:UIApplicationDidEnterBackgroundNotification
                   object:nil];

//    [listener addObserver:self
//                 selector:@selector(stopKeepingAwake)
//                     name:UIApplicationWillEnterForegroundNotification
//                   object:nil];
}

-(void)configureSession{
    NSError *setCategoryError = nil;
    session = [AVAudioSession sharedInstance];
    BOOL success = [session setCategory:AVAudioSessionCategoryPlayback
//                            withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                  error:&setCategoryError];
    if (!success) {
        NSLog(@"[CDVSoundFork] session cannot be set: %@",setCategoryError.description);
    }
}
-(void)configureBackgroundAudioPlayer {
    NSString* path = [[NSBundle mainBundle] pathForResource:@"appbeep"
                                                     ofType:@"wav"];
    
    NSURL* url = [NSURL fileURLWithPath:path];
    
    
    backgroundAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url
                                                                   error:NULL];
    // Silent
    backgroundAudioPlayer.volume = 0;
    // Infinite
    backgroundAudioPlayer.numberOfLoops = -1;
}

/**
 * Keep the app awake.
 */
- (void) keepAwake {
    [session setActive:YES error:nil];
    [self sendEventToApp:@"keepawakestart"];
//    [backgroundAudioPlayer play];
    
}

/**
 * Let the app going to sleep.
 */
- (void) stopKeepingAwake {
    if (TARGET_IPHONE_SIMULATOR) {
        NSLog(@"BackgroundMode: On simulator apps never pause in background!");
    }
    
//    [backgroundAudioPlayer pause];
//    [session setActive:NO error:nil];
//    float rate = avPlayer.rate;
//    if (rate == 0) {
//        [session setActive:NO error:nil];
//    }
    [self sendEventToApp:@"keepawakestop"];
}
- (void) handleAudioSessionInterruption:(NSNotification*)notification{
    NSNumber* reason = [notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey];
    if ([reason intValue] == AVAudioSessionInterruptionTypeBegan) {
        [self keepAwake];
    } else {
        [self stopKeepingAwake];
    }
}

@end

@implementation CDVAudioFile

@synthesize resourcePath;
@synthesize resourceURL;
@synthesize player, volume, rate;
@synthesize recorder;

@end
@implementation CDVAudioPlayer
@synthesize mediaId;

@end

@implementation CDVAudioRecorder
@synthesize mediaId;

@end
