#import <Foundation/Foundation.h>
#import "MSAITelemetryContext.h"
#import "MSAITelemetryContextPrivate.h"
#import "MSAITelemetryManagerPrivate.h"
#import "MSAIHelper.h"
#import "MSAISessionHelper.h"
#import "MSAISessionHelperPrivate.h"
#import "MSAIReachability.h"
#import "MSAIReachabilityPrivate.h"

NSString *const kMSAITelemetrySessionId = @"MSAITelemetrySessionId";
NSString *const kMSAISessionAcquisitionTime = @"MSAISessionAcquisitionTime";

@implementation MSAITelemetryContext

#pragma mark - Initialisation

- (instancetype)initWithAppContext:(MSAIContext *)appContext
                      endpointPath:(NSString *)endpointPath
                    firstSessionId:(NSString *)sessionId{
  
  if ((self = [self init])) {
    
    MSAIDevice *deviceContext = [MSAIDevice new];
    deviceContext.model = appContext.deviceModel;
    deviceContext.type = appContext.deviceType;
    deviceContext.osVersion = appContext.osVersion;
    deviceContext.os = appContext.osName;
    
    //TODO: Get device id from appContext
    deviceContext.deviceId = msai_appAnonID();
    deviceContext.locale = msai_deviceLocale();
    deviceContext.language = msai_deviceLanguage();
    deviceContext.screenResolution = msai_screenSize();
    deviceContext.oemName = @"Apple";
    
    MSAIInternal *internalContext = [MSAIInternal new];
    internalContext.sdkVersion = msai_sdkVersion();
    
    MSAIApplication *applicationContext = [MSAIApplication new];
    applicationContext.version = appContext.appVersion;
    
    MSAISession *sessionContext = [MSAISession new];
    
    MSAIOperation *operationContext = [MSAIOperation new];
    
    MSAIUser *userContext = [MSAIUser new];
    userContext.userId = msai_appAnonID();
    
    MSAILocation *locationContext = [MSAILocation new];
    
    _instrumentationKey = appContext.instrumentationKey;
    _endpointPath = endpointPath;
    _userDefaults = NSUserDefaults.standardUserDefaults;
    _application = applicationContext;
    _device = deviceContext;
    _location = locationContext;
    _user = userContext;
    _internal = internalContext;
    _operation = operationContext;
    _session = sessionContext;
    _tags = [self tags];
    
    if(sessionId){
      [self updateSessionContextWithId:sessionId];
      [MSAISessionHelper addSessionId:sessionId withDate:[NSDate date]];
    }
    [self configureNetworkStatusTracking];
    [self configureSessionTracking];
  }
  return self;
}

- (void)dealloc{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Network

- (void)configureNetworkStatusTracking{
  [[MSAIReachability sharedInstance] startNetworkStatusTracking];
  _device.network = [[MSAIReachability sharedInstance] descriptionForActiveReachabilityType];
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(updateNetworkType:) name:kMSAIReachabilityTypeChangedNotification object:nil];
}

-(void)updateNetworkType:(NSNotification *)notification{
  
  @synchronized(self){
    _device.network = [[notification userInfo]objectForKey:kMSAIReachabilityUserInfoName];
  }
}

#pragma mark - Session

- (void)resetIsNewFlag {
  if ([_session.isNew isEqualToString:@"true"]) {
    _session.isNew = @"false";
  }
}

- (BOOL)isFirstSession{
  return ![_userDefaults boolForKey:kMSAIApplicationWasLaunched];
}

- (void)updateSessionContextWithId:(NSString *)sessionId {
  
  if(![_session.sessionId isEqualToString:sessionId]){
    BOOL firstSession = [self isFirstSession];
    _session.sessionId = sessionId;
    _session.isNew = @"true";
    _session.isFirst = (firstSession ? @"true" : @"false");
  }
}

- (void)configureSessionTracking{
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  __weak typeof(self) weakSelf = self;
  [center addObserverForName:MSAISessionStartedNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *notification) {
                    typeof(self) strongSelf = weakSelf;
                    
                    NSDictionary *userInfo = notification.userInfo;
                    NSString *sessionId = userInfo[kMSAISessionInfoSessionId];
                    [strongSelf updateSessionContextWithId:sessionId];
                  }];
}

#pragma mark - Custom getter
#pragma mark - Helper

- (MSAIOrderedDictionary *)contextDictionary {
  MSAIOrderedDictionary *contextDictionary = [MSAIOrderedDictionary new];
  [contextDictionary addEntriesFromDictionary:self.tags];
  [contextDictionary addEntriesFromDictionary:[self.session serializeToDictionary]];
  [contextDictionary addEntriesFromDictionary:[self.device serializeToDictionary]];
  [self resetIsNewFlag];
  
  return contextDictionary;
}

- (MSAIOrderedDictionary *)tags {
  if(!_tags){
    _tags = [self.application serializeToDictionary];
    [_tags addEntriesFromDictionary:[self.application serializeToDictionary]];
    [_tags addEntriesFromDictionary:[self.location serializeToDictionary]];
    [_tags addEntriesFromDictionary:[self.user serializeToDictionary]];
    [_tags addEntriesFromDictionary:[self.internal serializeToDictionary]];
    [_tags addEntriesFromDictionary:[self.operation serializeToDictionary]];
  }
  return _tags;
}

@end
