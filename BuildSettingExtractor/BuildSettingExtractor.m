//
//  BuildSettingExtractor.m
//  BuildSettingExtractor
//
//  Created by James Dempsey on 1/30/15.
//  Copyright (c) 2015 Tapas Software. All rights reserved.
//

#import "BuildSettingExtractor.h"
#import "BuildSettingInfoSource.h"
#import "Constants+Categories.h"

static NSSet *XcodeCompatibilityVersionStringSet() {
    static NSSet *_compatibilityVersionStringSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _compatibilityVersionStringSet = [NSSet setWithObjects:@"Xcode 3.2", @"Xcode 6.3", @"Xcode 8.0", @"Xcode 9.3", @"Xcode 10.0", @"Xcode 11.0", nil];
    });
    return _compatibilityVersionStringSet;
}

@interface BuildSettingExtractor ()
@property (strong) NSMutableDictionary *buildSettingsByTarget;
@property (strong) NSDictionary *objects;
@property BOOL extractionSuccessful;

@property (strong) BuildSettingInfoSource *buildSettingInfoSource;
@end

@implementation BuildSettingExtractor

+ (NSString *)defaultSharedConfigName {
    return @"Shared";
}

+ (NSString *)defaultProjectConfigName {
    return @"Project";
}

+ (NSString *)defaultNameSeparator {
    return @"-";
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sharedConfigName = [[self class] defaultSharedConfigName];
        _projectConfigName = [[self class] defaultProjectConfigName];
        _nameSeparator = [[self class] defaultNameSeparator];
        _buildSettingsByTarget = [[NSMutableDictionary alloc] init];
        _buildSettingInfoSource = [[BuildSettingInfoSource alloc] init];
        _extractionSuccessful = NO;
    }
    return self;
}

/* Given a dictionary and key whose value is an array of object identifiers, return the identified objects in an array */
- (NSArray *)objectArrayForDictionary:(NSDictionary *)dict key:(NSString *)key {
    NSArray *identifiers = dict[key];
    NSMutableArray *objectArray = [[NSMutableArray alloc] init];
    for (NSString *identifier in identifiers) {
        id obj = self.objects[identifier];
        [objectArray addObject:obj];
    }
    return objectArray;
}

- (NSArray *)extractBuildSettingsFromProject:(NSURL *)projectWrapperURL error:(NSError **)error {

    NSMutableArray *nonFatalErrors = [[NSMutableArray alloc] init];
    
    [self.buildSettingsByTarget removeAllObjects];

    NSURL *projectFileURL = [projectWrapperURL URLByAppendingPathComponent:@"project.pbxproj"];

    NSData *fileData = [NSData dataWithContentsOfURL:projectFileURL options:0 error:error];
    if (!fileData) {
        return nil;
    }
        
    NSDictionary *projectPlist = [NSPropertyListSerialization propertyListWithData:fileData options:NSPropertyListImmutable format:NULL error:error];
    if (!projectPlist) {
        return nil;
    }
            
    // Get root object (project)
    self.objects = projectPlist[@"objects"];
    NSDictionary *rootObject = self.objects[projectPlist[@"rootObject"]];

    // Check compatibility version
    NSString *compatibilityVersion = rootObject[@"compatibilityVersion"];
    if (![XcodeCompatibilityVersionStringSet() containsObject:compatibilityVersion]) {
        NSDictionary *userInfo = @{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Unable to extract build settings from project ‘%@’.", [[projectWrapperURL lastPathComponent] stringByDeletingPathExtension]], NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"Project file format version ‘%@’ is not supported.", compatibilityVersion]};
        if (error) {
            *error = [NSError errorWithDomain:[[NSBundle mainBundle] bundleIdentifier] code:UnsupportedXcodeVersion userInfo:userInfo];
        }
        return nil;
    }
            
    // Get project targets
    NSArray *targets = [self objectArrayForDictionary:rootObject key:@"targets"];
    
    // Validate project config name to guard against name conflicts with target names
    NSError *nameValdationError = nil;
    NSArray *targetNames = [targets valueForKeyPath:@"name"];
    NSString *validatedProjectConfigName = [self validatedProjectConfigNameWithTargetNames:targetNames error: &nameValdationError];
    
    if (nameValdationError) {
        [nonFatalErrors addObject:nameValdationError];
    }
    
    // Get project settings
    NSString *buildConfigurationListID = rootObject[@"buildConfigurationList"];
    NSDictionary *projectSettings = [self buildSettingStringsByConfigurationForBuildConfigurationListID:buildConfigurationListID];

    self.buildSettingsByTarget[validatedProjectConfigName] = projectSettings;
    
    // Begin check that the project file has some settings
    BOOL projectFileHasSettings = projectSettings.containsBuildSettings;

    // Add project targets
    for (NSDictionary *target in targets) {
        NSString *targetName = target[@"name"];
        buildConfigurationListID = target[@"buildConfigurationList"];
        NSDictionary *targetSettings = [self buildSettingStringsByConfigurationForBuildConfigurationListID:buildConfigurationListID];
        if (!projectFileHasSettings) { projectFileHasSettings = targetSettings.containsBuildSettings; }

        self.buildSettingsByTarget[targetName] = targetSettings;

    }
    
    if (!projectFileHasSettings) {
        if (error) {
            *error = [NSError errorForNoSettingsFoundInProject: [projectWrapperURL lastPathComponent]];
        }
        return nil;
    }


    self.extractionSuccessful = YES;
    return nonFatalErrors;
}

// This will return a validated project config name to guard against naming conflicts with targets
// If a conflict is found, the project config files will have "-Project-Settings" appended to the
// provided project config name, using the user-specified name separator between words.
- (NSString *)validatedProjectConfigNameWithTargetNames:(NSArray *)targetNames error:(NSError **)error {
    NSString *validatedProjectConfigName = self.projectConfigName;
    if ([targetNames containsObject:self.projectConfigName]) {
        validatedProjectConfigName = [validatedProjectConfigName stringByAppendingFormat:@"%@Project%@Settings", self.nameSeparator, self.nameSeparator];
        if (error) {
            *error = [NSError errorForNameConflictWithName:self.projectConfigName validatedName:validatedProjectConfigName];
        }
    }
    return validatedProjectConfigName;
}

/* Writes an xcconfig file for each target / configuration combination to the specified directory.
 */
- (BOOL)writeConfigFilesToDestinationFolder:(NSURL *)destinationURL error:(NSError **)error {
    
    // It is a programming error to try to write before extracting or to call this method after extracting build settings has failed.
    if (!self.extractionSuccessful) {
        [NSException raise:NSInternalInconsistencyException format:@"The method -writeConfigFilesToDestinationFolder:error: was called before successful completion of -extractBuildSettingsFromProject:error:. Callers of this method must call -extractBuildSettingsFromProject:error: first and check for a non-nil return value indicating success."];
    }

    __block BOOL success = YES;
    __block NSError *blockError = nil;
    
    [self.buildSettingsByTarget enumerateKeysAndObjectsUsingBlock:^(id targetName, id obj, BOOL *stop) {
        [obj enumerateKeysAndObjectsUsingBlock:^(id configName, id settings, BOOL *stop) {

            NSString *filename = [self configFilenameWithTargetName:targetName configName:configName];

            NSString *configFileString = @"";

            // Add header comment
            NSString *headerComment = [self headerCommentForFilename:filename];
            if (headerComment) {
                configFileString = [configFileString stringByAppendingString:headerComment];
            }

            // If the config name is not the shared config, we need to import the shared config
            if (![configName isEqualToString:self.sharedConfigName]) {
                NSString *configFilename = [self configFilenameWithTargetName:targetName configName:self.sharedConfigName];
                NSString *includeDirective = [NSString stringWithFormat:@"\n\n#include \"%@\"", configFilename];
                configFileString = [configFileString stringByAppendingString:includeDirective];
            }

            // If there are no settings at all, add a comment that the lack of settings is on purpose
            if ([settings isEqualToString:@""]) {
                settings = [settings stringByAppendingString:@"\n\n"];
                settings = [settings stringByAppendingString:@"//********************************************//\n"];
                settings = [settings stringByAppendingString:@"//* Currently no build settings in this file *//\n"];
                settings = [settings stringByAppendingString:@"//********************************************//"];

                ;
            }

            configFileString = [configFileString stringByAppendingString:settings];

            // Trim whitespace and newlines
            configFileString = [configFileString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];


            NSURL *fileURL = [destinationURL URLByAppendingPathComponent:filename];

            success = [configFileString writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&blockError];
            if (!success) {
                *stop = YES;
            }
        }];
    }];
    
    if (!success && error) {
        *error = blockError;
    }
    
    return success;
}

// Given the target name and config name returns the xcconfig filename to be used.
- (NSString *)configFilenameWithTargetName:(NSString *)targetName configName:(NSString *)configName {
    NSString *separator = configName.length ? self.nameSeparator: @"";
    return [NSString stringWithFormat:@"%@%@%@.xcconfig", targetName, separator, configName];
}

// Given the filename generate the header comment
- (NSString *)headerCommentForFilename:(NSString *)filename {
    NSString *headerComment = @"";

    NSString *dateString = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];

    headerComment = [headerComment stringByAppendingString:@"//\n"];
    headerComment = [headerComment stringByAppendingFormat:@"// %@\n", filename];
    headerComment = [headerComment stringByAppendingString:@"//\n"];
    headerComment = [headerComment stringByAppendingFormat:@"// Generated by BuildSettingExtractor on %@\n", dateString];
    headerComment = [headerComment stringByAppendingString:@"// https://github.com/dempseyatgithub/BuildSettingExtractor\n"];
    headerComment = [headerComment stringByAppendingString:@"//"];

    return headerComment;
}


/* Given a build setting dictionary, returns a string representation of the build settings, suitable for an xcconfig file. */
- (NSString *)stringRepresentationOfBuildSettings:(NSDictionary *)buildSettings {
    NSMutableString *string = [[NSMutableString alloc] init];

    // Sort build settings by name for easier reading and testing. Case insensitive compare should stay stable regardess of locale.
    NSArray *sortedKeys = [[buildSettings allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];

    BOOL firstKey = YES;
    for (NSString *key in sortedKeys) {
        id value = buildSettings[key];

        if (self.includeBuildSettingInfoComments) {
            NSString *comment = [self.buildSettingInfoSource commentForBuildSettingWithName:key];
            [string appendString:comment];
        } else {
            if (firstKey) {
                [string appendString:@"\n\n"]; // Tack on some space before first setting, if there are no info comments
                firstKey = NO;
            }
        }

        if ([value isKindOfClass:[NSString class]]) {
            [string appendFormat:@"%@ = %@\n", key, value];

        } else if ([value isKindOfClass:[NSArray class]]) {
            [string appendFormat:@"%@ = %@\n", key, [value componentsJoinedByString:@" "]];
        } else {
            [NSException raise:@"Should not get here!" format:@"Unexpected class: %@ in %s", [value class], __PRETTY_FUNCTION__];
        }

    }
    
    return string;
}

/* Given a build configuration list ID, retrieves the list of build configurations, consolidates shared build settings into a shared configuration and returns a dictionary of build settings configurations as strings, keyed by configuration name. */
- (NSDictionary *)buildSettingStringsByConfigurationForBuildConfigurationListID:(NSString *)buildConfigurationListID {

    // Get the array of build configuration objects for the build configuration list ID
    NSDictionary *buildConfigurationList = self.objects[buildConfigurationListID];
    NSArray *projectBuildConfigurations = [self objectArrayForDictionary:buildConfigurationList key:@"buildConfigurations"];


    NSDictionary *buildSettingsByConfiguration = [self buildSettingsByConfigurationForConfigurations:projectBuildConfigurations];

    // Turn each build setting into a build setting string. Store by configuration name
    NSMutableDictionary *buildSettingStringsByConfiguration = [[NSMutableDictionary alloc] init];
    [buildSettingsByConfiguration enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *buildSettingsString = [self stringRepresentationOfBuildSettings:obj];
        [buildSettingStringsByConfiguration setValue:buildSettingsString forKey:key];

    }];
    return buildSettingStringsByConfiguration;

}


/* Given an array of build configuration dictionaries, removes common build settings into a shared build configuration and returns a dictionary of build settings dictionaries, keyed by configuration name.
 */
- (NSDictionary *)buildSettingsByConfigurationForConfigurations:(NSArray *)buildConfigurations {

    NSMutableDictionary *buildSettingsByConfiguration = [[NSMutableDictionary alloc] init];

    NSMutableDictionary *sharedBuildSettings = [[NSMutableDictionary alloc] init];
    NSDictionary *firstBuildSettings = nil;
    NSInteger index = 0;

    for (NSDictionary *buildConfiguration in buildConfigurations) {

        NSDictionary *buildSettings = buildConfiguration[@"buildSettings"];

        // Use first build settings as a starting point, represents all settings after first iteration
        if (index == 0) {
            firstBuildSettings = buildSettings;

        }

        // Second iteration, compare second against first build settings to come up with common items
        else if (index == 1){
            [firstBuildSettings enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                id otherObj = buildSettings[key];
                if ([obj isEqualTo:otherObj]) {
                    sharedBuildSettings[key] = obj;
                }
            }];
        }

        // Subsequent iteratons, remove common items that don't match current config settings
        else {
            [[sharedBuildSettings copy] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                id otherObj = buildSettings[key];
                if (![obj isEqualTo:otherObj]) {
                    [sharedBuildSettings removeObjectForKey:key];
                }
            }];
        }

        index++;
    }

    [buildSettingsByConfiguration setValue:sharedBuildSettings forKey:self.sharedConfigName];

    NSArray *sharedKeys = [sharedBuildSettings allKeys];
    for (NSDictionary *projectBuildConfiguration in buildConfigurations) {
        NSString *configName = projectBuildConfiguration[@"name"];
        NSMutableDictionary *buildSettings = projectBuildConfiguration[@"buildSettings"];
        [buildSettings removeObjectsForKeys:sharedKeys];
        [buildSettingsByConfiguration setValue:buildSettings forKey:configName];
        
    }
    
    return buildSettingsByConfiguration;
}

@end
