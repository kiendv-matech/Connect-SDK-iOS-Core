//
//  DLNAHTTPServer.m
//  Connect SDK
//
//  Created by Jeremy White on 9/30/14.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <ifaddrs.h>
#import <arpa/inet.h>
#import "DLNAHTTPServer.h"
#import "DeviceService.h"
#import "CTXMLReader.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerHTTPStatusCodes.h"
#import "ConnectUtil.h"
#import <sys/sysctl.h>
#import <net/if.h>

#define IOS_CELLULAR    @"pdp_ip0"
#define IOS_WIFI        @"en0"
#define IOS_WIRED       @"en2"
#define IOS_VPN         @"utun0"
#define IP_ADDR_IPv4    @"ipv4"
#define IP_ADDR_IPv6    @"ipv6"

@implementation DLNAHTTPServer
{
    NSMutableDictionary *_allSubscriptions;
}

- (instancetype) init
{
    if (self = [super init])
    {
        _allSubscriptions = [NSMutableDictionary new];
    }

    return self;
}

- (BOOL) isRunning
{
    if (!_server)
        return NO;
    else
        return _server.isRunning;
}

- (void) start
{
    [self stop];

    [_allSubscriptions removeAllObjects];

    _server = [[GCDWebServer alloc] init];
    _server.delegate = self;

    GCDWebServerResponse *(^webServerResponseBlock)(GCDWebServerRequest *request) = ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        [self processRequest:(GCDWebServerDataRequest *)request];
        // according to the UPnP specification, a subscriber must reply with HTTP 200 OK
        // to successfully acknowledge the notification
        return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
    };

    [self.server addDefaultHandlerForMethod:@"NOTIFY"
                               requestClass:[GCDWebServerDataRequest class]
                               processBlock:webServerResponseBlock];

    [self.server startWithPort:49291 bonjourName:nil];
}

- (void) stop
{
    if (!_server)
        return;

    self.server.delegate = nil;

    if (_server.isRunning)
        [self.server stop];

    _server = nil;
}

/// Returns a service subscription key for the given URL. Different service URLs
/// should produce different keys by extracting the relative path, e.g.:
/// "http://example.com:8888/foo/bar?q=a#abc" => "/foo/bar?q=a#abc"
- (NSString *)serviceSubscriptionKeyForURL:(NSURL *)url {
    // unfortunately, -[NSURL relativeString] works for URLs created with
    // -initWithString:relativeToURL: only
    NSString *resourceSpecifier = url.absoluteURL.resourceSpecifier;
    // resourceSpecifier starts with two slashes, so we'll look for the third one
    NSRange relativePathStartRange = [resourceSpecifier rangeOfString:@"/"
                                                              options:0
                                                                range:NSMakeRange(2, resourceSpecifier.length - 2)];
    NSAssert(NSNotFound != relativePathStartRange.location, @"Couldn't find relative path in %@", resourceSpecifier);
    return [resourceSpecifier substringFromIndex:relativePathStartRange.location];
}

- (void) addSubscription:(ServiceSubscription *)subscription
{
    @synchronized (_allSubscriptions)
    {
        NSString *serviceSubscriptionKey = [self serviceSubscriptionKeyForURL:subscription.target];

        if (!_allSubscriptions[serviceSubscriptionKey])
            _allSubscriptions[serviceSubscriptionKey] = [NSMutableArray new];

        NSMutableArray *serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
        [serviceSubscriptions addObject:subscription];
        subscription.isSubscribed = YES;
    }
}

- (void) removeSubscription:(ServiceSubscription *)subscription
{
    @synchronized (_allSubscriptions)
    {
        NSString *serviceSubscriptionKey = [self serviceSubscriptionKeyForURL:subscription.target];

        NSMutableArray *serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];

        if (!_allSubscriptions[serviceSubscriptionKey])
            return;

        subscription.isSubscribed = NO;
        [serviceSubscriptions removeObject:subscription];

        if (serviceSubscriptions.count == 0)
            [_allSubscriptions removeObjectForKey:serviceSubscriptionKey];
    }
}

- (BOOL) hasSubscriptions
{
    @synchronized (_allSubscriptions)
    {
        return _allSubscriptions.count > 0;
    }
}

- (void) processRequest:(GCDWebServerDataRequest *)request
{
    if (!request.data || request.data.length == 0)
        return;

    NSString *serviceSubscriptionKey = [[self serviceSubscriptionKeyForURL:request.URL]
                                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *serviceSubscriptions;

    @synchronized (_allSubscriptions)
    {
        serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
    }

    if (!serviceSubscriptions || serviceSubscriptions.count == 0)
        return;
 
    NSError *xmlParseError;
    NSDictionary *requestDataXML = [CTXMLReader dictionaryForXMLData:request.data error:&xmlParseError];

    if (xmlParseError)
    {
        DLog(@"XML Parse error %@", xmlParseError.description);
        return;
    }

    NSString *eventXMLStringEncoded = requestDataXML[@"e:propertyset"][@"e:property"][@"LastChange"][@"text"];

    if (!eventXMLStringEncoded)
    {
        DLog(@"Received event with no LastChange data, ignoring...");
        return;
    }

    NSError *eventXMLParseError;
    NSDictionary *eventXML = [CTXMLReader dictionaryForXMLString:eventXMLStringEncoded
                                                           error:&eventXMLParseError];

    if (eventXMLParseError)
    {
        DLog(@"Could not parse event into usable format, ignoring… (%@)", eventXMLParseError);
        return;
    }

    [self handleEvent:eventXML forSubscriptions:serviceSubscriptions];
}

- (void) handleEvent:(NSDictionary *)eventInfo forSubscriptions:(NSArray *)subscriptions
{
    DLog(@"eventInfo: %@", eventInfo);

    [subscriptions enumerateObjectsUsingBlock:^(ServiceSubscription *subscription, NSUInteger subIdx, BOOL *subStop) {
        [subscription.successCalls enumerateObjectsUsingBlock:^(SuccessBlock success, NSUInteger successIdx, BOOL *successStop) {
            dispatch_on_main(^{
                success(eventInfo);
            });
        }];
    }];
}

#pragma mark - GCDWebServerDelegate

- (void) webServerDidStart:(GCDWebServer *)server { }
- (void) webServerDidStop:(GCDWebServer *)server { }

#pragma mark - Utility

- (NSString *)getHostPath
{
    return [NSString stringWithFormat:@"http://%@:%d/", [self getIPAddress], 49291];
}

-(NSString *)getIPAddress
{
    NSString *address = @"error";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;

    // retrieve the current interfaces - returns 0 on success
    success = getifaddrs(&interfaces);
    if (success == 0)
    {
        // Loop through linked list of interfaces
        temp_addr = interfaces;
        while(temp_addr != NULL)
        {
            if(temp_addr->ifa_addr->sa_family == AF_INET)
            {
                // Get NSString from C String
                address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
            }
            temp_addr = temp_addr->ifa_next;
        }
    }

    // Free memory
    freeifaddrs(interfaces);
    return address;
}

//- (NSString *)getIPAddress:(BOOL)preferIPv4
//{
//    NSArray *searchArray = preferIPv4 ?
//                            @[ IOS_WIFI @"/" IP_ADDR_IPv4, IOS_WIFI @"/" IP_ADDR_IPv6, IOS_CELLULAR @"/" IP_ADDR_IPv4, IOS_CELLULAR @"/" IP_ADDR_IPv6 ] :
//                            @[ IOS_WIFI @"/" IP_ADDR_IPv6, IOS_WIFI @"/" IP_ADDR_IPv4, IOS_CELLULAR @"/" IP_ADDR_IPv6, IOS_CELLULAR @"/" IP_ADDR_IPv4 ] ;
//
//    NSDictionary *addresses = [self getIPAddresses];
//
//    __block NSString *address;
//    [searchArray enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop)
//        {
//            address = addresses[key];
//            if(address) *stop = YES;
//        } ];
//    return address ? address : @"0.0.0.0";
//}
//
//- (NSDictionary *)getIPAddresses
//{
//    NSMutableDictionary *addresses = [NSMutableDictionary dictionaryWithCapacity: 8];
//
//    // retrieve the current interfaces - returns 0 on success
//    struct ifaddrs *interfaces;
//    if(!getifaddrs(&interfaces)) {
//        // Loop through linked list of interfaces
//        struct ifaddrs *interface;
//        for(interface=interfaces; interface; interface=interface->ifa_next) {
//            if(!(interface->ifa_flags & IFF_UP) /* || (interface->ifa_flags & IFF_LOOPBACK) */ ) {
//                continue; // deeply nested code harder to read
//            }
//            const struct sockaddr_in *addr = (const struct sockaddr_in*)interface->ifa_addr;
//            char addrBuf[ MAX(INET_ADDRSTRLEN, INET6_ADDRSTRLEN) ];
//            if(addr && (addr->sin_family==AF_INET || addr->sin_family==AF_INET6)) {
//                NSString *name = [NSString stringWithUTF8String:interface->ifa_name];
//                NSString *type;
//                if(addr->sin_family == AF_INET) {
//                    if(inet_ntop(AF_INET, &addr->sin_addr, addrBuf, INET_ADDRSTRLEN)) {
//                        type = IP_ADDR_IPv4;
//                    }
//                } else {
//                    const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6*)interface->ifa_addr;
//                    if(inet_ntop(AF_INET6, &addr6->sin6_addr, addrBuf, INET6_ADDRSTRLEN)) {
//                        type = IP_ADDR_IPv6;
//                    }
//                }
//                if(type) {
//                    NSString *key = [NSString stringWithFormat:@"%@/%@", name, type];
//                    addresses[key] = [NSString stringWithUTF8String:addrBuf];
//                }
//            }
//        }
//        // Free memory
//        freeifaddrs(interfaces);
//    }
//    return [addresses count] ? addresses : nil;
//}

@end
