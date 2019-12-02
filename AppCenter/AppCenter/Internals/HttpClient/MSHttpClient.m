// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#import "MSHttpClient.h"
#import "MSAppCenterErrors.h"
#import "MSAppCenterInternal.h"
#import "MSConstants+Internal.h"
#import "MSHttpCall.h"
#import "MSHttpClientPrivate.h"
#import "MSHttpUtil.h"
#import "MSLoggerInternal.h"
#import "MSUtility+StringFormatting.h"
#import "MS_Reachability.h"
#import "MSOneCollectorIngestion.h"

#define DEFAULT_RETRY_INTERVALS @[ @10, @(5 * 60), @(20 * 60) ]

@implementation MSHttpClient

- (instancetype)init {
  return [self initWithMaxHttpConnectionsPerHost:nil
                                  retryIntervals:DEFAULT_RETRY_INTERVALS
                                    reachability:[MS_Reachability reachabilityForInternetConnection]
                              compressionEnabled:YES];
}

- (instancetype)initNoRetriesWithCompressionEnabled:(BOOL)compressionEnabled {
  return [self initWithMaxHttpConnectionsPerHost:nil
                                  retryIntervals:@[]
                                    reachability:[MS_Reachability reachabilityForInternetConnection]
                              compressionEnabled:compressionEnabled];
}

- (instancetype)initWithCompressionEnabled:(BOOL)compressionEnabled {
  return [self initWithMaxHttpConnectionsPerHost:nil
                                  retryIntervals:DEFAULT_RETRY_INTERVALS
                                    reachability:[MS_Reachability reachabilityForInternetConnection]
                              compressionEnabled:compressionEnabled];
}

- (instancetype)initWithMaxHttpConnectionsPerHost:(NSInteger)maxHttpConnectionsPerHost compressionEnabled:(BOOL)compressionEnabled {
  return [self initWithMaxHttpConnectionsPerHost:@(maxHttpConnectionsPerHost)
                                  retryIntervals:DEFAULT_RETRY_INTERVALS
                                    reachability:[MS_Reachability reachabilityForInternetConnection]
                              compressionEnabled:compressionEnabled];
}

- (instancetype)initWithMaxHttpConnectionsPerHost:(NSNumber *)maxHttpConnectionsPerHost
                                   retryIntervals:(NSArray *)retryIntervals
                                     reachability:(MS_Reachability *)reachability
                               compressionEnabled:(BOOL)compressionEnabled {
  if ((self = [super init])) {
    _sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    if (maxHttpConnectionsPerHost) {
      _sessionConfiguration.HTTPMaximumConnectionsPerHost = [maxHttpConnectionsPerHost integerValue];
    }
    _session = [NSURLSession sessionWithConfiguration:_sessionConfiguration];
    _pendingCalls = [NSMutableSet new];
    _retryIntervals = [NSArray arrayWithArray:retryIntervals];
    _enabled = YES;
    _reachability = reachability;
    _compressionEnabled = compressionEnabled;

    // Add listener to reachability.
    [MS_NOTIFICATION_CENTER addObserver:self selector:@selector(networkStateChanged:) name:kMSReachabilityChangedNotification object:nil];
    [self.reachability startNotifier];
  }
  return self;
}

- (void)sendAsync:(NSURL *)url
               method:(NSString *)method
              headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                 data:(nullable NSData *)data
    completionHandler:(MSHttpRequestCompletionHandler)completionHandler {
  @synchronized(self) {
    if (!self.enabled) {
      NSError *error = [NSError errorWithDomain:kMSACErrorDomain
                                           code:MSACDisabledErrorCode
                                       userInfo:@{NSLocalizedDescriptionKey : kMSACDisabledErrorDesc}];
      completionHandler(nil, nil, error);
      return;
    }
    MSHttpCall *call = [[MSHttpCall alloc] initWithUrl:url
                                                method:method
                                               headers:headers
                                                  data:data
                                        retryIntervals:self.retryIntervals
                                    compressionEnabled:self.compressionEnabled
                                     completionHandler:completionHandler];
    [self sendCallAsync:call];
  }
}

- (void)sendCallAsync:(MSHttpCall *)call {
  @synchronized(self) {
    if (![self.pendingCalls containsObject:call]) {
      [self.pendingCalls addObject:call];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:call.url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:0];
    request.HTTPBody = call.data;
    request.HTTPMethod = call.method;
    request.allHTTPHeaderFields = call.headers;

    // Always disable cookies.
    [request setHTTPShouldHandleCookies:NO];
    call.inProgress = YES;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                   [self requestCompletedWithHttpCall:call data:data response:response error:error];
                                                 }];
    [task resume];
  }
}

- (void)requestCompletedWithHttpCall:(MSHttpCall *)httpCall data:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
  NSHTTPURLResponse *httpResponse;
  @synchronized(self) {
    httpCall.inProgress = NO;

    // If the call was removed, do not invoke the completion handler as that will have been done already by set enabled.
    if (![self.pendingCalls containsObject:httpCall]) {
      MSLogDebug([MSAppCenter logTag], @"HTTP call was canceled; do not process further.");
      return;
    }

    // Handle NSError (low level error where we don't even get a HTTP response).
    BOOL internetIsDown = [MSHttpUtil isNoInternetConnectionError:error];
    BOOL couldNotEstablishSecureConnection = [MSHttpUtil isSSLConnectionError:error];
    if (error) {
      if (internetIsDown || couldNotEstablishSecureConnection) {

        // Reset the retry count, will retry once the (secure) connection is established again.
        [httpCall resetRetry];
        NSString *logMessage = internetIsDown ? @"Internet connection is down." : @"Could not establish secure connection.";
        MSLogInfo([MSAppCenter logTag], @"HTTP call failed with error: %@", logMessage);
        return;
      } else {
        MSLogError([MSAppCenter logTag], @"HTTP request error with code: %td, domain: %@, description: %@", error.code, error.domain,
                   error.localizedDescription);
      }
    }

    // Handle HTTP error.
    else {
      httpResponse = (NSHTTPURLResponse *)response;
      if ([MSHttpUtil isRecoverableError:httpResponse.statusCode] && ![httpCall hasReachedMaxRetries]) {

        // Check if there is a "retry after" header in the response
        NSString *retryAfter = httpResponse.allHeaderFields[kMSRetryHeaderKey];
        NSNumber *retryAfterMilliseconds;
        if (retryAfter) {
          NSNumberFormatter *formatter = [NSNumberFormatter new];
          retryAfterMilliseconds = [formatter numberFromString:retryAfter];
        }
        [httpCall startRetryTimerWithStatusCode:httpResponse.statusCode
                                     retryAfter:retryAfterMilliseconds
                                          event:^{
                                            [self sendCallAsync:httpCall];
                                          }];
        return;
      }
    }
    [self.pendingCalls removeObject:httpCall];
  }

  // Unblock the caller now with the outcome of the call.
  httpCall.completionHandler(data, httpResponse, error);
}

- (void)networkStateChanged:(__unused NSNotificationCenter *)notification {
  if ([self.reachability currentReachabilityStatus] == NotReachable) {
    MSLogInfo([MSAppCenter logTag], @"Internet connection is down.");
  } else {
    MSLogInfo([MSAppCenter logTag], @"Internet connection is up.");
  }
}

- (void)setEnabled:(BOOL)isEnabled {
  @synchronized(self) {
    if (self.enabled != isEnabled) {
      _enabled = isEnabled;
      if (isEnabled) {
        self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration];
        [self.reachability startNotifier];
      } else {
        [self.reachability stopNotifier];

        // Cancel all the tasks and invalidate current session to free resources.
        [self.session invalidateAndCancel];
        self.session = nil;

        // Remove pending calls and invoke their completion handler.
        for (MSHttpCall *call in self.pendingCalls) {
          NSError *error = [NSError errorWithDomain:kMSACErrorDomain
                                               code:MSACCanceledErrorCode
                                           userInfo:@{NSLocalizedDescriptionKey : kMSACCanceledErrorDesc}];
          call.completionHandler(nil, nil, error);
        }
        [self.pendingCalls removeAllObjects];
      }
    }
  }
}

- (void)dealloc {
  [self.reachability stopNotifier];
  [MS_NOTIFICATION_CENTER removeObserver:self name:kMSReachabilityChangedNotification object:nil];
  [self.session finishTasksAndInvalidate];
}

@end
