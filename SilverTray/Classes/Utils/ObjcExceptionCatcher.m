//
//  ObjcExceptionCatcher.m
//  NuguCore
//
//  Created by DCs-OfficeMBP on 24/05/2019.
//  Copyright (c) 2019 SK Telecom Co., Ltd. All rights reserved.
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

#import <Foundation/Foundation.h>
#import "ObjcExceptionCatcher.h"

@implementation ObjcExceptionCatcher

+ (NSError *)objcTry:(NSError*(NS_NOESCAPE ^)(void))tryBlock {
    @try {
        tryBlock();
    } @catch (NSException *exception) {
        NSError *error = [[NSError alloc] initWithDomain:exception.name code:0 userInfo:exception.userInfo];
        return error;
    }
    
    return nil;
}

@end
