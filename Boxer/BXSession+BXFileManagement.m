/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXSession+BXFileManagement.h"
#import "BXSessionPrivate.h"
#import "BXFileTypes.h"
#import "BXBaseAppController+BXSupportFiles.h"
#import "NSAlert+BXAlert.h"
#import "NSError+ADBErrorHelpers.h"
#import "BXCloseAlert.h"

#import "BXEmulator+BXDOSFileSystem.h"
#import "BXDOSWindowController.h"
#import "BXEmulatorErrors.h"
#import "BXEmulator+BXShell.h"
#import "ADBShadowedFilesystem.h"
#import "ADBBinCueImage.h"
#import "BXGamebox.h"
#import "BXDrive.h"
#import "BXDrivesInUseAlert.h"
#import "BXGameProfile.h"
#import "BXDriveImport.h"
#import "ADBScanOperation.h"

#import "NSWorkspace+ADBMountedVolumes.h"
#import "NSWorkspace+ADBFileTypes.h"
#import "NSWorkspace+BXExecutableTypes.h"
#import "NSString+ADBPaths.h"
#import "NSURL+ADBFilesystemHelpers.h"
#import "NSFileManager+ADBTemporaryFiles.h"
#import "RegexKitLite.h"
#import "BXBezelController.h"
#import "ADBUserNotificationDispatcher.h"
#import "BXInspectorController.h"


//Boxer will delay its handling of volume mount notifications by this many seconds,
//to allow multipart volumes to finish mounting properly
#define BXVolumeMountDelay 1.0


NSString * const BXGameStateGameNameKey = @"BXGameName";
NSString * const BXGameStateGameIdentifierKey = @"BXGameIdentifier";
NSString * const BXGameStateEmulatorVersionKey = @"BXEmulatorVersion";


//The methods in this category are not intended to be called outside BXSession.
@interface BXSession (BXFileManagerPrivate)

- (void) _volumeDidMount:		(NSNotification *)theNotification;
- (void) _volumeWillUnmount:	(NSNotification *)theNotification;
- (void) _filesystemDidChange:	(NSNotification *)theNotification;

- (void) _handleVolumeDidMount: (NSNotification *)theNotification;

- (void) _applicationDidBecomeActive: (NSNotification *)theNotification;

@end


@implementation BXSession (BXFileManagement)

#pragma mark - Helper class methods

+ (NSURL *) preferredMountPointForURL: (NSURL *)URL
{	
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	
	//If the URL points to a disk image, use that as the mount point.
    if ([URL matchingFileType: [BXFileTypes mountableImageTypes]] != nil)
        return URL;
    
	//If the URL is (itself or inside) a gamebox or mountable folder, use that as the mount point.
	NSURL *mountableContainer = [workspace nearestAncestorOfURL: URL matchingTypes: [self.class preferredMountPointTypes]];
    if (mountableContainer)
        return mountableContainer;
	
	//Check what kind of volume the file is on
	NSURL *volumeURL = [URL resourceValueForKey: NSURLVolumeURLKey];
	NSString *volumeType = [workspace typeOfVolumeAtURL: URL];
    
	//If it's on a data CD volume or floppy volume, use the base folder of the volume as the mount point
	if ([volumeType isEqualToString: ADBDataCDVolumeType] || [workspace isFloppyVolumeAtURL: URL])
	{
		return volumeURL;
	}
    
	//If it's on an audio CD, hunt around for a corresponding data CD volume and use that as the mount point if found
	else if ([volumeType isEqualToString: ADBAudioCDVolumeType])
	{
		NSURL *dataVolumeURL = [workspace dataVolumeOfAudioCDAtURL: volumeURL];
		if (dataVolumeURL)
            return dataVolumeURL;
	}
	
	//If we get this far, then treat the path as a regular file or folder.
	//If the path is a folder, use it directly as the mount point...
    if (URL.isDirectory)
        return URL;
	
	//...otherwise use the path's parent folder.
	else
        return URL.URLByDeletingLastPathComponent;
}

+ (NSURL *) gameDetectionPointForURL: (NSURL *)URL
              shouldSearchSubfolders: (BOOL *)shouldRecurse
{
	if (shouldRecurse)
        *shouldRecurse = YES;
    
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	
	//If the file is inside a gamebox (first in preferredMountPointTypes) then search from that;
	//If the file is inside a mountable folder (second) then search from that.
	for (NSString *type in @[BXGameboxType, BXMountableFolderType])
	{
        NSURL *parentContainer = [workspace nearestAncestorOfURL: URL matchingTypes: [NSSet setWithObject: type]];
		if (parentContainer)
            return parentContainer;
	}
	
	//Failing that, check what kind of volume the file is on.
	NSURL *volumeURL = [URL resourceValueForKey: NSURLVolumeURLKey];
	NSString *volumeType = [workspace typeOfVolumeAtURL: URL];
	
	//If it's on a data CD volume or floppy volume, scan from the base folder of the volume
	if ([volumeType isEqualToString: ADBDataCDVolumeType] || [workspace isFloppyVolumeAtURL: volumeURL])
	{
		return volumeURL;
	}
	//If it's on an audio CD, hunt around for a corresponding data CD volume and use that if found
	else if ([volumeType isEqualToString: ADBAudioCDVolumeType])
	{
		NSURL *dataVolumeURL = [workspace dataVolumeOfAudioCDAtURL: volumeURL];
		if (dataVolumeURL) return dataVolumeURL;
	}
	
	//If we get this far, then treat the path as a regular file or folder and recommend against
	//searching subfolders (since the file hierarchy could be potentially huge.)
	if (shouldRecurse)
        *shouldRecurse = NO;
	
	//If the path is a folder, search it directly...
	if (URL.isDirectory)
        return URL;
	
	//...otherwise search the path's parent folder.
	else
        return URL.URLByDeletingLastPathComponent;
}


#pragma mark - Filetype helper methods

+ (NSSet *) preferredMountPointTypes
{
	static NSSet *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = [[NSSet alloc] initWithObjects:
                 BXGameboxType,
                 BXMountableFolderType,
                 nil];
    });
	return types;
}

+ (NSSet *) separatelyMountedTypes
{
	static NSSet *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSSet *imageTypes	= [BXFileTypes mountableImageTypes];
        NSSet *folderTypes	= [self preferredMountPointTypes];
        types = [imageTypes setByAddingObjectsFromSet: folderTypes];
    });
	return types;
}

+ (NSSet *) automountedVolumeFormats
{
	static NSSet *formats;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formats = [[NSSet alloc] initWithObjects:
         ADBDataCDVolumeType,
         ADBAudioCDVolumeType,
         ADBFATVolumeType,
         nil];
    });
	return formats;
}

+ (NSSet *) hiddenFilenamePatterns
{
	static NSSet *exclusions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exclusions = [[NSSet alloc] initWithObjects:
                      [BXConfigurationFileName stringByAppendingPathExtension: BXConfigurationFileExtension],
                      [BXGameInfoFileName stringByAppendingPathExtension: BXGameInfoFileExtension],
                      BXTargetSymlinkName,
                      @"Icon\r",
                      nil];
    });
    
	return exclusions;
}


#pragma mark - Drive shadowing

- (BOOL) _shouldShadowDrive: (BXDrive *)drive
{
    
    // Never shadow
    return NO;
    
//    //Don't shadow if we're not running a gamebox.
//    if (!self.hasGamebox)
//        return NO;
//
//    //Don't shadow read-only drives or drives that are located outside the gamebox.
//    if (drive.isReadOnly || ![self driveIsBundled: drive])
//        return NO;
//
//    return YES;
}

- (NSURL *) currentGameStateURL
{
    if (self.hasGamebox)
    {
        NSURL *stateURL = [(BXBaseAppController *)[NSApp delegate] gameStatesURLForGamebox: self.gamebox
                                                                         creatingIfMissing: NO
                                                                                     error: NULL];
        
        return [stateURL URLByAppendingPathComponent: @"Current.boxerstate"];
    }
    else
    {
        return nil;
    }
}

- (NSURL *) shadowURLForDrive: (BXDrive *)drive
{
    if ([self _shouldShadowDrive: drive])
    {
        NSURL *stateURL = self.currentGameStateURL;
        if (stateURL)
        {
            NSString *driveName;
            //If the drive is identical to the gamebox itself (old-style gameboxes)
            //then map it to a different name.
            if ([drive.sourceURL isEqual: self.gamebox.resourceURL])
                driveName = @"C.harddisk";
            //Otherwise, use the original filename of the gamebox.
            else
                driveName = drive.sourceURL.lastPathComponent;
            
            NSURL *driveShadowURL = [stateURL URLByAppendingPathComponent: driveName];
            
            return driveShadowURL;
        }
    }
    return nil;
}

- (BOOL) hasShadowedChanges
{
    for (BXDrive *drive in self.allDrives)
    {
        if ([drive.shadowURL checkResourceIsReachableAndReturnError: NULL])
            return YES;
    }
    return NO;
}

- (BOOL) revertChangesForDrive: (BXDrive *)drive error: (NSError **)outError
{
    ADBShadowedFilesystem *filesystem = (ADBShadowedFilesystem *)drive.filesystem;
    if ([filesystem respondsToSelector: @selector(clearShadowContentsForPath:error:)])
    {
        //Release the file resources of any drive that we're about to revert.
        //If we can't let go of them, bail out.
        BOOL releasedResources = [self.emulator releaseResourcesForDrive: drive error: outError];
        if (!releasedResources)
            return NO;
        
        return [filesystem clearShadowContentsForPath: @"/" error: outError];
    }
    //If the drive does not support reversion, pretend the operation was successful.
    else
    {
        return YES;
    }
}

- (BOOL) revertChangesForAllDrivesAndReturnError: (NSError **)outError
{
    for (BXDrive *drive in self.allDrives)
    {
        BOOL reverted = [self revertChangesForDrive: drive error: outError];
        if (!reverted) return NO;
    }
    return YES;
}

- (BOOL) mergeChangesForDrive: (BXDrive *)drive error: (NSError **)outError
{
    ADBShadowedFilesystem *filesystem = (ADBShadowedFilesystem *)drive.filesystem;
    if ([filesystem respondsToSelector: @selector(mergeShadowContentsForPath:error:)])
    {
        //Release the file resources of any drive that we're about to merge.
        //If we can't let go of them, bail out.
        BOOL releasedResources = [self.emulator releaseResourcesForDrive: drive error: outError];
        if (!releasedResources)
            return NO;
        
        return [filesystem mergeShadowContentsForPath: @"/" error: outError];
    }
    //If the drive does not support merging, pretend the operation was successful.
    else
    {
        return YES;
    }
}

- (BOOL) mergeChangesForAllDrivesAndReturnError: (NSError **)outError
{
    for (BXDrive *drive in self.allDrives)
    {
        BOOL merged = [self mergeChangesForDrive: drive error: outError];
        if (!merged) return NO;
    }
    return YES;
}

- (BOOL) isValidGameStateAtURL: (NSURL *)stateURL error: (NSError **)outError
{
    if (![stateURL checkResourceIsReachableAndReturnError: outError])
    {
        return NO;
    }
    
    if (!self.hasGamebox)
    {
        if (outError)
        {
            *outError = [BXSessionError errorWithDomain: BXSessionErrorDomain
                                                   code: BXGameStateUnsupported
                                               userInfo: @{ NSURLErrorKey: stateURL }];
        }
        return NO;
    }
    
    //Check the metadata of the bundle to ensure that it is actually a match for the current gamebox.
    NSDictionary *stateInfo = [self infoForGameStateAtURL: stateURL];
    NSString *gameIdentifier = [stateInfo objectForKey: BXGameStateGameIdentifierKey];
    
    if (![gameIdentifier isEqualToString: self.gamebox.gameIdentifier])
    {
        if (outError)
        {
            *outError = [BXGameStateGameboxMismatchError errorWithStateURL: stateURL
                                                                   gamebox: self.gamebox
                                                                  userInfo: nil];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL) _copyGameStateFromURL: (NSURL *)sourceURL toURL: (NSURL *)destinationURL outError: (NSError **)outError
{
    NSURL *destinationBaseURL = destinationURL.URLByDeletingLastPathComponent;
    
    NSFileManager *manager = [NSFileManager defaultManager];
    
    //Ensure the destination folder exists before we start.
    BOOL destinationExists = [manager createDirectoryAtURL: destinationBaseURL
                               withIntermediateDirectories: YES
                                                attributes: nil
                                                     error: outError];
    if (!destinationExists) return NO;
    
    //Make a temporary directory into which we can copy the new state before replacing any original.
    NSURL *tempBaseURL = [manager URLForDirectory: NSItemReplacementDirectory
                                         inDomain: NSUserDomainMask
                                appropriateForURL: destinationBaseURL
                                           create: YES
                                            error: outError];
    if (!tempBaseURL) return NO;
    
    //Copy the state file to the temporary location.
    NSURL *tempURL = [tempBaseURL URLByAppendingPathComponent: destinationURL.lastPathComponent];
    BOOL copied = [manager copyItemAtURL: sourceURL toURL: tempURL error: outError];
    if (!copied) return NO;
    
    //Finally, replace any original state with the new state.
    return [manager replaceItemAtURL: destinationURL
                       withItemAtURL: tempURL
                      backupItemName: nil
                             options: 0
                    resultingItemURL: NULL
                               error: outError];
}

- (BOOL) importGameStateFromURL: (NSURL *)sourceURL error: (NSError **)outError
{
    if (![self isValidGameStateAtURL: sourceURL error: outError])
        return NO;
    
    NSURL *destinationURL = self.currentGameStateURL;
    
    return [self _copyGameStateFromURL: sourceURL toURL: destinationURL outError: outError];
}

- (BOOL) exportGameStateToURL: (NSURL *)destinationURL error: (NSError **)outError
{
    NSURL *sourceURL = self.currentGameStateURL;
    
    //Ensure our game state has the latest metadata before copying
    //(this is otherwise written on session exit.)
    [self _updateInfoForGameStateAtURL: sourceURL];
    
    return [self _copyGameStateFromURL: sourceURL toURL: destinationURL outError: outError];
}

- (NSDictionary *) infoForGameStateAtURL: (NSURL *)stateURL
{
    NSURL *plistURL = [stateURL URLByAppendingPathComponent: @"Info.plist"];
    return [NSDictionary dictionaryWithContentsOfURL: plistURL];
}

- (BOOL) setInfo: (NSDictionary *)info forGameStateAtURL: (NSURL *)stateURL
{
    NSURL *plistURL = [stateURL URLByAppendingPathComponent: @"Info.plist"];
    BOOL stateExists = [[NSFileManager defaultManager] createDirectoryAtURL: stateURL
                                                withIntermediateDirectories: YES
                                                                 attributes: NULL
                                                                      error: NULL];
    if (stateExists)
    {
        return [info writeToURL: plistURL atomically: YES];
    }
    return stateExists;
}

- (void) _updateInfoForGameStateAtURL: (NSURL *)stateURL
{
    NSAssert(stateURL != nil, @"No game state specified.");
    NSAssert(self.hasGamebox, @"_updateInfoForGameStateAtURL called on a session that has no gamebox.");
    
    NSDictionary *originalData = [self infoForGameStateAtURL: stateURL];
    NSMutableDictionary *newData = [NSMutableDictionary dictionaryWithDictionary: originalData];
    [newData setObject: self.gamebox.gameName forKey: BXGameStateGameNameKey];
    [newData setObject: self.gamebox.gameIdentifier forKey: BXGameStateGameIdentifierKey];
    [newData setObject: [BXBaseAppController buildNumber] forKey: BXGameStateEmulatorVersionKey];
    
    [self setInfo: newData forGameStateAtURL: stateURL];
}


#pragma mark -
#pragma mark Drive status

- (BOOL) allowsDriveChanges
{
    return !([(BXBaseAppController *)[NSApp delegate] isStandaloneGameBundle]);
}

- (NSArray *) allDrives
{
    NSMutableArray *allDrives = [NSMutableArray arrayWithCapacity: 10];
    NSArray *sortedLetters = [self.drives.allKeys sortedArrayUsingSelector: @selector(compare:)];
    for (NSString *letter in sortedLetters)
    {
        NSArray *queue = [self.drives objectForKey: letter];
        [allDrives addObjectsFromArray: queue];
    }
    return allDrives;
}

- (NSArray *) mountedDrives
{
    return self.emulator.mountedDrives;
}

- (BOOL) hasDriveQueues
{
    for (NSArray *queue in self.drives.objectEnumerator)
    {
        if (queue.count > 1)
            return YES;
    }
    return NO;
}

+ (NSSet *) keyPathsForValuesAffectingHasDriveQueues
{
    return [NSSet setWithObject: @"drives"];
}

+ (NSSet *) keyPathsForValuesAffectingAllDrives
{
    return [NSSet setWithObject: @"drives"];
}

+ (NSSet *) keyPathsForValuesAffectingMountedDrives
{
    return [NSSet setWithObject: @"emulator.mountedDrives"];
}

- (BOOL) driveIsMounted: (BXDrive *)drive
{
    return ([self.mountedDrives containsObject: drive]);
}


#pragma mark -
#pragma mark Drive queuing

- (void) enqueueDrive: (BXDrive *)drive
{
    NSString *letter = drive.letter;
    NSAssert1(letter != nil, @"Drive %@ passed to enqueueDrive had no letter assigned.", drive);
    
    [self willChangeValueForKey: @"drives"];
    NSMutableArray *queue = [self.drives objectForKey: letter];
    if (!queue)
    {
        queue = [NSMutableArray arrayWithObject: drive];
        [_drives setObject: queue forKey: letter];
    }
    else if (![queue containsObject: drive])
    {
        [queue addObject: drive];
    }
    
    [self didChangeValueForKey: @"drives"];
}

- (void) dequeueDrive: (BXDrive *)drive
{
    //If the specified drive is currently being imported, then refuse to remove
    //it from the queue: we don't want it to disappear from the UI until we're
    //good and ready.
    //TODO: expand this to prevent dequeuing drives that are currently mounted
    //or that should not be removed for other reasons.
    if ([self activeImportOperationForDrive: drive]) return;
    
    NSString *letter = drive.letter;
    NSAssert1(letter != nil, @"Drive %@ passed to dequeueDrive had no letter assigned.", drive);
    
    [self willChangeValueForKey: @"drives"];
    [[self.drives objectForKey: letter] removeObject: drive];
    [self didChangeValueForKey: @"drives"];
    
}

- (void) replaceQueuedDrive: (BXDrive *)oldDrive
                  withDrive: (BXDrive *)newDrive
{
    NSString *letter = newDrive.letter;
    NSAssert1(letter != nil, @"Drive %@ passed to replaceQueuedDrive:withDrive: had no letter assigned.", newDrive);
    
    NSMutableArray *queue = [self.drives objectForKey: letter];
    NSUInteger oldDriveIndex = [queue indexOfObject: oldDrive];
    
    //If there was no queue to start with, or the old drive wasn't queued,
    //then just queue the new drive normally.
    if (!queue || oldDriveIndex == NSNotFound) [self enqueueDrive: newDrive];
    else
    {
        [self willChangeValueForKey: @"drives"];
        [queue removeObject: newDrive];
        [queue replaceObjectAtIndex: oldDriveIndex withObject: newDrive];
        [self didChangeValueForKey: @"drives"];
    }
}

- (BXDrive *) queuedDriveRepresentingURL: (NSURL *)URL
{
	for (BXDrive *drive in self.allDrives)
	{
		if ([drive representsLogicalURL: URL])
            return drive;
	}
	return nil;
}

- (NSUInteger) indexOfQueuedDrive: (BXDrive *)drive
{
    NSString *letter = drive.letter;
    if (!letter) return NSNotFound;
    
    NSArray *queue = [self.drives objectForKey: letter];
    return [queue indexOfObject: drive];
}

- (BXDrive *) siblingOfQueuedDrive: (BXDrive *)drive
                          atOffset: (NSInteger)offset
{
    NSString *letter = drive.letter;
    if (!letter) return nil;
    
    NSArray *queue = [self.drives objectForKey: letter];
    NSUInteger queueIndex = [queue indexOfObject: drive];
    if (queueIndex == NSNotFound) return nil;
    
    //Wow, who knew C made it such a fucking ordeal to modulo-wrap negative numbers into positive
    NSInteger siblingIndex = ((NSInteger)queueIndex + offset) % (NSInteger)queue.count;
    if (siblingIndex < 0)
        siblingIndex = queue.count + offset;
    
    return [queue objectAtIndex: siblingIndex];
}


#pragma mark -
#pragma mark Drive mounting

- (NSWindow *) windowForDriveSheet
{
    BXInspectorController *inspector = [BXInspectorController controller];
    if (inspector.isVisible && inspector.selectedTabViewItemIndex == BXDriveInspectorPanelIndex)
    {
        return inspector.window;
    }
    else
    {
        return self.windowForSheet;
    }
}

- (void) _mountQueuedSiblingsAtOffset: (NSInteger)offset
{
    for (BXDrive *currentDrive in self.mountedDrives)
    {
        BXDrive *siblingDrive = [self siblingOfQueuedDrive: currentDrive atOffset: offset];
        if (siblingDrive && ![siblingDrive isEqual: currentDrive])
        {
            NSError *mountError = nil;
            BXDrive *mountedDrive = [self mountDrive: siblingDrive
                                            ifExists: BXDriveReplace
                                             options: BXDefaultDriveMountOptions
                                               error: &mountError];
            
            if (!mountedDrive && mountError)
            {
                [self presentError: mountError
                    modalForWindow: self.windowForDriveSheet
                          delegate: nil
                didPresentSelector: NULL
                       contextInfo: NULL];
                
                //Don't continue mounting if we encounter a problem
                break;
            }
        }
    }
}

- (BOOL) shouldUnmountDrives: (NSArray *)selectedDrives 
                usingOptions: (BXDriveMountOptions)options
                      sender: (id)sender
{
	//If the Option key was held down, bypass this check altogether and allow any drive to be unmounted
	NSUInteger optionKeyDown = ([NSApp currentEvent].modifierFlags & NSEventModifierFlagOption) == NSEventModifierFlagOption;
	if (optionKeyDown) return YES;

	NSMutableArray *drivesInUse = [[NSMutableArray alloc] initWithCapacity: selectedDrives.count];
	for (BXDrive *drive in selectedDrives)
	{
        //If the drive is importing, refuse to unmount/dequeue it altogether.
        if ([self activeImportOperationForDrive: drive]) return NO;
        
        //If the drive isn't mounted anyway, then ignore it
        //(we may receive a mix of mounted and unmounted drives)
        if (![self driveIsMounted: drive]) continue;
        
        //Prevent locked drives from being removed altogether
		if (drive.isLocked) return NO;
		
		//If a program is running and the drive is in use, then warn about it
		if (!self.emulator.isAtPrompt && [self.emulator driveInUse: drive])
			[drivesInUse addObject: drive];
	}
	
	if (drivesInUse.count > 0)
	{
		//Note that alert stays retained - it is released by the didEndSelector
		BXDrivesInUseAlert *alert = [[BXDrivesInUseAlert alloc] initWithDrives: drivesInUse forSession: self];
		
        NSDictionary *contextInfo = @{
                                      @"drives": selectedDrives,
                                      @"options": @(options)
                                      };
        
        [alert beginSheetModalForWindow: self.windowForDriveSheet completionHandler:^(NSModalResponse returnCode) {
            [self drivesInUseAlertDidEnd:alert returnCode:returnCode contextInfo:contextInfo];
        }];
        
		return NO;
	}
	return YES;
}

- (void) drivesInUseAlertDidEnd: (BXDrivesInUseAlert *)alert
					 returnCode: (NSInteger)returnCode
                    contextInfo: (NSDictionary *)contextInfo
{
	if (returnCode == NSAlertFirstButtonReturn)
    {
        NSArray *selectedDrives = [contextInfo objectForKey: @"drives"];
        BXDriveMountOptions options = [[contextInfo objectForKey: @"options"] unsignedIntegerValue];
        
        //It's OK to force removal here since we've already gotten permission
        //from the user to eject in-use drives.
        NSError *unmountError = nil;
        BOOL unmounted = [self unmountDrives: selectedDrives
                                     options: options | BXDriveForceUnmounting
                                       error: &unmountError];
        
        if (!unmounted && unmountError)
        {
            [alert.window orderOut: self];
            [self presentError: unmountError
                modalForWindow: self.windowForDriveSheet
                      delegate: nil
            didPresentSelector: NULL
                   contextInfo: NULL];
        }
    }
    //Release the context dictionary that was previously retained in the beginSheetModalForWindow: call.
}

static NSArray<NSURL*>* removeUserDirs(NSArray<NSURL*>* oldArrs)
{
    NSMutableIndexSet *idxSet = [NSMutableIndexSet indexSet];
    NSMutableArray *tmp = [oldArrs mutableCopy];
    for (NSUInteger i = 0; i < oldArrs.count; i++) {
        if ([oldArrs[i] isBasedInURL: NSFileManager.defaultManager.homeDirectoryForCurrentUser]) {
            [idxSet addIndex:i];
        }
    }
    
    [tmp removeObjectsAtIndexes:idxSet];
    return [tmp copy];
}

- (BOOL) validateDriveURL: (NSURL **)ioValue
                    error: (NSError **)outError
{
    NSURL *driveURL = *ioValue;
    NSAssert(driveURL != nil, @"No drive URL specified.");
    
    //Resolve the path to eliminate any symlinks, tildes and backtracking
    NSURL *resolvedURL = driveURL.URLByResolvingSymlinksInPath.URLByStandardizingPath;
    
    if (![resolvedURL checkResourceIsReachableAndReturnError: outError])
    {
        return NO;
    }
                            
    //Check if the path represents any restricted folders.
    //(Only bother to do this for folders: we can assume disc images are not system folders.)
    if (resolvedURL.isDirectory)
    {
        NSURL *rootURL = [NSURL fileURLWithPath: NSOpenStepRootDirectory()];
        if ([resolvedURL isEqual: rootURL])
        {
            if (outError)
            {
                *outError = [BXSessionCannotMountSystemFolderError errorWithFolderURL: driveURL
                                                                             userInfo: nil];
            }
            return NO;
        }
        
        //Restrict all system library folders, but not the user's own library folder.
        NSArray *restrictedURLs = [[NSFileManager defaultManager] URLsForDirectory: NSAllLibrariesDirectory
                                                                         inDomains: NSAllDomainsMask & ~NSUserDomainMask];
        restrictedURLs = removeUserDirs(restrictedURLs);
        
        for (NSURL *restrictedURL in restrictedURLs)
        {   
            if ([resolvedURL isBasedInURL: restrictedURL])
            {
                if (outError)
                {
                    *outError = [BXSessionCannotMountSystemFolderError errorWithFolderURL: driveURL
                                                                                 userInfo: nil];
                }
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL) shouldMountNewDriveForURL: (NSURL *)URL
{
	//If the file isn't already accessible from DOS, we should mount it
	if (![self.emulator logicalURLIsAccessibleInDOS: URL])
        return YES;
	
	//If the URL is accessible within an existing drive, but the file is of a type
	//that should get its own drive, then mount it as a new drive of its own.
	if (([URL matchingFileType: [self.class separatelyMountedTypes]] != nil) && ![self.emulator logicalURLIsMountedInDOS: URL])
		return YES;
	
	return NO;
}

- (BXDrive *) mountDriveForURL: (NSURL *)URL
                      ifExists: (BXDriveConflictBehaviour)conflictBehaviour
                       options: (BXDriveMountOptions)options
                         error: (NSError **)outError
{
	NSAssert1(self.isEmulating, @"mountDriveForURL:ifExists:options:error: called for %@ while emulator is not running.", URL);
    
	//Choose an appropriate mount point and create the new drive for it
	NSURL *mountPointURL = [self.class preferredMountPointForURL: URL];
    
    //Make sure the mount point exists and is suitable to use
    if (![self validateDriveURL: &mountPointURL error: outError]) return nil;
    
    //Check if there's already a drive in the queue that matches this mount point:
    //if so, mount it if necessary and return that.
    BXDrive *existingDrive = [self queuedDriveRepresentingURL: mountPointURL];
    if (existingDrive)
    {
        existingDrive = [self mountDrive: existingDrive
                                ifExists: conflictBehaviour
                                 options: options
                                   error: outError];
        return existingDrive;
    }
    //Otherwise, create a new drive for the mount
    else
    {
        BXDrive *drive = [BXDrive driveWithContentsOfURL: mountPointURL
                                                  letter: nil
                                                    type: BXDriveAutodetect];
        
        return [self mountDrive: drive
                       ifExists: conflictBehaviour
                        options: options
                          error: outError];
    }
}

- (BOOL) openURLInDOS: (NSURL *)URL
        withArguments: (NSString *)arguments
          clearScreen: (BOOL)clearScreen
         onCompletion: (BXSessionProgramCompletionBehavior)completionBehavior
                error: (out NSError **)outError
{
	if (!self.canOpenURLs)
    {
        if (outError)
        {
            *outError = [BXSessionNotReadyError errorWithUserInfo: nil];
        }
        return NO;
    }
    
	//Get the path to the file in the DOS filesystem
	NSString *dosPath = [self.emulator DOSPathForLogicalURL: URL];
	if (!dosPath)
    {
        if (outError)
        {
            *outError = [BXSessionURLNotReachableError errorWithURL: URL userInfo: nil];
        }
        return NO;
	}
    
	//Unpause the emulation if it's paused, and ensure we don't remain auto-paused.
    //TODO: we shouldn't force autopause to be off here, we should trigger a re-evaluation
    //of the autopause criteria and handle this in _shouldAutoPause.
    self.autoPaused = NO;
	[self resume: self];
	
    //If this was an executable, launch it now.
	if ([URL matchingFileType: [BXFileTypes executableTypes]] != nil)
	{
        if (completionBehavior == BXSessionProgramCompletionBehaviorAuto || completionBehavior == BXSessionShowDOSPromptOnCompletionIfDirectory)
        {
            if (self.DOSWindowController.DOSViewShown || !self.allowsLauncherPanel)
                completionBehavior = BXSessionShowDOSPromptOnCompletion;
            else
                completionBehavior = BXSessionShowLauncherOnCompletion;
        }
        _programCompletionBehavior = completionBehavior;
        
        self.emulator.clearsScreenBeforeCommandExecution = clearScreen;
        
        //Switch to the DOS view as soon as we execute.
        [self.DOSWindowController showDOSView];
        
		[self.emulator executeProgramAtDOSPath: dosPath
                                 withArguments: arguments
                             changingDirectory: YES];
        
	}
    //Otherwise, treat the specified path as a directory and switch the working directory to it.
	else
	{
		[self.emulator changeWorkingDirectoryToDOSPath: dosPath];
        
        if (completionBehavior == BXSessionProgramCompletionBehaviorAuto)
        {
            if (self.DOSWindowController.DOSViewShown || !self.allowsLauncherPanel)
                completionBehavior = BXSessionShowDOSPromptOnCompletion;
            else
                completionBehavior = BXSessionShowLauncherOnCompletion;
        }
        
        //Because the directory change will happen instantaneously and emulatorDidReturnToShell:
        //will never be called, handle the 'exit' behaviour immediately.
        switch (completionBehavior)
        {
            case BXSessionShowDOSPromptOnCompletion:
            case BXSessionShowDOSPromptOnCompletionIfDirectory:
                [self.DOSWindowController showDOSView];
                break;
            case BXSessionShowLauncherOnCompletion:
                [self.DOSWindowController showLaunchPanel];
                break;
        }
	}
    
	return YES;
}

- (BOOL) openURLInDOS: (NSURL *)URL error: (out NSError **)outError
{
    return [self openURLInDOS: URL
                withArguments: nil
                  clearScreen: NO
                 onCompletion: BXSessionProgramCompletionBehaviorAuto
                        error: outError];
}

//Mount drives for all CD-ROMs that are currently mounted in OS X
//(as long as they're not already mounted in DOS, that is.)
//Returns YES if any drives were mounted, NO otherwise.
- (NSArray *) mountCDVolumesWithError: (NSError **)outError
{
	BXEmulator *theEmulator = self.emulator;
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSArray *volumeURLs = [workspace  mountedVolumeURLsOfType: ADBDataCDVolumeType includingHidden: NO];
	
	//If there were no data CD volumes, then check for audio CD volumes and mount them instead
	//(We avoid doing this if there were data CD volumes, since the audio CDs will then be used
	//as 'shadow' audio volumes for those data CDs.)
	if (!volumeURLs.count)
		volumeURLs = [workspace mountedVolumeURLsOfType: ADBAudioCDVolumeType includingHidden: NO];
    
    NSMutableArray *mountedDrives = [NSMutableArray arrayWithCapacity: 10];
	for (NSURL *volumeURL in volumeURLs)
	{
		if (![theEmulator logicalURLIsMountedInDOS: volumeURL])
		{
			BXDrive *drive = [BXDrive driveWithContentsOfURL: volumeURL letter: nil type: BXDriveCDROM];
            
            drive = [self mountDrive: drive 
                            ifExists: BXDriveQueue
                             options: BXSystemVolumeMountOptions
                               error: outError];
            
            if (drive)
                [mountedDrives addObject: drive];
            
            //If there was any error in mounting a drive,
            //then bail out and don't attempt to mount further drives
            //TODO: check the actual error to determine whether we can
            //continue after failure.
            else return nil;
		}
	}
	return mountedDrives;
}

//Mount drives for all floppy-sized FAT volumes that are currently mounted in OS X.
//Returns YES if any drives were mounted, NO otherwise.
- (NSArray *) mountFloppyVolumesWithError: (NSError **)outError
{
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSArray *volumeURLs = [workspace mountedVolumeURLsOfType: ADBFATVolumeType includingHidden: NO];
	BXEmulator *theEmulator = self.emulator;
    
    NSMutableArray *mountedDrives = [NSMutableArray arrayWithCapacity: 10];
	for (NSURL *volumeURL in volumeURLs)
	{
		if (![theEmulator logicalURLIsMountedInDOS: volumeURL] && [workspace isFloppyVolumeAtURL: volumeURL])
		{
			BXDrive *drive = [BXDrive driveWithContentsOfURL: volumeURL letter: nil type: BXDriveFloppyDisk];
            
            drive = [self mountDrive: drive
                            ifExists: BXDriveQueue
                             options: BXSystemVolumeMountOptions
                               error: outError];
            
            if (drive)
                [mountedDrives addObject: drive];
            
            //If there was any error in mounting a drive,
            //then bail out and don't attempt to mount further drives
            //TODO: check the actual error to determine whether we can
            //continue after failure.
            else return nil;
		}
	}
	return mountedDrives;
}

- (BXDrive *) mountToolkitDriveWithError: (NSError **)outError
{
	BXEmulator *theEmulator = self.emulator;

	NSString *toolkitDriveLetter	= [[NSUserDefaults standardUserDefaults] stringForKey: @"toolkitDriveLetter"];
	NSURL *toolkitURL               = [[NSBundle mainBundle] URLForResource: @"DOS Toolkit" withExtension: nil];
    
	BXDrive *toolkitDrive = [BXDrive driveWithContentsOfURL: toolkitURL letter: toolkitDriveLetter type: BXDriveHardDisk];
    toolkitDrive.title = NSLocalizedString(@"DOS Toolkit", @"The display title for Boxer’s toolkit drive.");
	
	//Hide and lock the toolkit drive so that it cannot be ejected and will not appear in the drive inspector,
    //and make it read-only with 0 bytes free so that it will not appear as a valid installation target to DOS games.
	toolkitDrive.locked = YES;
	toolkitDrive.readOnly = YES;
	toolkitDrive.hidden = YES;
	toolkitDrive.freeSpace = 0;
    
	toolkitDrive = [self mountDrive: toolkitDrive
                           ifExists: BXDriveReplace
                            options: BXBuiltinDriveMountOptions
                              error: outError];
	
	//Point DOS to the correct paths if we've mounted the toolkit drive successfully
	//TODO: we should treat this as an error if it didn't mount!
	if (toolkitDrive)
	{
		//TODO: the DOS path should include the root folder of every drive, not just Y and Z.
        //We should also have a proper API for adding to the DOS path, rather than overriding
        //it completely like this.
		NSString *dosPath	= [NSString stringWithFormat: @"%1$@:\\;%1$@:\\UTILS;Z:\\", toolkitDrive.letter];
		NSString *ultraDir	= [NSString stringWithFormat: @"%@:\\ULTRASND", toolkitDrive.letter];
		NSString *utilsDir	= [NSString stringWithFormat: @"%@:\\UTILS", toolkitDrive.letter];
		
		[theEmulator setVariable: @"path"		to: dosPath		encoding: BXDirectStringEncoding];
		[theEmulator setVariable: @"boxerutils"	to: utilsDir	encoding: BXDirectStringEncoding];
		[theEmulator setVariable: @"ultradir"	to: ultraDir	encoding: BXDirectStringEncoding];
	}
    return toolkitDrive;
}

- (BXDrive *) mountTempDriveWithError: (NSError **)outError
{
	BXEmulator *theEmulator = self.emulator;

	//Mount a temporary folder at the appropriate drive
	NSFileManager *manager		= [NSFileManager defaultManager];
	NSString *tempDriveLetter	= [[NSUserDefaults standardUserDefaults] stringForKey: @"temporaryDriveLetter"];
	NSURL *tempURL              = [manager createTemporaryURLWithPrefix: @"Boxer" error: outError];
	
	if (tempURL)
	{
        //Record the location of the temporary folder: we'll delete it when the session finishes.
		self.temporaryFolderURL = tempURL;
		
		BXDrive *tempDrive = [BXDrive driveWithContentsOfURL: tempURL letter: tempDriveLetter type: BXDriveHardDisk];
        tempDrive.title = NSLocalizedString(@"Temporary Files", @"The display title for Boxer’s temp drive.");
        
        //Hide and lock the temp drive so that it cannot be ejected and will not appear in the drive inspector.
		tempDrive.locked = YES;
		tempDrive.hidden = YES;
		
        //Replace any existing drive at the same letter, and don't show any notifications
		tempDrive = [self mountDrive: tempDrive
                            ifExists: BXDriveReplace
                             options: BXBuiltinDriveMountOptions
                               error: outError];
		
		if (tempDrive)
		{
			NSString *tempPath = [NSString stringWithFormat: @"%@:\\", tempDrive.letter];
			[theEmulator setVariable: @"temp"	to: tempPath	encoding: BXDirectStringEncoding];
			[theEmulator setVariable: @"tmp"	to: tempPath	encoding: BXDirectStringEncoding];
		}
        //If we couldn't mount the temporary folder for some reason, then delete it
        else
        {
            [manager removeItemAtURL: tempURL error: nil];
        }
        
        return tempDrive;
	}	
    return nil;
}

- (BXDrive *) mountDummyCDROMWithError: (NSError **)outError
{
    //First, check if we already have a CD drive mounted:
    //If so, we don't need a dummy one.
    for (BXDrive *drive in self.mountedDrives)
    {
        if (drive.type == BXDriveCDROM) return drive;
    }
    
    NSURL *dummyImageURL    = [[NSBundle mainBundle] URLForResource: @"DummyCD" withExtension: @"iso"];
	BXDrive *dummyDrive     = [BXDrive driveWithContentsOfURL: dummyImageURL letter: nil type: BXDriveCDROM];
    
    dummyDrive.title = NSLocalizedString(@"Dummy CD",
                                         @"The display title for Boxer’s dummy CD-ROM drive.");
	
	dummyDrive = [self mountDrive: dummyDrive
                         ifExists: BXDriveQueue
                          options: BXDriveKeepWithSameType
                            error: outError];
	
    return dummyDrive;
}

- (NSString *) preferredLetterForDrive: (BXDrive *)drive
                               options: (BXDriveMountOptions)options
{
    //If we want to keep this drive with others of its ilk,
    //then use the letter of the first drive of that type.
    if ((options & BXDriveKeepWithSameType) && (drive.type == BXDriveCDROM || drive.type == BXDriveFloppyDisk))
    {
        for (BXDrive *knownDrive in self.allDrives)
        {
            if (knownDrive.type == drive.type)
                return knownDrive.letter;
        }
    }
    
    //Otherwise, pick the next suitable drive letter for that type
    //that isn't already queued.
    NSArray *letters;
	if      (drive.isFloppy)	letters = [BXEmulator floppyDriveLetters];
	else if (drive.isCDROM)     letters = [BXEmulator CDROMDriveLetters];
	else                        letters = [BXEmulator hardDriveLetters];
    
    BOOL avoidDriveC = (options & BXDriveAvoidAssigningDriveC) == BXDriveAvoidAssigningDriveC;
	for (NSString *letter in letters)
    {
        if (avoidDriveC && [letter isEqualToString: @"C"])
            continue;
        
        NSArray *drivesAtLetter = [self.drives objectForKey: letter];
        if (!drivesAtLetter.count) return letter;
    }
    
    //Uh-oh, looks like all suitable drive letters are taken! Bummer.
    return nil;
}

- (BXDrive *) mountDrive: (BXDrive *)drive
                ifExists: (BXDriveConflictBehaviour)conflictBehaviour
                 options: (BXDriveMountOptions)options
                   error: (NSError **)outError
{
    if (outError) *outError = nil;
    
    //If this drive is already mounted, don't bother retrying.
    if ([self driveIsMounted: drive]) return drive;
    
    //TODO: return an operation-disabled error message also
    if (!self.allowsDriveChanges && _hasConfigured)
        return nil;
    
    //Sanity check: BXDriveReplaceWithSiblingFromQueue is not applicable
    //when mounting a new drive, so ensure it is not set.
    options &= ~BXDriveReplaceWithSiblingFromQueue;
    
    //Sanity check: BXDriveReassign cannot be used along with
    //BXDriveKeepWithSameType, so clear that flag.
    if (conflictBehaviour == BXDriveReassign)
        options &= ~BXDriveKeepWithSameType;
    
    //If the drive doesn't have a specific drive letter,
    //determine one now based on the specified options.
    if (!drive.letter)
    {
        drive.letter = [self preferredLetterForDrive: drive
                                             options: options];
    }
    
    //Allow the game profile to override the drive volume label if needed.
	NSString *customLabel = [self.gameProfile volumeLabelForDrive: drive];
	if (customLabel) drive.volumeLabel = customLabel;
    
    BXDrive *driveToMount = drive;
    BXDrive *fallbackDrive = nil;
    
	if (options & BXDriveUseBackingImageIfAvailable)
    {
        //Check if the specified path has a DOSBox-compatible image backing it:
        //if so then try to mount that instead, and assign the current path as an alias.
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        NSURL *sourceImageURL = [workspace sourceImageForVolumeAtURL: drive.sourceURL];
        
        if ([sourceImageURL matchingFileType: [BXFileTypes mountableImageTypes]] != nil)
        {
            //Check if we already have another drive representing the source path
            //at the requested drive letter: if so, then just add the path as an
            //alias to that existing drive, and mount that drive instead
            //(assuming it isn't already.)
            //TODO: should we handle this case upstairs in mountDriveForPath:?
            BXDrive *existingDrive = [self queuedDriveRepresentingURL: sourceImageURL];
            if (![existingDrive isEqual: drive] && [existingDrive.letter isEqual: drive.letter])
            {
                [existingDrive addEquivalentURL: drive.sourceURL];
                [existingDrive addEquivalentURL: drive.mountPointURL];
                
                if ([self driveIsMounted: existingDrive])
                {
                    return existingDrive;
                }
                else
                {
                    driveToMount = existingDrive;
                }
            }
            //Otherwise, make a new drive using the image, and mount that instead.
            else
            {
                BXDrive *imageDrive = [BXDrive driveWithContentsOfURL: sourceImageURL
                                                               letter: drive.letter
                                                                 type: drive.type];
                
                imageDrive.readOnly = drive.readOnly;
                imageDrive.hidden = drive.isHidden;
                imageDrive.locked = drive.isLocked;
                
                [imageDrive addEquivalentURL: drive.sourceURL];
                [imageDrive addEquivalentURL: drive.mountPointURL];
                
                driveToMount = imageDrive;
                fallbackDrive = drive;
            }
        }
    }
    
    if (options & BXDriveUseShadowingIfAvailable)
    {
        drive.shadowURL = [self shadowURLForDrive: drive];
    }
    
    //Check if this is a CD-ROM drive and enabled for CD audio.
    //If it is, check that any CD audio volume is actually available.
    //TODO: cache this information so we're not polling the filesystem.
    if (drive.isCDROM && drive.usesCDAudio)
    {
		NSArray *audioVolumes = [[NSWorkspace sharedWorkspace] mountedVolumeURLsOfType: ADBAudioCDVolumeType
                                                                       includingHidden: YES];
        if (!audioVolumes.count)
            drive.usesCDAudio = NO;
    }
    
    BXDrive *mountedDrive = nil;
    BXDrive *replacedDrive = nil;
    BOOL replacedDriveWasCurrent = NO;
    
    do
    {
        NSError *mountError = nil;
        mountedDrive = [self.emulator mountDrive: driveToMount error: &mountError];
    
        //If mounting fails, check what the failure was and try to recover.
        if (!mountedDrive)
        {
            //The drive letter was already taken: decide what to do based on our conflict behaviour.
            if ([mountError matchesDomain: BXDOSFilesystemErrorDomain code: BXDOSFilesystemDriveLetterOccupied])
            {
                switch (conflictBehaviour)
                {
                    //Pick a new drive letter and try again.
                    case BXDriveReassign:
                        {
                            NSString *newLetter = [self preferredLetterForDrive: driveToMount
                                                                        options: options];
                            driveToMount.letter = newLetter;
                        }
                        break;
                    
                    //Try to unmount the existing drive and try again.
                    case BXDriveReplace:
                        {
                            NSError *unmountError = nil;
                            replacedDrive           = [self.emulator driveAtLetter: driveToMount.letter];
                            replacedDriveWasCurrent = [self.emulator.currentDrive isEqual: replacedDrive];
                            
                            BOOL unmounted = [self unmountDrive: replacedDrive
                                                        options: options
                                                          error: &unmountError];
                            
                            //If we couldn't unmount the drive we're trying to replace,
                            //then queue up the desired drive anyway and then give up.
                            if (!unmounted)
                            {
                                [self enqueueDrive: driveToMount];
                                if (outError) *outError = unmountError;
                                return nil;
                            }
                        }
                        break;
                        
                    //Add the conflicting drive into a queue alongside the existing drive,
                    //and give up on mounting for now.
                    case BXDriveQueue:
                    default:
                        {
                            [self enqueueDrive: driveToMount];
                            return nil;
                        }
                }
            }
            
            //Disc image couldn't be recognised: if we have a fallback volume,
            //switch to that instead and continue mounting.
            //(If we don't, we'll continue bailing out.)
            else if ([mountError matchesDomain: BXDOSFilesystemErrorDomain code: BXDOSFilesystemInvalidImage] && fallbackDrive)
            {
                driveToMount = fallbackDrive;
                fallbackDrive = nil;
            }
            
            //Bail out completely after any other error - once we put back
            //any drive we tried to replace.
            else
            {
                //Tweak: if we failed because we couldn't read the source file/volume,
                //check if this could be because of an import operation.
                //If so, rephrase the error with a more helpful description.
                if ([mountError matchesDomain: BXDOSFilesystemErrorDomain code: BXDOSFilesystemCouldNotReadDrive] &&
                    [[self activeImportOperationForDrive: driveToMount].class driveUnavailableDuringImport])
                {
                    NSString *descriptionFormat = NSLocalizedString(@"The drive “%1$@” is unavailable while it is being imported.",
                                                                    @"Error shown when a drive cannot be mounted because it is busy being imported.");
                    
                    NSString *description = [NSString stringWithFormat: descriptionFormat, driveToMount.title];
                    NSString *suggestion = NSLocalizedString(@"You can use the drive once the import has completed or been cancelled.", @"Recovery suggestion shown when a drive cannot be mounted because it is busy being imported.");
                    
                    
                    NSDictionary *userInfo = @{
                        NSLocalizedDescriptionKey: description,
                        NSLocalizedRecoverySuggestionErrorKey: suggestion,
                        NSUnderlyingErrorKey: mountError,
                        BXDOSFilesystemErrorDriveKey: driveToMount,
                    };
                    
                    mountError = [NSError errorWithDomain: mountError.domain
                                                     code: mountError.code
                                                 userInfo: userInfo];
                }
                
                if (replacedDrive)
                {
                    [self.emulator mountDrive: replacedDrive error: NULL];
                    
                    if (replacedDriveWasCurrent && self.emulator.isAtPrompt)
                    {
                        [self.emulator changeToDriveLetter: replacedDrive.letter];
                    }
                }
                if (outError) *outError = mountError;
                return nil;
            }
        }
    }
    while (!mountedDrive);
    
    //If we got this far then we have successfully mounted a drive!
    //Post a notification about it if appropriate.
    if (options & BXDriveShowNotifications)
    {
        //If we replaced an existing drive then show a slightly different notification
        if (replacedDrive)
        {
            [[BXBezelController controller] showDriveSwappedBezelFromDrive: replacedDrive
                                                                   toDrive: mountedDrive];
        }
        else
        {
            [[BXBezelController controller] showDriveAddedBezelForDrive: mountedDrive];
        }
    }
    
    //If we replaced DOS's current drive in the course of ejecting, then switch
    //to the new drive.
    //TODO: make it so that we don't switch away from the drive in the first place.
    if (replacedDrive && replacedDriveWasCurrent && self.emulator.isAtPrompt)
    {
        [self.emulator changeToDriveLetter: mountedDrive.letter];
    }
    
    return mountedDrive;
}


- (BOOL) unmountDrive: (BXDrive *)drive
              options: (BXDriveMountOptions)options
                error: (NSError **)outError
{
    //TODO: populate an operation-disabled error message.
    if (!self.allowsDriveChanges && _hasConfigured)
        return NO;
    
    if ([self driveIsMounted: drive])
    {
        BOOL force = NO;
        if      (options & BXDriveForceUnmounting) force = YES;
        else if (options & BXDriveForceUnmountingIfRemovable &&
                (drive.type == BXDriveCDROM || drive.type == BXDriveFloppyDisk)) force = YES;
        
        //If requested, try to find another drive in the same queue
        //to replace the unmounted one with.
        BXDrive *replacementDrive = nil;
        BOOL driveWasCurrent = NO;
        if (options & BXDriveReplaceWithSiblingFromQueue)
        {
            replacementDrive = [self siblingOfQueuedDrive: drive atOffset: 1];
            if ([replacementDrive isEqual: drive]) replacementDrive = nil;
            driveWasCurrent = [self.emulator.currentDrive isEqual: drive];
        }
        
        
        BOOL unmounted = [self.emulator unmountDrive: drive
                                               force: force
                                               error: outError];
        
        if (unmounted)
        {
            if (replacementDrive)
            {
                replacementDrive = [self mountDrive: replacementDrive
                                           ifExists: BXDriveQueue
                                            options: BXReplaceWithSiblingDriveMountOptions
                                              error: nil];
                
                //Remember to change back to the same drive once we're done unmounting.
                if (replacementDrive && driveWasCurrent && self.emulator.isAtPrompt)
                {
                    [self.emulator changeToDriveLetter: replacementDrive.letter];
                }
            }
            
            if (options & BXDriveShowNotifications)
            {
                //Show a slightly different notification if we swapped in another drive.
                if (replacementDrive)
                {
                    [[BXBezelController controller] showDriveSwappedBezelFromDrive: drive
                                                                           toDrive: replacementDrive];
                }
                else
                {
                    [[BXBezelController controller] showDriveRemovedBezelForDrive: drive];
                }
            }
            
            if (options & BXDriveRemoveExistingFromQueue)
            {
                [self dequeueDrive: drive];
            }
            
        }
        return unmounted;
    }
    //If the drive isn't mounted, but we requested that it be removed from the queue
    //after unmounting anyway, then do that now.
    else
    {
        if (options & BXDriveRemoveExistingFromQueue)
            [self dequeueDrive: drive];
        return NO;
    }
}


- (BOOL) unmountDrives: (NSArray *)drivesToUnmount
               options: (BXDriveMountOptions)options
                 error: (NSError **)outError
{
	BOOL succeeded = NO;
	for (BXDrive *drive in drivesToUnmount)
	{
        if ([self unmountDrive: drive options: options error: outError]) succeeded = YES;
        //If any of the drive unmounts failed, don't continue further
        else return NO;
	}
	return succeeded;
}


#pragma mark -
#pragma mark Managing executables

+ (NSSet *) keyPathsForValuesAffectingPrincipalDrive
{
	return [NSSet setWithObject: @"executableURLs"];
}

- (BXDrive *) principalDrive
{
	//Prioritise drive C, if it's available and has executables on it
	if ([[self.executableURLs objectForKey: @"C"] count])
        return [self.emulator driveAtLetter: @"C"];
    
	//Otherwise through all the mounted drives and return the first one that we have programs for.
    NSArray *sortedLetters = [self.executableURLs.allKeys sortedArrayUsingSelector: @selector(compare:)];
	for (NSString *letter in sortedLetters)
	{
		if ([[self.executableURLs objectForKey: letter] count])
            return [self.emulator driveAtLetter: letter];
	}
	return nil;
}

+ (NSSet *) keyPathsForValuesAffectingProgramURLsOnPrincipalDrive
{
	return [NSSet setWithObjects: @"executableURLs", nil];
}

- (NSArray *) programURLsOnPrincipalDrive
{
	NSString *driveLetter = self.principalDrive.letter;
	if (driveLetter) return [self.executableURLs objectForKey: driveLetter];
	else return nil;
}


#pragma mark -
#pragma mark OS X filesystem notifications

//Register ourselves as an observer for filesystem notifications
- (void) _registerForFilesystemNotifications
{
	if ([self _shouldAutoMountExternalVolumes])
    {
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        NSNotificationCenter *workspaceCenter = [workspace notificationCenter];
        [workspaceCenter addObserver: self
                            selector: @selector(_volumeDidMount:)
                                name: NSWorkspaceDidMountNotification
                              object: workspace];
        
        [workspaceCenter addObserver: self
                            selector: @selector(_volumeWillUnmount:)
                                name: NSWorkspaceWillUnmountNotification
                              object: workspace];

        [workspaceCenter addObserver: self
                            selector: @selector(_volumeWillUnmount:)
                                name: NSWorkspaceDidUnmountNotification
                              object: workspace];
	}
    
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    [defaultCenter addObserver: self
                      selector: @selector(_applicationDidBecomeActive:)
                          name: NSApplicationDidBecomeActiveNotification
                        object: NSApp];
}

- (void) _deregisterForFilesystemNotifications
{
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSNotificationCenter *center = [workspace notificationCenter];

	[center removeObserver: self name: NSWorkspaceDidMountNotification		object: workspace];
	[center removeObserver: self name: NSWorkspaceDidUnmountNotification	object: workspace];
	[center removeObserver: self name: NSWorkspaceWillUnmountNotification	object: workspace];
}

- (void) _volumeDidMount: (NSNotification *)theNotification
{
	//We decide what to do with audio CD volumes based on whether they have a corresponding
	//data volume. Unfortunately, the volumes are reported as soon as they are mounted, so
	//often the audio volume will send a mount notification before its data volume exists.
	
	//To work around this, we add a slight delay before we process the volume mount notification,
    //to allow other volumes time to finish mounting.
    
    [self performSelector: @selector(_handleVolumeDidMount:)
               withObject: theNotification
               afterDelay: BXVolumeMountDelay];
}

- (void) _handleVolumeDidMount: (NSNotification *)theNotification
{
	//Don't respond to mounts if the emulator isn't actually running
	if (!self.isEmulating) return;
	
	NSURL *volumeURL        = [theNotification.userInfo objectForKey: NSWorkspaceVolumeURLKey];
	NSWorkspace *workspace	= [NSWorkspace sharedWorkspace];
	NSString *volumeType	= [workspace typeOfVolumeAtURL: volumeURL];
    
    //Ignore the mount if it's a hidden volume.
    if (![workspace isVisibleVolumeAtURL: volumeURL]) return;
    
	//Only mount volumes that are of an appropriate type.
	if (![[self.class automountedVolumeFormats] containsObject: volumeType])
        return;
	
	//Only mount CD audio volumes if they have no corresponding data volume
	//(Otherwise, we mount the data volume instead and shadow it with the audio CD's tracks)
	if ([volumeType isEqualToString: ADBAudioCDVolumeType] &&
        [workspace dataVolumeOfAudioCDAtURL: volumeURL] != nil)
        return;
	
	//Only mount FAT volumes that are actual floppy disks
	if ([volumeType isEqualToString: ADBFATVolumeType] &&
        ![workspace isFloppyVolumeAtURL: volumeURL])
        return;
	
    
	NSURL *mountPointURL = [self.class preferredMountPointForURL: volumeURL];
    
    //If the path is already mounted, don't mess around further.
	if ([self.emulator logicalURLIsMountedInDOS: mountPointURL])
        return;
	
    //If an existing queued drive corresponds to this volume,
    //then mount it if it's not already mounted.
    BXDrive *existingDrive  = [self queuedDriveRepresentingURL: mountPointURL];
    if (existingDrive)
    {
        [self mountDrive: existingDrive
                ifExists: BXDriveReplace
                 options: BXDefaultDriveMountOptions
                   error: NULL];
    }
	//Alright, if we got this far then it's ok to mount a new drive for it
    else
    {
        BXDrive *drive = [BXDrive driveWithContentsOfURL: mountPointURL
                                                  letter: nil
                                                    type: BXDriveAutodetect];
        
        //Ignore errors when automounting volumes, since these
        //are not directly triggered by the user.
        [self mountDrive: drive
                ifExists: BXDriveReplace
                 options: BXDefaultDriveMountOptions
                   error: NULL];
    }
}

//Implementation note: this handler is called in response to NSVolumeWillUnmountNotifications,
//so that we can remove any of our own file locks that would prevent OS X from continuing to unmount.
//However, it's also called again in response to NSVolumeDidUnmountNotifications, so that we can catch
//unmounts that happened too suddenly to send a WillUnmount notification (which can happen when
//pulling out a USB drive or mechanically ejecting a disk)
- (void) _volumeWillUnmount: (NSNotification *)theNotification
{
	//Ignore unmount events if the emulator isn't actually running
	if (!self.isEmulating) return;
	
	NSURL *volumeURL = [theNotification.userInfo objectForKey: NSWorkspaceVolumeURLKey];
	
    //Scan our drive list to see which drives would be affected by this volume
    //becoming unavailable.
	for (BXDrive *drive in self.allDrives)
	{
        //TODO: refactor this so that we can move the decision off to BXDrive itself
		//(We can't use BXDrive representsURL: because that would give false positives
        //for drives with backing images: we don't want to eject drives whose images
        //are still accessible to us, just because OS X unmounted the image.
		if ([drive.mountPointURL isEqual: volumeURL] || [drive.sourceURL isEqual: volumeURL])
		{
            //Drive import processes may unmount a volume themselves in the course
            //of importing it: in which case we want to leave the drive in place.
            //(TODO: check that this is still the desired behaviour, now that we
            //have implemented drive queues.)
            ADBOperation <BXDriveImport> *activeImport = [self activeImportOperationForDrive: drive];
            if ([activeImport.class driveUnavailableDuringImport]) continue;
            
            //If the drive is mounted, then unmount it now and remove it from the drive list.
            if ([self driveIsMounted: drive])
            {
                [self unmountDrive: drive
                           options: BXVolumeUnmountingDriveUnmountOptions
                             error: nil];
            }
            //If the drive is not mounted, then just remove it from the drive list.
            else
            {
                [self dequeueDrive: drive];
            }
		}
		else
		{
            [drive removeEquivalentURL: volumeURL];
		}
	}
}


#pragma mark -
#pragma mark Emulator delegate methods

- (void) emulatorDidMountDrive: (NSNotification *)theNotification
{	
	BXDrive *drive = [theNotification.userInfo objectForKey: @"drive"];
    
    //Flag the drive as being mounted
    drive.mounted = YES;
    
    //Add the drive to our set of known drives
    [self enqueueDrive: drive];
	
    //If this drive is part of the gamebox, and we're not a standalone app,
    //scan it for executables to display in the program panel
	if (![(BXBaseAppController *)[NSApp delegate] isStandaloneGameBundle] && !drive.isVirtual && [self driveIsBundled: drive])
	{
        [self executableScanForDrive: drive startImmediately: YES];
	}
}

- (void) emulatorDidUnmountDrive: (NSNotification *)theNotification
{
	BXDrive *drive = [theNotification.userInfo objectForKey: @"drive"];
	
    //Flag the drive as no longer being mounted
    drive.mounted = NO;
    
    //Stop scanning for executables on the drive
    [self cancelExecutableScanForDrive: drive];
	
    //Remove the cached executable list when the drive is unmounted
	if ([self.executableURLs objectForKey: drive.letter])
	{
		[self willChangeValueForKey: @"executableURLs"];
		[_executableURLs removeObjectForKey: drive.letter];
		[self didChangeValueForKey: @"executableURLs"];
	}
}

//Pick up on the creation of new executables
- (void) emulatorDidCreateFile: (NSNotification *)notification
{
	BXDrive *drive = [notification.userInfo objectForKey: BXEmulatorDriveKey];
	NSURL *URL = [notification.userInfo objectForKey: BXEmulatorLogicalURLKey];
	
	//The drive is in our executables cache: check if the created file was a DOS executable
	//(If so, add it to the executables cache) 
	NSMutableArray *driveExecutables = [self.executableURLs mutableArrayValueForKey: drive.letter];
	if (driveExecutables && ![driveExecutables containsObject: URL])
	{
        NSString *drivePath = [drive.filesystem pathForLogicalURL: URL];
		if (drivePath && [BXFileTypes isCompatibleExecutableAtPath: drivePath filesystem: drive.filesystem error: NULL])
		{
			[self willChangeValueForKey: @"executableURLs"];
			[driveExecutables addObject: URL];
			[self didChangeValueForKey: @"executableURLs"];
		}
	}
}

//Pick up on the deletion of executables
- (void) emulatorDidRemoveFile: (NSNotification *)notification
{
	BXDrive *drive = [notification.userInfo objectForKey: BXEmulatorDriveKey];
	NSURL *URL = [notification.userInfo objectForKey: BXEmulatorLogicalURLKey];
	
	//The drive is in our executables cache: remove any reference to the deleted file
	NSMutableArray *driveExecutables = [self.executableURLs objectForKey: drive.letter];
	if (driveExecutables && [driveExecutables containsObject: URL])
	{
		[self willChangeValueForKey: @"executableURLs"];
		[driveExecutables removeObject: URL];
		[self didChangeValueForKey: @"executableURLs"];
	}
}

- (BOOL) emulator: (BXEmulator *)emulator shouldShowFileWithName: (NSString *)fileName
{
	//Permit . and .. to be shown
	if ([fileName isEqualToString: @"."] || [fileName isEqualToString: @".."])
        return YES;
	
	//Hide all hidden UNIX files
	//CHECK: will this ever hide valid DOS files?
	if ([fileName hasPrefix: @"."]) return NO;
	
	//Hide OSX and Boxer metadata files
	if ([[self.class hiddenFilenamePatterns] containsObject: fileName]) return NO;
    
	return YES;
}

- (BOOL) emulator: (BXEmulator *)emulator shouldAllowWriteAccessToURL: (NSURL *)fileURL onDrive: (BXDrive *)drive
{
	//Don't allow write access to files on drives marked as read-only
	if (drive.isReadOnly) return NO;
    
	//Don't allow write access to files inside Boxer's application bundle
    //Disabled for now, because:
    //1. our internal drives are flagged as read-only anyway, and
    //2. standalone game bundles have all the game files inside the application,
    //and so need to allow write access.
    /*
	filePath = filePath.stringByStandardizingPath;
	NSString *boxerPath = [[NSBundle mainBundle] bundlePath];
	if ([filePath isRootedInPath: boxerPath]) return NO;
	*/
	//TODO: don't allow write access to files in system directories
	
	//Let other files go through unmolested
	return YES;
}

- (BOOL) emulator: (BXEmulator *)theEmulator shouldMountDriveFromURL: (NSURL *)driveURL
{
    //TODO: show an error message
    if (!self.allowsDriveChanges && _hasConfigured)
        return NO;
    
    NSError *validationError = nil;
    BOOL shouldMount = [self validateDriveURL: &driveURL error: &validationError];
    
    if (validationError)
    {
        [self presentError: validationError
            modalForWindow: self.windowForSheet //Use the main DOS window instead of the Inspector, since the user will have tried to mount from the DOS shell.
                  delegate: nil
        didPresentSelector: NULL
               contextInfo: NULL];
    }
    return shouldMount;
}


#pragma mark -
#pragma mark Drive executable scanning

- (ADBOperation *) executableScanForDrive: (BXDrive *)drive
                         startImmediately: (BOOL)start
{
    id <ADBFilesystemPathAccess> filesystem = drive.filesystem;
    
    if (!filesystem) return nil;
    
    id <ADBFilesystemPathEnumeration> enumerator = [filesystem enumeratorAtPath: @"/"
                                                                        options: NSDirectoryEnumerationSkipsHiddenFiles
                                                                   errorHandler: NULL];
    
    ADBOperation *scan = [ADBScanOperation scanWithEnumerator: enumerator
                                                   usingBlock: ^id(NSString *path, BOOL *stop)
    {
        //Don't scan nested drives. This allows for old-style gameboxes that treat the root folder of the gamebox as drive C. 
        if ([enumerator.filesystem typeOfFileAtPath: path matchingTypes: [BXFileTypes mountableFolderTypes]])
        {
            [enumerator skipDescendants];
            return nil;
        }
        else if ([BXFileTypes isCompatibleExecutableAtPath: path filesystem: enumerator.filesystem error: NULL])
        {
            return path;
        }
        else
        {
            return nil;
        }
    }];
    
    scan.delegate = self;
    scan.didFinishSelector = @selector(executableScanDidFinish:);
    scan.contextInfo = drive;
    
    if (start)
    {
        for (ADBOperation *otherScan in self.scanQueue.operations)
        {
            //Ignore completed scans
            if (otherScan.isFinished) continue;

            //If a scan for this drive is already in progress and hasn't been cancelled,
            //then use that scan instead.
            BXDrive *otherDrive = otherScan.contextInfo;
            
            if (!otherScan.isCancelled && [otherDrive isEqual: drive])
            {
                return otherScan;
            }
            
            //If there's a scan going on for the same path,
            //then make ours wait for that one to finish.
            else if ([otherDrive.mountPointURL isEqual: drive.mountPointURL])
                [scan addDependency: otherScan];
        }    

        [self willChangeValueForKey: @"isScanningForExecutables"];
        [self.scanQueue addOperation: scan];
        [self didChangeValueForKey: @"isScanningForExecutables"];
    }
    return scan;
}

- (BOOL) isScanningForExecutables
{
    for (NSOperation *scan in self.scanQueue.operations)
	{
		if (!scan.isFinished && !scan.isCancelled) return YES;
	}    
    return NO;
}

- (ADBOperation *) activeExecutableScanForDrive: (BXDrive *)drive
{
    for (ADBOperation *scan in self.scanQueue.operations)
	{
		if (scan.isExecuting && [scan.contextInfo isEqual: drive])
            return scan;
	}    
    return nil;
}

- (BOOL) cancelExecutableScanForDrive: (BXDrive *)drive
{
    BOOL didCancelScan = NO;
    for (ADBOperation *operation in self.scanQueue.operations)
	{
        //Ignore completed scans
        if (operation.isFinished) continue;
        
		if ([operation.contextInfo isEqual: drive])
        {
            [self willChangeValueForKey: @"isScanningForExecutables"];
            [operation cancel];
            [self didChangeValueForKey: @"isScanningForExecutables"];
            didCancelScan = YES;
        }
	}    
    return didCancelScan;
}

- (void) executableScanDidFinish: (NSNotification *)theNotification
{
    ADBScanOperation *scan = theNotification.object;
	BXDrive *drive = scan.contextInfo;
    
    [self willChangeValueForKey: @"isScanningForExecutables"];
	if (scan.succeeded && scan.matches.count)
	{
        //Construct logical URLs out of the filesystem-relative paths returned by the scan.
        NSMutableArray *driveExecutables = [NSMutableArray arrayWithCapacity: scan.matches.count];
        for (NSString *matchedPath in scan.matches)
        {
            NSURL *logicalURL = [drive.filesystem logicalURLForPath: matchedPath];
            if (logicalURL)
                [driveExecutables addObject: logicalURL];
            else
                NSLog(@"Filesystem %@ on drive %@ could not resolve executable path %@ to logical URL", drive.filesystem, drive, matchedPath);
        }
        
        //Only send notifications if any executables were found, to prevent unnecessary redraws
        BOOL notify = (driveExecutables.count > 0);
        
        //TODO: is there a better notification method we could use here?
        if (notify) [self willChangeValueForKey: @"executableURLs"];
        [_executableURLs setObject: [NSMutableArray arrayWithArray: driveExecutables]
                            forKey: drive.letter];
        if (notify) [self didChangeValueForKey: @"executableURLs"];
	}
    [self didChangeValueForKey: @"isScanningForExecutables"];
}

#pragma mark -
#pragma mark Drive importing

- (BOOL) driveIsBundled: (BXDrive *)drive
{
    if (self.hasGamebox)
    {
        NSURL *driveURL = drive.sourceURL;
        NSURL *bundleURL = self.gamebox.resourceURL;
        
        if ([driveURL isEqual: bundleURL] || [driveURL.URLByDeletingLastPathComponent isEqual: bundleURL])
            return YES;
    }
	return NO;
}

- (BOOL) equivalentDriveIsBundled: (BXDrive *)drive
{
	if (self.hasGamebox)
	{
		Class importClass = [BXDriveImport importClassForDrive: drive];
        if (importClass)
        {
            NSString *importedName	= [importClass nameForDrive: drive];
            NSURL *importedURL      = [self.gamebox.resourceURL URLByAppendingPathComponent: importedName];
            
            //A file already exists with the same name as we would import it with,
            //which probably means the drive was bundled earlier
            return [importedURL checkResourceIsReachableAndReturnError: NULL];
        }
	}
	return NO;
}

- (ADBOperation <BXDriveImport> *) activeImportOperationForDrive: (BXDrive *)drive
{
	for (ADBOperation <BXDriveImport> *import in self.importQueue.operations)
	{
		if (import.isExecuting && [import.drive isEqual: drive])
            return import;
	}
	return nil;
}

- (BOOL) canImportDrive: (BXDrive *)drive
{
	//Don't import drives if:
	//...we're not running a gamebox
	if (!self.hasGamebox) return NO;
	
	//...the drive is one of our own internal drives
	if (drive.isVirtual || drive.isHidden) return NO;
	
	//...the drive is currently being imported or is already bundled in the current gamebox
	if ([self activeImportOperationForDrive: drive] ||
		[self driveIsBundled: drive]) return NO;
	
	//Otherwise, go for it!
	return YES;
}

- (ADBOperation <BXDriveImport> *) importOperationForDrive: (BXDrive *)drive
                                          startImmediately: (BOOL)start
{
	if ([self canImportDrive: drive])
	{
		ADBOperation <BXDriveImport> *driveImport = [BXDriveImport importOperationForDrive: drive
                                                                      destinationFolderURL: self.gamebox.resourceURL
                                                                                 copyFiles: YES];
		
		driveImport.delegate = self;
		driveImport.didFinishSelector = @selector(driveImportDidFinish:);
    	
		if (start)
        {
            [self startImportOperation: driveImport];
        }
        
		return driveImport;
	}
	else
	{
		return nil;
	}
}

- (void) startImportOperation: (ADBOperation <BXDriveImport> *)operation
{
    //If we'll lose access to the drive during importing,
    //eject it but leave it in the drive queue: and make
    //a note to remount it afterwards.
    if ([self driveIsMounted: operation.drive] && [operation.class driveUnavailableDuringImport])
    {
        [self unmountDrive: operation.drive
                   options: BXDriveForceUnmounting | BXDriveReplaceWithSiblingFromQueue
                     error: nil];
        
        operation.contextInfo = @{ @"remountAfterImport": @(YES) };
    }
    
    [self.importQueue addOperation: operation];
}

- (BOOL) cancelImportForDrive: (BXDrive *)drive
{
	for (ADBOperation <BXDriveImport> *import in self.importQueue.operations)
	{
		if (!import.isFinished && [import.drive isEqual: drive])
		{
			[import cancel];
			return YES;
		}
	}
	return NO;
}

- (BOOL) isImportingDrives
{
    for (NSOperation *import in self.importQueue.operations)
	{
		if (!import.isFinished && !import.isCancelled) return YES;
	}    
    return NO;
}

- (void) driveImportDidFinish: (NSNotification *)theNotification
{
	ADBOperation <BXDriveImport> *import = theNotification.object;
	BXDrive *originalDrive = import.drive;
    
    BOOL remountDrive = [[import.contextInfo objectForKey: @"remountAfterImport"] boolValue];

	if (import.succeeded)
	{
		//Once the drive has successfully imported, replace the old drive
		//with the newly-imported version (as long as the old one is not currently in use)
		if (![self.emulator driveInUse: originalDrive])
		{
            BXDrive *importedDrive = [BXDrive driveWithContentsOfURL: import.destinationURL
                                                              letter: originalDrive.letter
                                                                type: originalDrive.type];
			
            //Make the new drive an alias for the old one.
            [importedDrive addEquivalentURL: originalDrive.sourceURL];
            [importedDrive addEquivalentURL: originalDrive.mountPointURL];
            
            //If the old drive is currently mounted, or was mounted back when we started,
            //then replace it entirely.
			if (remountDrive || [self driveIsMounted: originalDrive])
            {
                //Mount the new drive without showing notification
                //or bothering to check for backing images.
                //Note that this will automatically fail if the old
                //drive is still in use.
                NSError *mountError = nil;
                BXDrive *mountedDrive = [self mountDrive: importedDrive
                                                ifExists: BXDriveReplace
                                                 options: BXBundledDriveMountOptions
                                                   error: &mountError];
                
                //Remove the old drive from the queue, once we've mounted the new one.
                if (mountedDrive)
                {
                    [self replaceQueuedDrive: originalDrive
                                   withDrive: mountedDrive];
                }
            }
            //Otherwise, just replace the original drive in the same position in its queue.
            else
            {
                [self replaceQueuedDrive: originalDrive
                               withDrive: importedDrive];
            }
		}
		
		//If we're active, display a notification that this drive was successfully imported.
        if ([NSApp isActive])
        {
            [[BXBezelController controller] showDriveImportedBezelForDrive: originalDrive
                                                                 toGamebox: self.gamebox];
        }
        //Otherwise, display a user notification to that effect.
        else if ([ADBUserNotificationDispatcher userNotificationsAvailable])
        {
            NSUserNotification *notification = [[NSUserNotification alloc] init];
            
            NSString *driveImportFormat = NSLocalizedString(@"Drive %@ imported",
                                                            @"Subtitle of notification shown when a drive has finished importing. %@ is the letter of the drive.");
            
            notification.title = self.displayName;
            notification.subtitle = [NSString stringWithFormat: driveImportFormat, originalDrive.letter];
            
            ADBUserNotificationActivationHandler activationHandler = ^(NSUserNotification *deliveredNotification) {
                [[ADBUserNotificationDispatcher dispatcher] removeNotification: deliveredNotification];
                [[BXInspectorController controller] showDrivesPanel: self];
            };
            
            [[ADBUserNotificationDispatcher dispatcher] scheduleNotification: notification
                                                                      ofType: BXDriveImportedNotificationType
                                                                  fromSender: self
                                                                onActivation: activationHandler];
            
        }
	}
    
	else if (import.error)
	{
        //Remount the original drive, if it was unmounted as a result of the import
        if (remountDrive)
        {
            NSError *mountError = nil;
            [self mountDrive: originalDrive
                    ifExists: BXDriveReplace
                     options: 0 //TODO: write this up as a proper constant
                       error: &mountError];
        }
		
        //Display a sheet for the error, unless it was just the user cancelling
		if (import.error && !import.error.isUserCancelledError)
		{
			[self presentError: import.error
				modalForWindow: self.windowForDriveSheet
					  delegate: nil
			didPresentSelector: NULL
				   contextInfo: NULL];
		}
	}
}


#pragma mark - Monitoring filesystem changes

- (void) _applicationDidBecomeActive: (NSNotification *)notification
{
    //Clear the DOS directory cache whenever the user refocuses the application,
    //in case filesystem changes were made while we were in the background.
    [self.emulator refreshMountedDrives];
    
    //If the gamebox has a documentation folder, rescan that too:
    //in case the user has added, removed or renamed documentation files.
    if (self.gamebox.hasDocumentationFolder)
    {
        [self.gamebox refreshDocumentation];
    }
}


#pragma mark - Captures

- (NSURL *) URLForCaptureOfType: (NSString *)typeDescription fileExtension: (NSString *)extension
{
    NSString *descriptiveSuffix = @"";
    //Remap certain of DOSBox's file type suggestions.
    if ([typeDescription isEqualToString: @"Parallel Port Stream"]) //Parallel-port dumps
    {
        descriptiveSuffix = @" LPT output";
        extension = @"txt";
    }
    
    //Work out an appropriate filename, based on the title of the session and the current date and time.
    NSValueTransformer *transformer = [NSValueTransformer valueTransformerForName: @"BXCaptureDateTransformer"];
    NSString *formattedDate = [transformer transformedValue: [NSDate date]];
    
    NSString *nameFormat = NSLocalizedString(@"%1$@%2$@ %3$@",
                                             @"Filename pattern for captures: %1$@ is the display name of the DOS session, %2$@ is the type of capture being created, %3$@ is the current date and time in a notation suitable for chronologically-ordered filenames.");
    
    //Name the captured file after the current gamebox, or - failing that - the application itself.
    NSString *sessionName = self.displayName;
    if (sessionName.length == 0)
        sessionName = [BXBaseAppController appName];
    
    NSString *baseName = [NSString stringWithFormat: nameFormat, sessionName, descriptiveSuffix, formattedDate];
    NSString *fileName = [baseName stringByAppendingPathExtension: extension];
    
    
    //Sanitise the filename in case it contains characters that are disallowed for file paths.
    //TODO: move this off to an NSFileManager/NSString category.
    fileName = [fileName stringByReplacingOccurrencesOfString: @":" withString: @"-"];
    fileName = [fileName stringByReplacingOccurrencesOfString: @"/" withString: @"-"];
    
    NSURL *baseURL = [(BXBaseAppController *)[NSApp delegate] recordingsURLCreatingIfMissing: YES error: NULL];
    NSURL *destinationURL = [baseURL URLByAppendingPathComponent: fileName];
    
    return destinationURL;
}

- (FILE *) emulator: (BXEmulator *)emulator openCaptureFileOfType: (NSString *)captureType extension: (NSString *)extension
{
    NSURL *URL = [self URLForCaptureOfType: captureType fileExtension: extension];
    if (URL != nil)
    {
        const char *fsRepresentation = URL.fileSystemRepresentation;
        FILE *handle = fopen(fsRepresentation, "wb");
        //TODO: should we hide the file extension for common file types like txt and png?
        return handle;
    }
    else
    {
        return nil;
    }
}

@end
