#import "AppDelegate.h"
#import <PubNub/PubNub.h>
​
​
@interface AppDelegate () <PNEventsListener>
​
#pragma mark - Information
​
// Request and timer which is used to reach main origin.
@property (nonatomic, assign, getter=isMainOriginReachable) BOOL mainOriginReachable;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *checkOriginRequest;
@property (nonatomic, nullable, strong) dispatch_source_t checkOriginTimer;
@property (nonatomic, strong, nullable) dispatch_queue_t checkOriginQueue;
// PubNub client and list of failover origins.
@property (nonatomic, strong) NSArray<NSString *> *origins;
@property (nonatomic, strong) PubNub *client;
​
@property (nonatomic, assign) NSUInteger currentTimeFailureCount;
​
#pragma mark -
​
@end
​
​
@implementation RCVideoAppDelegate
​
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.origins = @[@"ringcentral.pubnubapi.com", @"ringcentral-backup-1.pubnubapi.com", @"ringcentral-backup-2.pubnubapi.com"];
  self.checkOriginQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  
  PNConfiguration *configuration = [PNConfiguration configurationWithPublishKey: @"myPublishKey"
                                                                   subscribeKey:@"mySubscribeKey"
                                                                           uuid:@"myUniqueUUID"];
  configuration.origin = self.origins.firstObject;
  self.client = [PubNub clientWithConfiguration:configuration];
  [self.client addListener:self];
  
  [self.client subscribeToChannels:@[@"hello_world"] withPresence:NO];
  
  return YES;
}
​
- (void)failoverOrigin {
  NSString *currentOrigin = self.client.currentConfiguration.origin;
  NSUInteger currentOriginIdx = [self.origins indexOfObject:currentOrigin];
  __block NSUInteger nextOriginIdx = currentOriginIdx == self.origins.count - 1 ? 0 : currentOriginIdx + 1;
  
  dispatch_sync(self.checkOriginQueue, ^{
    if (self.isMainOriginReachable) {
      nextOriginIdx = 0;
    }
  });
  
  PNConfiguration *configuration = self.client.currentConfiguration;
  configuration.origin = self.origins[nextOriginIdx];
  
  // Skip origin update if it is used already (when both failover already used main origin and observer timer detected
  // main origin availability).
  if ([self.origins[nextOriginIdx] isEqual:self.client.currentConfiguration.origin]) {
    return;
  }
  
  [self.client copyWithConfiguration:configuration completion:^(PubNub *client) {
    NSLog(@"Client switched to: %@", client.currentConfiguration.origin);
    self.client = client;
  }];
}
​
- (void)observeMainOriginAvailability {
  // There is no need in timer restart, while main origin not reachable.
  if (self.checkOriginTimer != NULL && dispatch_source_testcancel(self.checkOriginTimer) == 0) {
    return;
  }
  
  // If observer started, main origin not reachable.
  dispatch_barrier_async(self.checkOriginQueue, ^{
    self.mainOriginReachable = NO;
  });
  
  // Endpoint which should be used to check origin reachability.
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/time/0", self.origins.firstObject]];
  __weak __typeof(self) weakSelf = self;
  
  dispatch_queue_t timerQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, timerQueue);
  
  dispatch_source_set_event_handler(timer, ^{
    NSURLSession *session = NSURLSession.sharedSession;
    __strong __typeof(self) strongSelf = weakSelf;
    
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (((NSHTTPURLResponse *)response).statusCode == 200) {
        // Looks like main origin is reachable now.
        dispatch_barrier_async(strongSelf.checkOriginQueue, ^{
          strongSelf.mainOriginReachable = YES;
          
          // Cancel main origin check timer.
          if (strongSelf->_checkOriginTimer != NULL && dispatch_source_testcancel(strongSelf->_checkOriginTimer) == 0) {
            dispatch_source_cancel(strongSelf->_checkOriginTimer);
            strongSelf->_checkOriginTimer = NULL;
          }
          
          [weakSelf failoverOrigin];
        });
      }
    }] resume];
    
    
  });
  
  dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)((uint64_t)6.f * NSEC_PER_SEC));
  dispatch_source_set_timer(timer, start, (uint64_t)6.f * NSEC_PER_SEC, NSEC_PER_SEC);
  dispatch_barrier_async(self.checkOriginQueue, ^{
    self.checkOriginTimer = timer;
  });
  dispatch_resume(timer);
}
​
​
#pragma mark - Event listener delegate
​
- (void)client:(PubNub *)client didReceiveStatus:(PNStatus *)status {
  // Handling any unexpected disconnection (PAM errors doesn't fall under this category).
  if (status.category == PNUnexpectedDisconnectCategory) {
    // Starting failover timer if required.
    [self observeMainOriginAvailability];
    // Rotate origins to find the one which is reachable.
    [self failoverOrigin];
  }
}
​
#pragma mark -
​
@end