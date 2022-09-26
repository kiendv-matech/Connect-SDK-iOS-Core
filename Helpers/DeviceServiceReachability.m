//
// Created by Jeremy White on 4/14/14.
// Copyright (c) 2014 LG Electronics. All rights reserved.
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

#import "DeviceServiceReachability.h"


@implementation DeviceServiceReachability
{
    NSTimer *_runTimer;
    NSOperationQueue *_reachabilityQueue;
}

- (instancetype) initWithTargetURL:(NSURL *)targetURL
{
    self = [super init];

    if (self)
    {
        _running = NO;
        _targetURL = targetURL;
        _reachabilityQueue = [[NSOperationQueue alloc] init];
    }

    return self;
}

+ (instancetype) reachabilityWithTargetURL:(NSURL *)targetURL
{
    return [[self alloc] initWithTargetURL:targetURL];
}

- (void) start
{
    _running = YES;
    _runTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(checkReachability) userInfo:nil repeats:YES];
    [_runTimer fire];
}

- (void) stop
{
    if (_running)
    {
        [_runTimer invalidate];
        _runTimer = nil;

        _running = NO;
    }
}

- (void) checkReachability
{
    if (!_running)
        return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.targetURL];
    [request setTimeoutInterval:10];
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:nil delegateQueue:_reachabilityQueue];
    __weak typeof(self) weakSelf = self;
    [[urlSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable connectionError) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!strongSelf->_running)
            return;

        if (connectionError) {
            DLog(@"Connection error to %@: %@", strongSelf.targetURL, connectionError);
        }

        const BOOL noDataIsAvailable = !data && connectionError && !response;
        if (noDataIsAvailable)
        {
            [strongSelf stop];

            if (strongSelf.delegate)
            {
                dispatch_async(dispatch_get_main_queue(), ^
                {
                    [strongSelf.delegate didLoseReachability:strongSelf];
                });
            }
        }
    }] resume];
}

@end
