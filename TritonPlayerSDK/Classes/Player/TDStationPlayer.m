//
//  TDStationPlayer.m
//  TritonPlayerSDK
//
//  Created by Carlos Pereira on 2015-03-12.
//  Copyright (c) 2015 Triton Digital. All rights reserved.
//

#import "TDStationPlayer.h"
#import "TDStreamPlayer.h"
#import "Provisioning.h"
#import "TritonPlayer.h"
#import "ProvisioningConstants.h"
#import "Server.h"
#import "TDMediaPlayer.h"
#import "MetadataConfiguration.h"
#import "TritonPlayerConstants.h"
#import "Logs.h"
#import "TDSBMPlayer.h"

#define kMaxBackoffRetryTimeInSeconds 60.0f

NSString *const SettingsStationPlayerUserAgentKey = @"StationPlayerUserAgent";
NSString *const SettingsStationPlayerMountKey = @"StationPlayerMount";
NSString *const SettingsStationPlayerBroadcasterKey = @"StationPlayerBroadcaster";
NSString *const SettingsStationPlayerForceDisableHLSkey = @"StationPlayerForceDisableHLS"; 

@interface TDStationPlayer ()<TDMediaPlaybackDelegate>

@property SInt32 lowDelay;
@property SInt32 bitrate;

@property (strong, nonatomic) Provisioning *provisioning;
@property (strong, nonatomic) TDStreamPlayer *streamPlayer;
@property (strong, nonatomic) TritonPlayer *tritonPlayer;


@property (copy, nonatomic) NSString *mount;
@property (copy, nonatomic) NSString *userAgent;
@property (copy, nonatomic) NSString *broadcaster;
@property (copy, nonatomic) NSDictionary *extraQueryParameters;
@property (copy, nonatomic) NSArray *tTags;
@property (copy, nonatomic) NSString *playerServicesRegion;

// The stream token
@property (copy, nonatomic) NSString *token;

@property (strong, nonatomic) NSMutableDictionary *settings;

@property(strong, nonatomic) NSString* sbmId;

//backoff
@property float backoffMaxRetry;
@property float backoffRetry;


@property (copy, nonatomic) NSString *referrerURL;
@property (assign, nonatomic) BOOL forceDisableHLS;

@property (assign, nonatomic) TDPlayerState state;
@end

@implementation TDStationPlayer

@synthesize currentPlaybackTime;
@synthesize playbackDuration;
@synthesize delegate;
@synthesize error = _error;

-(instancetype)init {
    return [self initWithSettings:nil];
}

-(instancetype)initWithSettings:(NSDictionary *)settings {
    self = [super init];
    if (self) {
        [self updateSettings:settings];
        
        self.streamPlayer = [[TDStreamPlayer alloc] init];
        self.streamPlayer.delegate = self;
        
        self.state = kTDPlayerStateStopped;
       
    }
    return self;
}

-(void)updateSettings:(NSDictionary *)settings {
    if (settings)
    {
       self.userAgent = settings[SettingsStationPlayerUserAgentKey];
       self.mount = settings[SettingsStationPlayerMountKey];
       self.broadcaster = settings[SettingsStationPlayerBroadcasterKey];
       self.extraQueryParameters = settings[SettingsStreamParamsExtraKey];
       self.tTags = settings[SettingsTtagKey];
       self.lowDelay = [settings[SettingsLowDelayKey] intValue];
       self.forceDisableHLS = [settings[SettingsStationPlayerForceDisableHLSkey] boolValue];
       self.token           = settings[StreamParamExtraAuthorizationTokenKey];
       self.playerServicesRegion = settings[SettingsPlayerServicesRegion];
    }
}

-(void)play {
    if ([self canChangeStateWithAction:kTDPlayerActionPlay]) {
				//reset backoff
				self.backoffRetry = 0.0f;
				
        [self updateStateMachineForAction:kTDPlayerActionPlay];
        [self startProvisioning];
    }
    
    PLAYER_LOG(@"StationPlayer: Mount to Play : %@", self.mount);
}

-(void)stop {
        [self updateStateMachineForAction:kTDPlayerActionStop];
        [self.streamPlayer stop];
    if(self.tritonPlayer != nil) {
       [self.tritonPlayer stop];
    }
    
}

-(void)pause {
    [self stop];
}

-(void)seekToTimeInterval:(NSTimeInterval)interval {
    if ([self.streamPlayer respondsToSelector:@selector(seekToTimeInterval:)]) {
        [self.streamPlayer seekToTimeInterval:interval];
    }
}

-(void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completionHandler {
    if ([self.streamPlayer respondsToSelector:@selector(seekToTime:completionHandler:)]) {
        [self.streamPlayer seekToTime:time completionHandler:completionHandler];
    }
}

-(AudioQueueRef)getAudioQueue {
    if ([self.streamPlayer respondsToSelector:@selector(getAudioQueue)]) {
        return [self.streamPlayer getAudioQueue];
        
    } else {
        return nil;
    }
}

#pragma mark - AudioPlayer

-(void)mute {
    [self stop];
}

-(void)unmute {
    [self play];
}

-(void)setVolume:(float)volume {
    [self.streamPlayer setVolume:volume];
}

-(NSTimeInterval)currentPlaybackTime {
    return [self.streamPlayer currentPlaybackTime];
}

-(NSTimeInterval)playbackDuration {
    return [self.streamPlayer playbackDuration];
}

-(id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime))block {
    return [self.streamPlayer addPeriodicTimeObserverForInterval:interval queue:queue usingBlock:block];
}

-(void)removeTimeObserver:(id)observer {
    [self.streamPlayer removeTimeObserver:observer];
}

#pragma mark - Provisioning




-(void)startProvisioning {
    
    // Repeat the provisioning in case it's geoblocked and there's an alternate mount
		
		// create a new provisioning object
		self.provisioning = nil;
		_provisioning = [[Provisioning alloc] initWithCallsign:self.mount referrerURL:self.referrerURL];
		_provisioning.forceDisableHLS = self.forceDisableHLS;
		_provisioning.userAgent = self.userAgent;
        _provisioning.playerServicesRegion = self.playerServicesRegion;
	 
		[self.provisioning getProvisioning:^(BOOL provOK){
				[self handleProvisioningResponse:provOK];
		}];
		
}


-(void) handleProvisioningResponse:(BOOL) provOK {
		
// Provisioning is ok, take a look at the status code
				if (provOK)
				{
						switch (self.provisioning.statusCode) {
								case kProvisioningStatusCodeOk:
										[self startPlayingStream];
										break;
										
								case kProvisioningStatusCodeGeoblocked:
										// KVO will not be called, since TritonPlayer is not started, so change state manually
										
                                if(self.provisioning.alternateMediaUrl != nil) {
                                    [self startPlayingMediaUrl];
                                    break;
                                }
                                        
										if (self.provisioning.alternateMount != nil) {
												
												
												// Change the mount for the alternate. Add preprod suffix if the original mount was preprod.
												if ([self.mount hasSuffix:@".preprod"]) {
														self.mount = [NSString stringWithFormat:@"%@.preprod", self.provisioning.alternateMount];
												} else {
														self.mount = self.provisioning.alternateMount;
												}
												
												if ([self.delegate respondsToSelector:@selector(mediaPlayer:didReceiveInfo:andExtra:)]) {
														[self.delegate mediaPlayer:self didReceiveInfo:kTDPlayerInfoForwardedToAlternateMount andExtra:@{InfoAlternateMountNameKey : self.mount}];
												}
												
												[self startProvisioning];
												
										} else {
												[self failWithError:TDPlayerMountGeoblockedError andDescription:NSLocalizedString(@"The mount is geo-blocked.", nil)];

										}
										break;
										
								case kProvisioningStatusCodeNotFound:
										[self failWithError:TDPlayerMountNotFoundError andDescription:NSLocalizedString(@"The mount doesn't exist.", nil)];
										
								case kProvisioningStatusCodeNotImplemented:
										[self failWithError:TDPlayerMountNotImplemntedError andDescription:NSLocalizedString(@"The requested version doesn’t exist.", nil)];
										break;
										
								case kProvisioningStatusCodeBadRequest:
										[self failWithError:TDPlayerMountBadRequestError andDescription:NSLocalizedString(@"Bad request. A required parameter is missing or an invalid parameter was sent.", nil)];//
										break;
										
								default:
										[self failWithError:TDPlayerHostNotFoundError andDescription:NSLocalizedString(@"Connection Error. Could not find the host.", nil)];
										break;
						}
						
				}
				else
				{
						// An error occurred and the provisioning didn't work but we are done with it.
						[self startWithNextAvailableServer];
				}
		
}

-(void)startPlayingMediaUrl
{
    self.tritonPlayer = [[TritonPlayer alloc] initWithDelegate:self andSettings:nil];
    [self.tritonPlayer updateSettings:@{SettingsContentURLKey : self.provisioning.alternateMediaUrl}];
    [self.tritonPlayer play];
}

-(void)player:(TritonPlayer *)player didChangeState:(TDPlayerState)state {
    
    if(state == kTDPlayerStateError)
    {
        [self failWithError:TDPlayerHostNotFoundError andDescription:NSLocalizedString(@"Connection Error. Could not find the host.", nil)];
    }
    else
    {
        [self updateStateMachineForAction:kTDPlayerActionJumpToNextState];
    }
    
}

-(void)startPlayingStream {
		
		if( self.streamPlayer == nil ){
				return;
		}
    
    self.sbmId = [TDSBMPlayer generateSBMSessionId];
    
    NSMutableString *connectingToURL = [NSMutableString stringWithFormat:@"%@/%@", self.provisioning.currentServer.url, self.provisioning.mountName];
    
    self.settings = [NSMutableDictionary dictionaryWithCapacity:9];
    
    if ([self.provisioning.mountFormat isEqualToString:kMountFormatFLV]) {
        
        self.settings[SettingsStreamPlayerProfileKey] = @(kTDStreamProfileFLV);
        self.settings[SettingsStreamPlayerUserAgentKey] = self.userAgent;
        self.settings[SettingsStreamPlayerStreamURLKey] = connectingToURL;
        self.settings[SettingsStreamParamsExtraKey] = self.extraQueryParameters;
        self.settings[SettingsTtagKey] = self.tTags;
        self.settings[StreamParamExtraAuthorizationTokenKey] = self.token;
        self.settings[SettingsLowDelayKey] = [NSNumber numberWithInt:self.lowDelay];
        self.settings[SettingsBitrateKey] = self.provisioning.mountBitrate;
        
    } else if ([self.provisioning.mountFormat isEqualToString:kMountFormatHLS]) {
        
        MetadataConfiguration *sbmConfiguration = self.provisioning.sidebandMetadataInfo;
        
        // If SBM is enabled, add mount suffix to the url and create the sbm url.
        if (sbmConfiguration.enabled) {
            NSString *sbmURL = [connectingToURL stringByAppendingString:sbmConfiguration.metadataSuffix];
            self.settings[SettingsStreamPlayerSBMURLKey] = sbmURL;
            
            [connectingToURL appendString:sbmConfiguration.mountSuffix];
        }
        
        self.settings[SettingsStreamPlayerProfileKey] = @(KTDStreamProfileHLS);
        self.settings[SettingsStreamPlayerUserAgentKey] = self.userAgent;
        self.settings[SettingsStreamPlayerStreamURLKey] = connectingToURL;
        self.settings[SettingsStreamParamsExtraKey] = self.extraQueryParameters;
        self.settings[SettingsTtagKey] = self.tTags;
        self.settings[StreamParamExtraAuthorizationTokenKey] = self.token;
        
    }

    [self.streamPlayer updateSettings:self.settings];
    [self.streamPlayer play];
}


//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
// startWithNextAvailableServer
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

-(void)startWithNextAvailableServer{
		
		//send state reconnecting
		[self updateStateMachineForAction:kTDPlayerActionReconnect];
		
    if ([self.provisioning getNextAvailableServer] == TRUE) {
        [self startPlayingStream];
    } else {
				
				//backoff 
				if( self.backoffRetry <= kMaxBackoffRetryTimeInSeconds){
						
						//increment backoff
						float delay = ((float)rand() / RAND_MAX) * 4 +1;
						self.backoffRetry += delay;

						[self performSelector:@selector(startProvisioning) withObject:nil afterDelay:delay];
						
				}else{
						// Unable to find a server to connect. it's probably because we tried all servers without success
						[self failWithError:TDPlayerHostNotFoundError andDescription:NSLocalizedString(@"Connection Error. Could not find the host.", nil)];
						
						//reset backoff retry
						self.backoffRetry = 0;
						
						[self.streamPlayer cancelBackgoundTasks];
				}
				
    }
}

#pragma mark - Error handling

- (void)failWithError:(TDPlayerError) errorCode andDescription:(NSString*) description {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey : description};
    
    NSError *error = [NSError errorWithDomain:TritonPlayerDomain code:errorCode userInfo:userInfo];
    
    self.error = error;
    [self updateStateMachineForAction:kTDPlayerActionError];
}

#pragma mark - TDMediaPlaybackDelegate methods

-(void)mediaPlayer:(id<TDMediaPlayback>)player didReceiveCuepointEvent:(CuePointEvent *)cuePointEvent {
    if ([self.delegate respondsToSelector:@selector(mediaPlayer:didReceiveCuepointEvent:)]) {
        [self.delegate mediaPlayer:self didReceiveCuepointEvent:cuePointEvent];
    }
}


-(void)mediaPlayer:(id<TDMediaPlayback>)player didChangeState:(TDPlayerState)newState {
    switch (newState) {
        case kTDPlayerStateCompleted:
            [self updateStateMachineForAction:kTDPlayerActionJumpToNextState];
            break;
            
        case kTDPlayerStatePlaying:
            [self updateStateMachineForAction:kTDPlayerActionJumpToNextState];
            break;
            
        case kTDPlayerStateError:
            // If the provisioning object is null, it means the stream was playing before the connection failed.
            if (!self.provisioning) {
                [self stop];
                [self play];
                
            } else {
                [self startWithNextAvailableServer];
            }
            break;

        default:
            break;
    }

}

-(void)mediaPlayer:(id<TDMediaPlayback>)player didReceiveInfo:(TDPlayerInfo)info andExtra:(NSDictionary *)extra {
    if (info == kTDPlayerInfoConnectedToStream) {
        // Deallocate provisioning. It's not useful from this point
       // self.provisioning = nil;
        
        // rewind provisioning servers list
        [self.provisioning rewindServerList];
    }
    
    if ([self.delegate respondsToSelector:@selector(mediaPlayer:didReceiveInfo:andExtra:)]) {
				extra = @{@"transport" : [self.settings objectForKey:SettingsStreamPlayerProfileKey]};
				[self.delegate mediaPlayer:self didReceiveInfo:info andExtra:extra];
    }
}

#pragma mark - State machine

-(BOOL)canChangeStateWithAction:(TDPlayerAction) action {
    return [self nextStateForAction:action] != self.state;
}

// Returns the next state for an action. This doesn't change the state.
-(TDPlayerState)nextStateForAction:(TDPlayerAction)action {
    TDPlayerState nextState = self.state;
    
    switch (action) {
        case kTDPlayerActionPlay:
            if (self.state == kTDPlayerStateStopped || self.state == kTDPlayerStateError || self.state == kTDPlayerStateCompleted || self.state == kTDPlayerStatePaused) {
                nextState = kTDPlayerStateConnecting;
                
            }
            break;
            
        case kTDPlayerActionStop:
            if (self.state != kTDPlayerStateStopped) {
                nextState = kTDPlayerStateStopped;
            }
            break;
            
        case kTDPlayerActionJumpToNextState:
            if (self.state == kTDPlayerStateConnecting) {
                nextState = kTDPlayerStatePlaying;
                
            }
            break;
				case kTDPlayerActionReconnect:
						if( self.state == kTDPlayerStatePlaying || self.state == kTDPlayerStateStopped || self.state == kTDPlayerStateError ){
							nextState = kTDPlayerStateConnecting;
						}
						break;
            
        case kTDPlayerActionError:
            if (self.state != kTDPlayerStateError) {
                nextState = kTDPlayerStateError;
                
            }
            break;
            
        case kTDPlayerActionPause:
            if (self.state == kTDPlayerStatePlaying) {
                nextState = kTDPlayerStatePaused;
                
            }
            break;
    }
    
    return nextState;
}

-(void)updateStateMachineForAction:(TDPlayerAction)action {
    
    TDPlayerState nextState = [self nextStateForAction:action];
    
    // If state changed, send the delegate a callback message
    if (self.state != nextState) {
        self.state = nextState;
        
        PLAYER_LOG(@"Changed state to: %@", [TritonPlayer toStringState:self.state]);
        
        // Clear error
        if (self.state != kTDPlayerStateError) {
            self.error = nil;
        }
        
        if ([self.delegate respondsToSelector:@selector(mediaPlayer:didChangeState:)]) {
            [self.delegate mediaPlayer:self didChangeState:self.state];
        }
    }
}

-(NSString*) getCastStreamingUrl
{
    if(self.streamPlayer != nil)
    {
        NSString* s= [self.streamPlayer getStreamingUrl];
        if(s == nil) return nil;
        
        NSURLComponents *components = [NSURLComponents componentsWithString:s];
        NSMutableArray<NSURLQueryItem *> *queryItems = [[NSMutableArray alloc] initWithArray:[components queryItems]];
        
         MetadataConfiguration *sbmConfiguration = self.provisioning.sidebandMetadataInfo;
        
        // If SBM is enabled.
        if (sbmConfiguration!= nil && sbmConfiguration.enabled && self.sbmId) {
            NSURLQueryItem*sbmQ = [[NSURLQueryItem alloc] initWithName:@"sbmid" value:self.sbmId];
            [queryItems addObject:sbmQ];
        }
        
        
        NSMutableString *sc = [NSMutableString stringWithFormat:@"%@/%@_SC", self.provisioning.currentServer.url, self.provisioning.mountName]; //Shoutcast stream url for casting
        NSURLComponents *url = [NSURLComponents componentsWithString:sc];
        
        [url setQueryItems:queryItems];
        return [url string];
    }
    return nil;
}

-(NSString*) getSideBandMetadataUrl
{
    MetadataConfiguration *sbmConfiguration = self.provisioning.sidebandMetadataInfo;
    
    // If SBM is enabled.
    if (sbmConfiguration!= nil && sbmConfiguration.enabled && self.sbmId) {
     NSMutableString *connectingToURL = [NSMutableString stringWithFormat:@"%@/%@", self.provisioning.currentServer.url, self.provisioning.mountName];
      NSString *sbmURL = [connectingToURL stringByAppendingString:sbmConfiguration.metadataSuffix];
      NSURLComponents *components = [NSURLComponents componentsWithString:sbmURL];
        NSString* q = [NSString stringWithFormat:@"sbmid=%@",self.sbmId];
        [components setQuery:q];
        
        return [components string];
    }
    
    return nil;
}

@end
