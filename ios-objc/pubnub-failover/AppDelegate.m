//
//  AppDelegate.m
//  pubnub-failover
//
//  Created by Serhii Mamontov on 30.11.2022.
//

#import "AppDelegate.h"
#import "PubNubManager.h"


@interface AppDelegate () <PNEventsListener>

#pragma mark - Information

@property (nonatomic, strong) PubNubManager *pubNubManager;

#pragma mark -

@end


@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  NSArray *origins = @[@"ringcentral-backup-1.pubnubapi.com", @"ringcentral-backup-2.pubnubapi.com"];
  PNConfiguration *configuration = [PNConfiguration configurationWithPublishKey:@"demo"
                                                                   subscribeKey:@"demo"
                                                                           uuid:@"myUniqueUUID"];
  configuration.origin = @"ringcentral.pubnubapi.com";
  configuration.authKey = @"my-auth-key";
  
  self.pubNubManager = [[PubNubManager alloc] initWithConfiguration:configuration origins:origins];
  [self.pubNubManager addListener:self];
  
  [self.pubNubManager subscribeToChannels:@[@"hello_world"] withPresence:NO];
  
  return YES;
}


#pragma mark - Event listener delegate

- (void)client:(PubNub *)client didReceiveStatus:(PNStatus *)status {
  if (status.operation == PNSubscribeOperation) {
    // Handle subscribe operation.
  }
}

@end
