/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 */

#import "SNMAnalytics.h"
#import "SNMAnalyticsCategory.h"
#import "SNMAnalyticsPrivate.h"
#import "SNMEventLog.h"
#import "SNMFeatureAbstractProtected.h"
#import "SNMLogManager.h"
#import "SNMPageLog.h"
#import "SNMSonoma.h"
#import "SNMSonomaInternal.h"
#import "SonomaCore+Internal.h"

/**
 *  Feature storage key name.
 */
static NSString *const kSNMFeatureName = @"Analytics";

@implementation SNMAnalytics

@synthesize autoPageTrackingEnabled = _autoPageTrackingEnabled;

#pragma mark - Module initialization

- (instancetype)init {
  if (self = [super init]) {

    // Set defaults.
    _autoPageTrackingEnabled = YES;

    // Init session tracker.
    _sessionTracker = [[SNMSessionTracker alloc] init];
    _sessionTracker.delegate = self;
  }
  return self;
}

#pragma mark - SNMFeatureInternal

+ (instancetype)sharedInstance {
  static id sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (void)startFeature {
  [super startFeature];
  SNMLogVerbose(@"SNMAnalytics: Started analytics module");
}

- (NSString *)storageKey {
  return kSNMFeatureName;
}

- (SNMPriority)priority {
  return SNMPriorityDefault;
}

- (void)onLogManagerReady:(id<SNMLogManager>)logManager {
  [super onLogManagerReady:logManager];

  // Add delegate to log manager.
  [self.logManager addDelegate:_sessionTracker];

  // Start session tracker
  [self.sessionTracker start];
}

#pragma mark - SNMFeatureAbstract

- (void)setEnabled:(BOOL)isEnabled {
  if (isEnabled) {
    [self.sessionTracker start];
    [self.logManager addDelegate:self.sessionTracker];
  } else {
    [self.logManager removeDelegate:self.sessionTracker];
    [self.sessionTracker stop];
    [self.sessionTracker clearSessions];
  }
  [super setEnabled:isEnabled];
}

#pragma mark - Module methods

+ (void)trackEvent:(NSString *)eventName {
  [self trackEvent:eventName withProperties:nil];
}

+ (void)trackEvent:(NSString *)eventName withProperties:(NSDictionary *)properties {
  @synchronized(self) {
    if ([[self sharedInstance] canBeUsed]) {
      [[self sharedInstance] trackEvent:eventName withProperties:properties];
    }
  }
}

+ (void)trackPage:(NSString *)pageName {
  [self trackPage:pageName withProperties:nil];
}

+ (void)trackPage:(NSString *)pageName withProperties:(NSDictionary *)properties {
  @synchronized(self) {
    if ([[self sharedInstance] canBeUsed]) {
      [[self sharedInstance] trackPage:pageName withProperties:properties];
    }
  }
}

+ (void)setAutoPageTrackingEnabled:(BOOL)isEnabled {
  @synchronized(self) {
    [[self sharedInstance] setAutoPageTrackingEnabled:isEnabled];
  }
}

+ (BOOL)isAutoPageTrackingEnabled {
  @synchronized(self) {
    return [[self sharedInstance] isAutoPageTrackingEnabled];
  }
}

#pragma mark - Private methods

- (void)trackEvent:(NSString *)eventName withProperties:(NSDictionary *)properties {
  if (![self isEnabled])
    return;

  // Create and set properties of the event log
  SNMEventLog *log = [[SNMEventLog alloc] init];
  log.name = eventName;
  log.eventId = kSNMUUIDString;
  if (properties)
    log.properties = properties;

  // Send log to core module
  [self sendLog:log withPriority:self.priority];
}

- (void)trackPage:(NSString *)pageName withProperties:(NSDictionary *)properties {
  if (![super isEnabled])
    return;

  // Create and set properties of the event log
  SNMPageLog *log = [[SNMPageLog alloc] init];
  log.name = pageName;
  if (properties)
    log.properties = properties;

  // Send log to core module
  [self sendLog:log withPriority:self.priority];
}

- (void)setAutoPageTrackingEnabled:(BOOL)isEnabled {
  _autoPageTrackingEnabled = isEnabled;
}

- (BOOL)isAutoPageTrackingEnabled {
  return _autoPageTrackingEnabled;
}

- (void)sendLog:(id<SNMLog>)log withPriority:(SNMPriority)priority {

  // Send log to core module.
  [self.logManager processLog:log withPriority:priority];
}

#pragma mark - SNMSessionTracker

- (void)sessionTracker:(id)sessionTracker processLog:(id<SNMLog>)log withPriority:(SNMPriority)priority {
  [self sendLog:log withPriority:priority];
}

@end
