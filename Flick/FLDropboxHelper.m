//
//  FLDropboxHelper.m
//  Flick
//
//  Created by Matt Nichols on 11/29/13.
//  Copyright (c) 2013 Matt Nichols. All rights reserved.
//

#import <Crashlytics/Crashlytics.h>
#import "FLDropboxHelper.h"
#import "FLSettingsViewController.h"

#define APP_KEY @"app_key"
#define APP_SECRET @"app_secret"
#define LAST_LINK_KEY @"LastLinkCopied"
#define PAST_COPIES_KEY @"FilenamesOnceCopied"
#define DROPBOX_ERROR_TEXT @"Dropbox error encountered!"

@interface FLDropboxHelper()

@property (nonatomic) NSArray *fileListing;
@property (nonatomic, strong) void (^linkCompletion)(BOOL);
@property (atomic) NSCache *entityCache;

@end

@implementation FLDropboxHelper

+ (FLDropboxHelper *)sharedHelper
{
    static FLDropboxHelper *helper = nil;
    if (!helper) {
        helper = [[FLDropboxHelper alloc] init];
        // setup dropbox manager
        DBAccountManager *mgr = [[DBAccountManager alloc] initWithAppKey:APP_KEY secret:APP_SECRET];
        [DBAccountManager setSharedManager:mgr];
        if ([mgr linkedAccount] && ![DBFilesystem sharedFilesystem]) {
            [DBFilesystem setSharedFilesystem:[[DBFilesystem alloc] initWithAccount:[mgr linkedAccount]]];
        }
    }
    return helper;
}

- (id)init
{
    self = [super init];
    if (self) {
        self.entityCache = [[NSCache alloc] init];
    }
    return self;
}

- (NSArray *)fileListing
{
    DBFilesystem *fs = [DBFilesystem sharedFilesystem];
    if (!_fileListing && fs) {
        DBError *error = nil;
        NSArray *fl = [fs listFolder:[DBPath root] error:&error];
        if (error) {
            [self handleError:error];
            _fileListing = nil;
        } else {
            // sort by recency of modification
            _fileListing = [fl sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
                NSDate *d1 = ((DBFileInfo *)obj1).modifiedTime;
                NSDate *d2 = ((DBFileInfo *)obj2).modifiedTime;
                return [d2 compare:d1];
            }];
        }
    }
    return _fileListing;
}

#pragma mark - Link & connection management

- (void)handleError:(DBError *)error
{
    DBErrorCode code = error.code;
    CLS_LOG(@"Dropbox error: %ld", (long)code);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.guideView displayError:DROPBOX_ERROR_TEXT];
    });
}

- (BOOL)isLinked
{
    return [[DBAccountManager sharedManager] linkedAccount] != nil;
}

- (void)linkIfUnlinked:(UIViewController *)controller completion:(void (^)(BOOL))completionBlock
{
    if (![self isLinked]) {
        [[DBAccountManager sharedManager] linkFromController:controller];
        self.linkCompletion = completionBlock;
    } else {
        completionBlock(YES);
    }
}

- (BOOL)finishLinking:(NSURL *)url
{
    DBAccount *account = [[DBAccountManager sharedManager] handleOpenURL:url];
    if (account) {
        // setup dropbox filesystem
        DBFilesystem *filesystem = [DBFilesystem sharedFilesystem];
        if (!filesystem) {
            filesystem = [[DBFilesystem alloc] initWithAccount:account];
            [DBFilesystem setSharedFilesystem:filesystem];
        }
    }

    BOOL success = !!account;
    self.linkCompletion(success);
    return success;
}

#pragma mark - Storage management

- (BOOL)canStoreObject:(id)object
{
    FLEntity *entity = [[FLEntity alloc] initWithObject:object];
    if (entity) {
        if ([entity.text isEqualToString:[[NSUserDefaults standardUserDefaults] stringForKey:LAST_LINK_KEY]]) {
            // we've copied this link from the app
            return NO;
        } else if ([self _isFilenameCopied:entity.nameForFile]) {
            // we've copied this entity from the app
            return NO;
        } else {
            DBPath *path = [[DBPath root] childPath:[entity nameForFile]];
            return ![self _isStored:path];
        }
    }
    return YES;
}

- (BOOL)_isStored:(DBPath *)path
{
    DBError *error = nil;
    if (![[DBFilesystem sharedFilesystem] fileInfoForPath:path error:&error]) {
        if (error && error.code != DBErrorParamsNotFound) {
            [self handleError:error];
        } else {
            return NO;
        }
    }
    return YES;
}

- (void)storeEntity:(FLEntity *)entity completion:(void (^)(DBFileInfo *info))completionBlock
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        DBPath *path = [[DBPath root] childPath:[entity nameForFile]];
        DBError *error = nil;
        DBFile *file = [[DBFilesystem sharedFilesystem] createFile:path error:&error];
        DBFileInfo *info = file.info;
        NSData *dataToWrite;
        if (entity.type == TextEntity) {
            dataToWrite = [entity.text dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            NSNumber *quality = [[NSUserDefaults standardUserDefaults] objectForKey:IMAGE_UPLOAD_QUALITY_KEY];
            dataToWrite = UIImageJPEGRepresentation(entity.image, (quality == nil) ? IMAGE_UPLOAD_QUALITY_DEFAULT : quality.floatValue);
        }
        [file writeData:dataToWrite error:&error];
        [file close];
        if (error) {
            [self handleError:error];
        } else {
            [self.entityCache setObject:entity forKey:info];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock((error == nil) ? info : nil);
        });
    });
}

- (FLEntity *)retrieveFile:(DBFileInfo *)fileInfo
{
    // protect from opening a file several times, at the same time
    @synchronized(fileInfo) {
        FLEntity *entity = [self.entityCache objectForKey:fileInfo];
        if (!entity) {
            DBError *error = nil;
            DBFile *file = [[DBFilesystem sharedFilesystem] openFile:fileInfo.path error:&error];
            NSData *fileData = [file readData:&error];
            [file close];

            if (error) {
                [self handleError:error];
            } else {
                UIImage *imgCandidate = [UIImage imageWithData:fileData];
                entity = [[FLEntity alloc] initWithObject:(imgCandidate) ? imgCandidate : [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding]];
                [self.entityCache setObject:entity forKey:fileInfo];
            }
        }
        return entity;
    }
}

- (BOOL)deleteFile:(DBFileInfo *)fileInfo delegate:(id<FLHistoryActionsDelegate>)delegate
{
    DBError *error = nil;
    FLEntity *entity = [self retrieveFile:fileInfo];
    if (entity) {
        BOOL success = [[DBFilesystem sharedFilesystem] deletePath:fileInfo.path error:&error];
        if (error) {
            [self handleError:error];
        }
        if (success) {
            [self _setPastCopiedFile:entity copied:NO];
            [delegate didDeleteFile];
        }
        return success;
    }
    return NO;
}

- (void)copyFile:(DBFileInfo *)fileInfo delegate:(id<FLHistoryActionsDelegate>)delegate
{
    // copy the entity to clipboard
    FLEntity *entity = [[FLDropboxHelper sharedHelper] retrieveFile:fileInfo];
    if (entity) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // slow as balls for big images, do it in the background to not clog up UI
            if (entity.type == PhotoEntity) {
                [UIPasteboard generalPasteboard].image = entity.image;
            } else {
                [UIPasteboard generalPasteboard].string = entity.text;
            }
        });
        [self _setPastCopiedFile:entity copied:YES];
        [delegate didCopyEntity:entity];
    }
}

- (void)copyLinkForFile:(DBFileInfo *)fileInfo delegate:(id<FLHistoryActionsDelegate>)delegate
{
    // copy the shortened DB link to the file at this index path
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = [self _linkForFile:fileInfo];
        if (path) {
            [UIPasteboard generalPasteboard].URL = [NSURL URLWithString:path];
        }
    });
    [delegate didCopyLinkForFile:fileInfo];
}

- (void)_setPastCopiedFile:(FLEntity *)file copied:(BOOL)copied
{
    NSString *fileName = [file nameForFile]; // recalculate for possible scaling
    if ([self _isFilenameCopied:fileName] == copied) {
        return;
    }

    NSMutableArray *pastCopies = [[NSUserDefaults standardUserDefaults] mutableArrayValueForKey:PAST_COPIES_KEY];
    if (pastCopies) {
        if (copied) {
            [pastCopies addObject:fileName];
        } else {
            [pastCopies removeObject:fileName];
        }
    } else if (copied) {
        // don't bother initializing if nothing to store
        pastCopies = [[NSMutableArray alloc] initWithObjects:fileName, nil];
        [[NSUserDefaults standardUserDefaults] setObject:pastCopies forKey:PAST_COPIES_KEY];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)_isFilenameCopied:(NSString *)filename
{
    NSMutableArray *pastCopies = [[NSUserDefaults standardUserDefaults] objectForKey:PAST_COPIES_KEY];
    return [pastCopies containsObject:filename];
}

- (NSString *)_linkForFile:(DBFileInfo *)fileInfo
{
    DBError *error = nil;
    NSString *link = [[DBFilesystem sharedFilesystem] fetchShareLinkForPath:fileInfo.path shorten:YES error:&error];
    if (error) {
        [self handleError:error];
    } else {
        // keep track of this link so we don't try to store the link from the clipboard at next open
        [[NSUserDefaults standardUserDefaults] setObject:link forKey:LAST_LINK_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    return link;
}

@end
