// Copyright 2010-2013 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniFileStore/OFSURL.h>

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#import <MobileCoreServices/MobileCoreServices.h>
#endif
#import <OmniFoundation/OFUTI.h>

RCS_ID("$Id$")

#if 0
NSString * const OFSDocumentStoreFolderPathExtension = @"folder";

BOOL OFSIsFolder(NSURL *URL)
{
    return [[URL pathExtension] caseInsensitiveCompare:OFSDocumentStoreFolderPathExtension] == NSOrderedSame;
}

NSString *OFSFolderNameForFileURL(NSURL *fileURL)
{
    NSURL *containerURL = [fileURL URLByDeletingLastPathComponent];
    if (OFSIsFolder(containerURL))
        return [containerURL lastPathComponent];
    return nil;
}
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
NSString * const OFSDocumentInteractionInboxFolderName = @"Inbox";

BOOL OFSInInInbox(NSURL *url)
{
    // Check to see if the URL directly points to the Inbox.
    if (([[url lastPathComponent] caseInsensitiveCompare:OFSDocumentInteractionInboxFolderName] == NSOrderedSame)) {
        return YES;
    }
    
    // URL does not directly point to Inbox, check if it points to a file directly in the Inbox.
    NSURL *pathURL = [url URLByDeletingLastPathComponent]; // Remove the filename.
    NSString *lastPathComponentString = [pathURL lastPathComponent];
    
    return ([lastPathComponentString caseInsensitiveCompare:OFSDocumentInteractionInboxFolderName] == NSOrderedSame);
}

BOOL OFSIsZipFileType(NSString *uti)
{
    // Check both of the semi-documented system UTIs for zip (in case one goes away or something else weird happens).
    // Also check for a temporary hack UTI we had, in case the local LaunchServices database hasn't recovered.
    return UTTypeConformsTo((__bridge CFStringRef)uti, CFSTR("com.pkware.zip-archive")) ||
    UTTypeConformsTo((__bridge CFStringRef)uti, CFSTR("public.zip-archive")) ||
    UTTypeConformsTo((__bridge CFStringRef)uti, CFSTR("com.omnigroup.zip"));
}
#endif

OFSScanDirectoryFilter OFSScanDirectoryExcludeInboxItemsFilter(void)
{
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    return [^BOOL(NSURL *fileURL){
        // We never want to acknowledge files in the inbox directly. Instead they'll be dealt with when they're handed to us via document interaction and moved.
        return OFSInInInbox(fileURL) == NO;
    } copy];
#else
    return nil; // No Inbox support on the Mac
#endif
};

BOOL OFSShouldIgnoreURLDuringScan(NSURL *fileURL)
{
    if ([[fileURL lastPathComponent] caseInsensitiveCompare:@".DS_Store"] == NSOrderedSame)
        return YES;
    return NO;
}

// We no longer use an NSFileCoordinator when scanning the documents directory. NSFileCoordinator doesn't make writers of documents wait if there is a coordinator of their containing directory, so this doesn't help. We *could*, as we find documents, do a coordinated read on each document to make sure we get its most recent timestamp, but this seems wasteful in most cases.
void OFSScanDirectory(NSURL *directoryURL, BOOL shouldRecurse,
                      OFSScanDirectoryFilter filterBlock,
                      OFSScanPathExtensionIsPackage pathExtensionIsPackage,
                      OFSScanDirectoryItemHandler itemHandler)
{
    OBASSERT(![NSThread isMainThread]);
    
    NSMutableArray *scanDirectoryURLs = [NSMutableArray arrayWithObjects:directoryURL, nil];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    while ([scanDirectoryURLs count] != 0) {
        NSURL *scanDirectoryURL = [scanDirectoryURLs lastObject]; // We're building a set, and it's faster to remove the last object than the first
        [scanDirectoryURLs removeLastObject];
        
        NSError *contentsError = nil;
        NSArray *fileURLs = [fileManager contentsOfDirectoryAtURL:scanDirectoryURL includingPropertiesForKeys:[NSArray arrayWithObject:NSURLIsDirectoryKey] options:0 error:&contentsError];
        if (!fileURLs)
            NSLog(@"Unable to scan documents in %@: %@", scanDirectoryURL, [contentsError toPropertyList]);
        
        for (__strong NSURL *fileURL in fileURLs) {
            // Built-in filter
            if (OFSShouldIgnoreURLDuringScan(fileURL))
                continue;
            
            // We do NOT use UTIs for determining if a folder is a file package (meaning we should treat it as a document). We might not have UTIs registered in this app for all the document types that might be present (a newer app version might have placed something in the container that an older version doesn't understand, and Launch Service might go insane and not even correctly report the UTIs in our Info.plist). Instead, any folder that has an extension that isn't OFSDocumentStoreFolderPathExtension is considered a package.
            // This does mean that folders *must* have the special extension, or no extension, or we'll treat them like file packages. This may be why iWork uses this approach, otherwise a user might create a folder called "2012.01 Presentations" and suddenly the app might think it was a file package from some future version.
            NSNumber *isDirectoryValue = nil;
            NSError *resourceError = nil;
            if (![fileURL getResourceValue:&isDirectoryValue forKey:NSURLIsDirectoryKey error:&resourceError])
                NSLog(@"Unable to determine if %@ is a directory: %@", fileURL, [resourceError toPropertyList]);
            
            // NSFileManager hands back non-standardized URLs even if the input is standardized.
            OBASSERT(isDirectoryValue);
            BOOL isDirectory = [isDirectoryValue boolValue];
            fileURL = [scanDirectoryURL URLByAppendingPathComponent:[fileURL lastPathComponent] isDirectory:isDirectory];
            
            if (filterBlock && !filterBlock(fileURL))
                continue;
            
            NSString *pathExtension = [fileURL pathExtension];
            if (isDirectory) {
                BOOL isPackage;
                if ([NSString isEmptyString:pathExtension])
                    isPackage = NO;
                else if (pathExtensionIsPackage) {
                    isPackage = pathExtensionIsPackage(pathExtension);
                } else {
                    OBASSERT_NOT_REACHED("Cannot tell if a path extension is a package... should we allow this at all?");
                    isPackage = NO;
                }
                
                if (isPackage) {
                    // Fall through and treat it as an item
                } else {
                    // Should be treated as a folder
                    if (shouldRecurse)
                        [scanDirectoryURLs addObject:fileURL];
                    continue; // We don't want to create an item if the fileURL points to a directory.
                }
            }
            
            itemHandler(fileManager, fileURL);
        }
    }
}

OFSScanPathExtensionIsPackage OFSIsPackageWithKnownPackageExtensions(NSSet *packageExtensions)
{
    // Don't cache the list of package extensions forever. Installing a new application between sync operations might make a file that previously existed turn into a package.
    NSMutableDictionary *extensionToIsPackage = [NSMutableDictionary new];
    
    OFSScanPathExtensionIsPackage isPackage = ^BOOL(NSString *pathExtension){
        pathExtension = [pathExtension lowercaseString];
        
        // Our UTTypeConformsTo() of local types below would hopefully catch this, but it might not since it uses depends on LaunchServices registration. Thus, it will only catch types that LaunchServices really knows about (whereas we fill in _localPackagePathExtensions by inspecting our UTI definitions directly).
        if ([packageExtensions member:pathExtension])
            return YES;
                
        NSNumber *cachedValue = extensionToIsPackage[pathExtension];
        if (cachedValue)
            return [cachedValue boolValue];
        
        __block BOOL foundPackage = NO;
        OFUTIEnumerateKnownTypesForTagPreferringNative((NSString *)kUTTagClassFilenameExtension, pathExtension, nil/*conformingToUTIOrNil*/, ^(NSString *typeIdentifier, BOOL *stop){
            // We check conformance here rather than passing in kUTTypePackage to OFUTIEnumerateKnownTypesForTagPreferringNative. The underlying UTTypeCreateAllIdentifiersForTag will *generate* a dynamic type that conforms to what we pass in instead of just returning an empty array.
            if (UTTypeConformsTo((__bridge CFStringRef)typeIdentifier, kUTTypePackage)) {
                foundPackage = YES;
                *stop = YES;
            }
        });
        
        extensionToIsPackage[pathExtension] = @(foundPackage);
        return foundPackage;
    };
    
    return [isPackage copy];
}

BOOL OFSGetBoolResourceValue(NSURL *url, NSString *key, BOOL *outValue, NSError **outError)
{
    NSError *error = nil;
    NSNumber *numberValue = nil;
    if (![url getResourceValue:&numberValue forKey:key error:&error]) {
        NSLog(@"Error getting resource key %@ for %@: %@", key, url, [error toPropertyList]);
        if (outError)
            *outError = error;
        return NO;
    }
    
    *outValue = [numberValue boolValue];
    return YES;
}


static void _assertPlainURL(NSURL *url)
{
    OBPRECONDITION([NSString isEmptyString:[url fragment]]);
    OBPRECONDITION([NSString isEmptyString:[url parameterString]]);
    OBPRECONDITION([NSString isEmptyString:[url query]]);
}

static NSString *_standardizedPathForURL(NSURL *url)
{
    OBASSERT([url isFileURL]);
    NSString *urlPath = [[url absoluteURL] path];
    
    NSString *path = [[urlPath stringByResolvingSymlinksInPath] stringByStandardizingPath];
    
    // In some cases this doesn't normalize /private/var/mobile and /var/mobile to the same thing.
    path = [path stringByRemovingPrefix:@"/var/mobile/"];
    path = [path stringByRemovingPrefix:@"/private/var/mobile/"];
    
    return path;
}

BOOL OFSURLContainsURL(NSURL *containerURL, NSURL *url)
{
    _assertPlainURL(url);
    _assertPlainURL(containerURL);

    if (!containerURL)
        return NO;
    
    // -[NSFileManager contentsOfDirectoryAtURL:...], when given something in file://localhost/var/mobile/... will return file URLs with non-standarized paths like file://localhost/private/var/mobile/...  Terrible.
    OBASSERT([containerURL isFileURL]);
    
    NSString *urlPath = _standardizedPathForURL(url);
    NSString *containerPath = _standardizedPathForURL(containerURL);
    
    if (![containerPath hasSuffix:@"/"])
        containerPath = [containerPath stringByAppendingString:@"/"];
    
    return [urlPath hasPrefix:containerPath];
}

NSString *OFSFileURLRelativePath(NSURL *baseURL, NSURL *fileURL)
{
    _assertPlainURL(fileURL);
    _assertPlainURL(baseURL);
    OBPRECONDITION([[[fileURL absoluteURL] path] hasPrefix:[[baseURL absoluteURL] path]]); // Can't compare the prefix in URL encoding since the % encoding can have upper/lowercase differences.
    
    NSString *localBasePath = [[baseURL absoluteURL] path];
    if (![localBasePath hasSuffix:@"/"])
        localBasePath = [localBasePath stringByAppendingString:@"/"];
    
    NSString *localAbsolutePath = [[fileURL absoluteURL] path];
    OBASSERT([localAbsolutePath hasPrefix:localBasePath]);
    
    NSString *localRelativePath = [[localAbsolutePath stringByRemovingPrefix:localBasePath] stringByRemovingSuffix:@"/"];
    OBASSERT(![localRelativePath hasPrefix:@"/"]);
    
    return localRelativePath;
}

BOOL OFSURLIsStandardized(NSURL *url)
{
    OBPRECONDITION([url isFileURL]);
    OBPRECONDITION([url checkResourceIsReachableAndReturnError:NULL]); // Don't ask to standardize URLs that don't exist -- -URLByStandardizingPath returns incorrect results in that case
    return OFSURLEqualsURL([url URLByStandardizingPath], url);
}


NSURL *OFSURLRelativeToDirectoryURL(NSURL *baseURL, NSString *quotedFileName)
{
    if (!baseURL || !quotedFileName)
        return nil;
    
    NSMutableString *urlString = [[baseURL absoluteString] mutableCopy];
    NSRange pathRange = OFSURLRangeOfPath(urlString);
    
    if ([urlString rangeOfString:@"/" options:NSAnchoredSearch|NSBackwardsSearch range:pathRange].length == 0) {
        [urlString insertString:@"/" atIndex:NSMaxRange(pathRange)];
        pathRange.length ++;
    }
    
    [urlString insertString:quotedFileName atIndex:NSMaxRange(pathRange)];
    
    NSURL *newURL = [NSURL URLWithString:urlString];
    return newURL;
}

NSURL *OFSDirectoryURLForURL(NSURL *url)
{
    NSString *urlString = [url absoluteString];
    NSRange lastComponentRange;
    unsigned trailingSlashLength;
    if (!OFSURLRangeOfLastPathComponent(urlString, &lastComponentRange, &trailingSlashLength))
        return url;
    
    NSString *parentURLString = [urlString substringToIndex:lastComponentRange.location];
    NSURL *parentURL = [NSURL URLWithString:parentURLString];
    return parentURL;
}

NSURL *OFSURLWithTrailingSlash(NSURL *baseURL)
{
    if (baseURL == nil)
        return nil;
    
    if ([[baseURL path] hasSuffix:@"/"])
        return baseURL;
    
    NSString *baseURLString = [baseURL absoluteString];
    NSRange pathRange = OFSURLRangeOfPath(baseURLString);
    
    if (pathRange.length && [baseURLString rangeOfString:@"/" options:NSAnchoredSearch|NSBackwardsSearch range:pathRange].length > 0)
        return baseURL;
    
    NSMutableString *newString = [baseURLString mutableCopy];
    [newString insertString:@"/" atIndex:NSMaxRange(pathRange)];
    NSURL *newURL = [NSURL URLWithString:newString];
    
    return newURL;
}

BOOL OFSURLEqualsURL(NSURL *URL1, NSURL *URL2)
{
    if (URL1 == URL2)
        return YES;
    if (!URL1 || !URL2)
        return NO;
    
    URL1 = [URL1 absoluteURL];
    URL2 = [URL2 absoluteURL];
    
    // This assumes that -path keeps the trailing slash and that we want slash differences to be significant (might want to change that).
    if (OFNOTEQUAL([URL1 path], [URL2 path]))
        return NO;
    
    // Some other bits should maybe be URL-decoded before comparison too. Also, we should maybe just assert that all the goofy stuff is nil for OFS-used URLs.
    return
    OFISEQUAL(URL1.scheme, URL2.scheme) &&
    OFISEQUAL(URL1.port, URL2.port) &&
    OFISEQUAL(URL1.user, URL2.user) &&
    OFISEQUAL(URL1.password, URL2.password) &&
    OFISEQUAL(URL1.fragment, URL2.fragment) &&
    OFISEQUAL(URL1.parameterString, URL2.parameterString) &&
    OFISEQUAL(URL1.query, URL2.query);
}

BOOL OFSURLEqualToURLIgnoringTrailingSlash(NSURL *URL1, NSURL *URL2)
{
    if (OFSURLEqualsURL(URL1, URL2))
        return YES;
    return OFSURLEqualsURL(OFSURLWithTrailingSlash(URL1), OFSURLWithTrailingSlash(URL2));
}

NSURL *OFSURLWithNameAffix(NSURL *baseURL, NSString *quotedSuffix, BOOL addSlash, BOOL removeSlash)
{
    OBASSERT(![quotedSuffix containsString:@"/"]);
    OBASSERT(!(addSlash && removeSlash));
    
    NSMutableString *urlString = [[baseURL absoluteString] mutableCopy];
    NSRange pathRange = OFSURLRangeOfPath(urlString);
    
    // Can't apply an affix to an empty name. Well, we could, but that would just push the problem off to some other part of XMLData.
    if (!pathRange.length) {
        return nil;
    }
    
    NSRange trailingSlash = [urlString rangeOfString:@"/" options:NSAnchoredSearch|NSBackwardsSearch range:pathRange];
    if (trailingSlash.length) {
        if (removeSlash)
            [urlString replaceCharactersInRange:trailingSlash withString:quotedSuffix];
        else
            [urlString insertString:quotedSuffix atIndex:trailingSlash.location];
    } else {
        if (addSlash)
            [urlString insertString:@"/" atIndex:NSMaxRange(pathRange)];
        [urlString insertString:quotedSuffix atIndex:NSMaxRange(pathRange)];
    }
    // pathRange is inaccurate now, but we don't use it again
    
    NSURL *newURL = [NSURL URLWithString:urlString];
    return newURL;
}

BOOL OFSURLRangeOfLastPathComponent(NSString *urlString, NSRange *lastComponentRange, unsigned *andTrailingSlash)
{
    if (!urlString)
        return NO;
    
    NSRange pathRange = OFSURLRangeOfPath(urlString);
    if (!pathRange.length)
        return NO;
    
    NSRange trailingSlash = [urlString rangeOfString:@"/" options:NSAnchoredSearch|NSBackwardsSearch range:pathRange];
    NSRange previousSlash;
    if (trailingSlash.length) {
        OBINVARIANT(NSMaxRange(trailingSlash) == NSMaxRange(pathRange));
        previousSlash = [urlString rangeOfString:@"/"
                                         options:NSBackwardsSearch
                                           range:(NSRange){ pathRange.location, trailingSlash.location - pathRange.location }];
        
        if (previousSlash.length && !(NSMaxRange(previousSlash) <= trailingSlash.location)) {
            // Double trailing slash is a syntactic weirdness we don't have a good way to handle.
            return NO;
        }
    } else {
        previousSlash = [urlString rangeOfString:@"/" options:NSBackwardsSearch range:pathRange];
    }
    
    if (!previousSlash.length)
        return NO;
    
    lastComponentRange->location = NSMaxRange(previousSlash);
    lastComponentRange->length = NSMaxRange(pathRange) - NSMaxRange(previousSlash) - trailingSlash.length;
    if (andTrailingSlash)
        *andTrailingSlash = (unsigned)trailingSlash.length;
    
    return YES;
}

NSRange OFSURLRangeOfPath(NSString *rfc1808URL)
{
    if (!rfc1808URL) {
        return (NSRange){NSNotFound, 0};
    }
    
    NSRange colon = [rfc1808URL rangeOfString:@":"];
    if (!colon.length) {
        return (NSRange){NSNotFound, 0};
    }
    
    NSUInteger len = [rfc1808URL length];
#define Suffix(pos) (NSRange){(pos), len - (pos)}
    
    // The fragment identifier is significant anywhere after the colon (and forbidden before the colon, but whatever)
    NSRange terminator = [rfc1808URL rangeOfString:@"#" options:0 range:Suffix(NSMaxRange(colon))];
    if (terminator.length)
        len = terminator.location;
    
    // According to RFC1808, the ? and ; characters do not have special meaning within the host specifier.
    // But the host specifier is an optional part (again, according to the RFC), so we need to only optionally skip it.
    NSRange pathRange;
    NSRange slashes = [rfc1808URL rangeOfString:@"//" options:NSAnchoredSearch range:Suffix(NSMaxRange(colon))];
    if (slashes.length) {
        NSRange firstPathSlash = [rfc1808URL rangeOfString:@"/" options:0 range:Suffix(NSMaxRange(slashes))];
        if (!firstPathSlash.length) {
            // A URL of the form foo://bar.com
            return (NSRange){ len, 0 };
        } else {
            pathRange.location = firstPathSlash.location;
        }
    } else {
        // The first character after the colon may or may not be a slash; RFC1808 allows relative paths there.
        pathRange.location = NSMaxRange(colon);
    }
    
    pathRange.length = len - pathRange.location;
    
    // Strip any query
    terminator = [rfc1808URL rangeOfString:@"?" options:0 range:pathRange];
    if (terminator.length)
        pathRange.length = terminator.location - pathRange.location;
    
    // Strip any parameter-string
    [rfc1808URL rangeOfString:@";" options:0 range:pathRange];
    if (terminator.length)
        pathRange.length = terminator.location - pathRange.location;
    
    return pathRange;
}


// This is a sort of simple 3-way-merge of URLs which we use to rewrite the Destination: header of a MOVE request if the server responds with a redirect of the source URL.
// Generally we're just MOVEing something to rename it within its containing collection. So this function checks to see if that is true, and if so, returns a new Destination: URL which represents the same rewrite within the new collection pointed to by the redirect.
// For more complicated situations, this function just gives up and returns nil; the caller will need to have some way to handle that.
NSString *OFSURLAnalogousRewrite(NSURL *oldSourceURL, NSString *oldDestination, NSURL *newSourceURL)
{
    if ([oldDestination hasPrefix:@"/"])
        oldDestination = [[NSURL URLWithString:oldDestination relativeToURL:oldSourceURL] absoluteString];
    NSString *oldSource = [oldSourceURL absoluteString];
    
    NSRange oldSourceLastComponent, oldDestinationLastComponent, newSourceLastComponent;
    unsigned oldSourceSlashy, oldDestinationSlashy, newSourceSlashy;
    if (!OFSURLRangeOfLastPathComponent(oldDestination, &oldDestinationLastComponent, &oldDestinationSlashy) ||
        !OFSURLRangeOfLastPathComponent(oldSource, &oldSourceLastComponent, &oldSourceSlashy)) {
        // Can't parse something.
        return nil;
    }
    
    if (![[oldSource substringToIndex:oldSourceLastComponent.location] isEqualToString:[oldDestination substringToIndex:oldDestinationLastComponent.location]]) {
        // The old source and destination URLs differ in more than just their final path component. Not obvious how to rewrite.
        // (We should maybe be checking the span after the last path component as well, but that's going to be an empty string in any reasonable situation)
        return nil;
    }
    
    NSString *newSource = [newSourceURL absoluteString];
    if (!OFSURLRangeOfLastPathComponent(newSource, &newSourceLastComponent, &newSourceSlashy)) {
        // Can't parse something.
        return nil;
    }
    
    if (![[oldSource substringWithRange:oldSourceLastComponent] isEqualToString:[newSource substringWithRange:newSourceLastComponent]]) {
        // The server's redirect changes the final path component, which is the same thing our MOVE is changing. Flee!
        return nil;
    }
    
    NSMutableString *newDestination = [newSource mutableCopy];
    NSString *newLastComponent = [oldDestination substringWithRange:oldDestinationLastComponent];
    if (!oldSourceSlashy && oldDestinationSlashy && !newSourceSlashy) {
        // We were adding a trailing slash; keep doing so.
        newLastComponent = [newLastComponent stringByAppendingString:@"/"];
    } else if (oldSourceSlashy && !oldDestinationSlashy && newSourceSlashy) {
        // We were removing a trailing slash. Extend the range so that we delete the new URL's trailing slash as well.
        newSourceLastComponent.length += newSourceSlashy;
    }
    [newDestination replaceCharactersInRange:newSourceLastComponent withString:newLastComponent];
    
    return newDestination;
}

