//
//  PubNubManager.m
//  pubnub-failover
//
//  Created by Sergey Mamontov on 30.11.2022.
//

#import "PubNubManager.h"


#pragma mark Static

/**
 * @brief Interval at which scheduled timer will try to check main origin availability.
 */
static NSTimeInterval const kMainOriginCheckInterval = 60.f;

/**
 * @brief How many times it is allowed to fail subscribe before failover will be triggered.
 */
static NSUInteger const kMaximumRetryCount = 5;


#pragma mark - Private interface declaration

@interface PubNubManager () <PNEventsListener>

#pragma mark - Information

// Request and timer which is used to reach main origin.
@property (nonatomic, assign, getter=isMainOriginReachable) BOOL mainOriginReachable;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *checkOriginRequest;
@property (nonatomic, nullable, strong) NSTimer *checkOriginTimer;
// PubNub client and list of failover origins.
@property (nonatomic, strong) NSArray<NSString *> *origins;
@property (nonatomic, strong) PubNub *client;

@property (nonatomic, strong, nullable) dispatch_queue_t resourcesAccessQueue;
@property (nonatomic, assign) NSUInteger currentTimeFailureCount;


#pragma mark - Failover handling

/**
 * @brief Handle requirement to recover after origin became unavailable.
 */
- (void)failoverOrigin;

- (void)observeMainOriginAvailability;

- (void)handleFailoverTimer:(NSTimer *)timer;

#pragma mark -


@end


#pragma mark - Interface implementation

@implementation PubNubManager


#pragma mark - Initialization & configuration

- (instancetype)initWithConfiguration:(PNConfiguration *)configuration origins:(NSArray<NSString *> *)origins {
  if ((self = [super init])) {
    self.client = [PubNub clientWithConfiguration:configuration];
    [self.client addListener:self];
    
    // Complete failover configuration.
    self.resourcesAccessQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    // Prepend main origin to list of failover origins list.
    if (![origins containsObject:configuration.origin]) {
      origins = [@[configuration.origin] arrayByAddingObjectsFromArray:origins];
    }
    
    self.origins = origins;
  }
  
  return self;
}


#pragma mark - Subscription

- (void)subscribeToChannels:(NSArray<NSString *> *)channels withPresence:(BOOL)shouldObservePresence {
  dispatch_async(self.resourcesAccessQueue, ^{
    [self.client subscribeToChannels:channels withPresence:shouldObservePresence];
  });
}

- (void)unsubscribeFromChannels:(NSArray<NSString *> *)channels withPresence:(BOOL)shouldObservePresence {
  dispatch_async(self.resourcesAccessQueue, ^{
    [self.client unsubscribeFromChannels:channels withPresence:shouldObservePresence];
  });
}


#pragma mark - Listeners

- (void)addListener:(id <PNEventsListener>)listener {
  dispatch_async(self.resourcesAccessQueue, ^{
    [self.client addListener:listener];
  });
}

- (void)removeListener:(id <PNEventsListener>)listener {
  dispatch_async(self.resourcesAccessQueue, ^{
    [self.client removeListener:listener];
  });
}


#pragma mark - Event listener delegate

- (void)client:(PubNub *)client didReceiveStatus:(PNStatus *)status {
  // Handling any unexpected disconnection (PAM errors doesn't fall under this category).
  if (status.operation == PNSubscribeOperation && status.category == PNUnexpectedDisconnectCategory) {
    PNSubscribeStatus *subscribeStatus = (PNSubscribeStatus *)status;
    
    if (self.currentTimeFailureCount >= kMaximumRetryCount - 1) {
      // Cancel automatic retry every 10 seconds.
      [subscribeStatus cancelAutomaticRetry];
      
      // Starting failover timer if required.
      [self observeMainOriginAvailability];
      // Rotate origins to find the one which is reachable.
      [self failoverOrigin];
    } else {
      self.currentTimeFailureCount++;
    }
  }
}


#pragma mark - Failover handling

- (void)failoverOrigin {
  dispatch_async(self.resourcesAccessQueue, ^{
    NSString *currentOrigin = self.client.currentConfiguration.origin;
    NSUInteger currentOriginIdx = [self.origins indexOfObject:currentOrigin];
    NSUInteger nextOriginIdx = currentOriginIdx == self.origins.count - 1 ? 0 : currentOriginIdx + 1;
    self.currentTimeFailureCount = 0;
    
    if (self.isMainOriginReachable) {
      nextOriginIdx = 0;
    }
    
    // Skip origin update if it is used already (when both failover already used main origin and observer timer detected
    // main origin availability).
    if ([self.origins[nextOriginIdx] isEqual:self.client.currentConfiguration.origin]) {
      return;
    }
    
    PNConfiguration *configuration = self.client.currentConfiguration;
    configuration.origin = self.origins[nextOriginIdx];
    
    [self.client copyWithConfiguration:configuration completion:^(PubNub *client) {
      dispatch_barrier_sync(self.resourcesAccessQueue, ^{
        self.client = client;
      });
    }];
  });
}

- (void)observeMainOriginAvailability {
  dispatch_barrier_sync(self.resourcesAccessQueue, ^{
    // There is no need in timer restart, while main origin not reachable.
    if ([self.checkOriginTimer isValid]) {
      return;
    }
    
    // If observer started, main origin not reachable.
    self.mainOriginReachable = NO;
    
    self.checkOriginTimer = [NSTimer timerWithTimeInterval:kMainOriginCheckInterval
                                                    target:self
                                                  selector:@selector(handleFailoverTimer:)
                                                  userInfo:nil
                                                   repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.checkOriginTimer forMode:NSRunLoopCommonModes];
  });
}

- (void)handleFailoverTimer:(NSTimer *)timer {
  dispatch_async(self.resourcesAccessQueue, ^{
    // Endpoint which should be used to check origin reachability.
    NSString *urlString = [NSString stringWithFormat:@"https://%@/v2/subscribe/%@/%@/0",
                           self.origins.firstObject,
                           self.client.currentConfiguration.subscribeKey,
                           [self percentEncodedString:[self.client channels].firstObject]];
    
    if (self.client.currentConfiguration.authKey.length > 0) {
      urlString = [urlString stringByAppendingFormat:@"?auth=%@",
                   [self percentEncodedString:self.client.currentConfiguration.authKey]];
    }
    
    __weak __typeof(self) weakSelf = self;
    NSURLSession *session = NSURLSession.sharedSession;
    
    [[session dataTaskWithURL:[NSURL URLWithString:urlString]
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      __strong __typeof(self) strongSelf = weakSelf;
      
      if (((NSHTTPURLResponse *)response).statusCode == 200) {
        // Looks like main origin is reachable now.
        dispatch_barrier_async(strongSelf.resourcesAccessQueue, ^{
          strongSelf.mainOriginReachable = YES;
          
          [strongSelf.checkOriginTimer invalidate];
          strongSelf.checkOriginTimer = nil;
        });
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          [strongSelf failoverOrigin];
        });
      }
    }] resume];
  });
}


#pragma mark - Misc

- (NSString *)percentEncodedString:(NSString *)string {
  static NSCharacterSet *_allowedCharacters;
  static dispatch_once_t onceToken;
  
  dispatch_once(&onceToken, ^{
    // Preparing set of characters which shouldn't be percent-encoded.
    NSMutableCharacterSet *chars = [[NSMutableCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    [chars formUnionWithCharacterSet:[NSCharacterSet URLQueryAllowedCharacterSet]];
    [chars formUnionWithCharacterSet:[NSCharacterSet URLFragmentAllowedCharacterSet]];
    [chars removeCharactersInString:@":/?#[]@!$&’()*+,;="];
    
    _allowedCharacters = [chars copy];
  });
  
  return [string stringByAddingPercentEncodingWithAllowedCharacters:_allowedCharacters];
}

#pragma mark -


@end
