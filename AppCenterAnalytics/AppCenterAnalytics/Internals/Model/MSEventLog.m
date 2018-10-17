#import "AppCenter+Internal.h"
#import "MSAnalyticsConstants.h"
#import "MSAnalyticsInternal.h"
#import "MSBooleanTypedProperty.h"
#import "MSConstants+Internal.h"
#import "MSCSData.h"
#import "MSCSExtensions.h"
#import "MSCSModelConstants.h"
#import "MSConstants+Internal.h"
#import "MSDateTimeTypedProperty.h"
#import "MSDoubleTypedProperty.h"
#import "MSEventLogPrivate.h"
#import "MSEventPropertiesInternal.h"
#import "MSLongTypedProperty.h"
#import "MSMetadataExtension.h"
#import "MSStringTypedProperty.h"

static NSString *const kMSTypeEvent = @"event";

static NSString *const kMSId = @"id";

static NSString *const kMSTypedProperties = @"typedProperties";

@implementation MSEventLog

- (instancetype)init {
  if ((self = [super init])) {
    self.type = kMSTypeEvent;
    _metadataTypeIdMapping = @{
      kMSLongTypedPropertyType : @(kMSLongMetadataTypeId),
      kMSDoubleTypedPropertyType : @(kMSDoubleMetadataTypeId),
      kMSDateTimeTypedPropertyType : @(kMSDateTimeMetadataTypeId)
    };
  }
  return self;
}

- (NSMutableDictionary *)serializeToDictionary {
  NSMutableDictionary *dict = [super serializeToDictionary];
  if (self.eventId) {
    dict[kMSId] = self.eventId;
  }
  if (self.typedProperties) {
    dict[kMSTypedProperties] = [self.typedProperties serializeToArray];
  }
  return dict;
}

- (BOOL)isValid {
  return [super isValid] && self.eventId;
}

- (BOOL)isEqual:(id)object {
  if (![(NSObject *)object isKindOfClass:[MSEventLog class]] || ![super isEqual:object]) {
    return NO;
  }
  MSEventLog *eventLog = (MSEventLog *)object;
  return ((!self.eventId && !eventLog.eventId) || [self.eventId isEqualToString:eventLog.eventId]);
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    _eventId = [coder decodeObjectForKey:kMSId];
    _typedProperties = [coder decodeObjectForKey:kMSTypedProperties];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [super encodeWithCoder:coder];
  [coder encodeObject:self.eventId forKey:kMSId];
  [coder encodeObject:self.typedProperties forKey:kMSTypedProperties];
}

#pragma mark - MSAbstractLog

- (MSCommonSchemaLog *)toCommonSchemaLogForTargetToken:(NSString *)token {
  MSCommonSchemaLog *csLog = [super toCommonSchemaLogForTargetToken:token];

  // Event name goes to part A.
  csLog.name = self.name;

  // Metadata extension must accompany data.
  // Event properties goes to part C.
  csLog.data = [MSCSData new];
  csLog.ext.metadataExt = [MSMetadataExtension new];
  [self setPropertiesAndMetadataForCSLog:csLog];
  return csLog;
}

#pragma mark - Helper

- (void)setPropertiesAndMetadataForCSLog:(MSCommonSchemaLog *)csLog {
  NSMutableDictionary *csProperties;
  NSMutableDictionary *metadata;
  if (self.typedProperties) {
    csProperties = [NSMutableDictionary new];
    metadata = [NSMutableDictionary new];
    for (MSTypedProperty *typedProperty in [self.typedProperties.properties objectEnumerator]) {

      // Properties keys are mixed up with other keys from Data, make sure they don't conflict.
      if ([typedProperty.name isEqualToString:kMSDataBaseData] || [typedProperty.name isEqualToString:kMSDataBaseDataType]) {
        MSLogWarning(MSAnalytics.logTag, @"Cannot use %@ in properties, skipping that property.", typedProperty.name);
        continue;
      }
      [self addTypedProperty:typedProperty toCSMetadata:metadata AndCSProperties:csProperties];
    }
  }
  if (csProperties.count != 0) {
    csLog.data.properties = csProperties;
  }
  if (metadata.count != 0) {
    csLog.ext.metadataExt.metadata = metadata;
  }
}

- (void)addTypedProperty:(MSTypedProperty *)typedProperty toCSMetadata:(NSMutableDictionary *)csMetadata AndCSProperties:(NSMutableDictionary *)csProperties {
  NSNumber *typeId = self.metadataTypeIdMapping[typedProperty.type];

  // If the key contains a '.' then it's nested objects (i.e: "a.b":"value" => {"a":{"b":"value"}}).
  NSArray *csKeys = [typedProperty.name componentsSeparatedByString:@"."];
  NSMutableDictionary *propertyTree = csProperties;
  NSMutableDictionary *metadataTree = csMetadata;

  /*
   * Keep track of the subtree that contains all the metadata levels added in the for loop.
   * Thus if it needs to be removed, a second traversal is not needed.
   * The metadata should be cleaned up if the property is not added due to a key collision.
   */
  NSMutableDictionary *metadataSubtreeParent = nil;
  for (NSUInteger i = 0; i < csKeys.count - 1; i++) {
    
    // If there is no field delimiter for this level in the metadata tree, create one.
    if (typeId && !metadataTree[kMSFieldDelimiter]) {
      metadataSubtreeParent = metadataSubtreeParent?: metadataTree;
      metadataTree[kMSFieldDelimiter] = [NSMutableDictionary new];
    }
    NSMutableDictionary *propertySubtree = nil;
    NSMutableDictionary *metadataSubtree = nil;
    id key = csKeys[i];
    if ([(NSObject *) propertyTree[key] isKindOfClass:[NSMutableDictionary class]]) {
      propertySubtree = propertyTree[key];
      metadataSubtree = metadataTree[kMSFieldDelimiter][key];
      if (typeId && !metadataSubtree) {
        metadataSubtree = [NSMutableDictionary new];
        metadataTree[kMSFieldDelimiter][key] = metadataSubtree;
      }
    }
    if (!propertySubtree) {
      if (propertyTree[key]) {
        propertyTree = nil;
        break;
      }
      propertySubtree = [NSMutableDictionary new];
      propertyTree[key] = propertySubtree;
      if (typeId) {
        metadataSubtree = [NSMutableDictionary new];
        metadataTree[kMSFieldDelimiter][key] = metadataSubtree;
      }
    }
    propertyTree = propertySubtree;
    metadataTree = metadataSubtree;
  }
  id lastKey = csKeys.lastObject;
  BOOL didAddTypedProperty = [self addTypedProperty:typedProperty toPropertyTree:propertyTree withKey:lastKey];
  if (typeId && didAddTypedProperty) {

    // If there is no field delimiter for this level in the metadata tree, create one.
    if (!metadataTree[kMSFieldDelimiter]) {
      metadataTree[kMSFieldDelimiter] = [NSMutableDictionary new];
    }
    metadataTree[kMSFieldDelimiter][lastKey] = typeId;
  } else if (metadataSubtreeParent) {
    [metadataSubtreeParent removeObjectForKey:kMSFieldDelimiter];
  }
}

- (BOOL)addTypedProperty:(MSTypedProperty *)typedProperty toPropertyTree:(NSMutableDictionary *)propertyTree withKey:(NSString *)key {
  if (!propertyTree || propertyTree[key]) {
    MSLogWarning(MSAnalytics.logTag, @"Property key '%@' already has a value, choosing one.", key);
    return NO;
  }
  if ([typedProperty isKindOfClass:[MSStringTypedProperty class]]) {
    MSStringTypedProperty *stringProperty = (MSStringTypedProperty *) typedProperty;
    propertyTree[key] = stringProperty.value;
  } else if ([typedProperty isKindOfClass:[MSBooleanTypedProperty class]]) {
    MSBooleanTypedProperty *boolProperty = (MSBooleanTypedProperty *) typedProperty;
    propertyTree[key] = @(boolProperty.value);
  } else if ([typedProperty isKindOfClass:[MSLongTypedProperty class]]) {
    MSLongTypedProperty *longProperty = (MSLongTypedProperty *) typedProperty;
    propertyTree[key] = @(longProperty.value);
  } else if ([typedProperty isKindOfClass:[MSDoubleTypedProperty class]]) {
    MSDoubleTypedProperty *doubleProperty = (MSDoubleTypedProperty *) typedProperty;
    propertyTree[key] = @(doubleProperty.value);
  } else if ([typedProperty isKindOfClass:[MSDateTimeTypedProperty class]]) {
    MSDateTimeTypedProperty *dateProperty = (MSDateTimeTypedProperty *) typedProperty;
    propertyTree[key] = [MSUtility dateToISO8601:dateProperty.value];
  }
  return YES;
}

@end
