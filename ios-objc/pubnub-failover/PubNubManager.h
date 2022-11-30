//
//  PubNubManager.h
//  pubnub-failover
//
//  Created by Sergey Mamontov on 30.11.2022.
//

#import <Foundation/Foundation.h>
#import <PubNub/PubNub.h>


NS_ASSUME_NONNULL_BEGIN

@interface PubNubManager : NSObject


#pragma mark - Information

/**
 * @brief Currently used \b PubNub instance.
 */
@property (nonatomic, readonly, strong) PubNub *client;


#pragma mark Initialization & configuration

/**
 * @brief Instantiate \b PubNub manager instance with default configuration and failover origins.
 *
 * @param configuration - \b PubNub client configuration instance with default origin.
 * @param origins - List of origins which should be used for failover (excluding main origin).
 *
 * @return Configured and ready to use manager.
 */
- (instancetype)initWithConfiguration:(PNConfiguration *)configuration origins:(NSArray<NSString *> *)origins;


#pragma mark - Subscription

- (void)subscribeToChannels:(NSArray<NSString *> *)channels withPresence:(BOOL)shouldObservePresence;
- (void)unsubscribeFromChannels:(NSArray<NSString *> *)channels withPresence:(BOOL)shouldObservePresence;


#pragma mark - Listeners

- (void)addListener:(id <PNEventsListener>)listener;
- (void)removeListener:(id <PNEventsListener>)listener;

#pragma mark -


@end

NS_ASSUME_NONNULL_END
