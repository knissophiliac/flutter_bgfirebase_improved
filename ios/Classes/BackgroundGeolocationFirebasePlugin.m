#import "BackgroundGeolocationFirebasePlugin.h"

#import <CoreLocation/CoreLocation.h>
#import "Firebase.h"

static NSString *const PLUGIN_PATH = @"com.transistorsoft/flutter_background_geolocation_firebase";
static NSString *const METHOD_CHANNEL_NAME      = @"methods";

static NSString *const ACTION_CONFIGURE = @"configure";

static NSString *const PERSIST_EVENT                = @"TSLocationManager:PersistEvent";

static NSString *const FIELD_LOCATIONS_COLLECTION = @"locationsCollection";
static NSString *const FIELD_GEOFENCES_COLLECTION = @"geofencesCollection";
static NSString *const FIELD_UPDATE_SINGLE_DOCUMENT = @"updateSingleDocument";

static NSString *const DEFAULT_LOCATIONS_COLLECTION = @"locations";
static NSString *const DEFAULT_GEOFENCES_COLLECTION = @"geofences";


@implementation BackgroundGeolocationFirebasePlugin {
    BOOL isRegistered;
}


+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    NSString *methodPath = [NSString stringWithFormat:@"%@/%@", PLUGIN_PATH, METHOD_CHANNEL_NAME];
    FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:methodPath binaryMessenger:[registrar messenger]];

    BackgroundGeolocationFirebasePlugin* instance = [[BackgroundGeolocationFirebasePlugin alloc] init];
    [registrar addApplicationDelegate:instance];
    [registrar addMethodCallDelegate:instance channel:channel];
}

-(instancetype) init {
    self = [super init];
    if (self) {
        isRegistered = NO;
        _locationsCollection = DEFAULT_LOCATIONS_COLLECTION;
        _geofencesCollection = DEFAULT_GEOFENCES_COLLECTION;
        _updateSingleDocument = NO;
    }

    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([self method:call.method is:ACTION_CONFIGURE]) {
        [self configure:call.arguments result:result];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

-(void) configure:(NSDictionary*)config result:(FlutterResult)result {
    if (config[FIELD_LOCATIONS_COLLECTION]) {
        _locationsCollection = config[FIELD_LOCATIONS_COLLECTION];
    }
    if (config[FIELD_GEOFENCES_COLLECTION]) {
        _geofencesCollection = config[FIELD_GEOFENCES_COLLECTION];
    }
    if (config[FIELD_UPDATE_SINGLE_DOCUMENT]) {
        _updateSingleDocument = [config[FIELD_UPDATE_SINGLE_DOCUMENT] boolValue];
    }

    if (!isRegistered) {
        isRegistered = YES;
        
        // TODO make configurable.
        FIRFirestore *db = [FIRFirestore firestore];
        FIRFirestoreSettings *settings = [db settings];
        [db setSettings:settings];

        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(onPersist:)
            name:PERSIST_EVENT
            object:nil];
    }
    result(@(YES));
}

-(void) onPersist:(NSNotification*)notification {
    NSDictionary *data = notification.object;
    NSString *collectionName = (data[@"location"][@"geofence"]) ? _geofencesCollection : _locationsCollection;
    NSArray *items = [collectionName componentsSeparatedByString:@"/"];
    NSString *userId = [items objectAtIndex:1]; 
    NSString *userDocumentPath = [NSString stringWithFormat:@"%@/%@", @"users", userId];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        FIRDatabase *realtime = [FIRDatabase database];
        
        NSDictionary *dict = @{ @"locData" : @{
                                    @"lat" : data[@"location"][@"coords"][@"latitude"],
                                    @"lng" : data[@"location"][@"coords"][@"longitude"],
                                    @"batteryLevel" : data[@"location"][@"battery"][@"level"]
                                },
                                @"locTime" : [FIRServerValue timestamp]
        };
        //FIRFirestore *db = [FIRFirestore firestore];
        
        // Add a new document with a generated ID
        if (!self.updateSingleDocument) {
            FIRDatabaseReference *realtimeRef = [realtime reference];
            NSString *lastLatKey = @"flutter.last_lat";
            NSString *lastLongKey = @"flutter.last_long";
            NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:appDomain];

            //Get old ones
            NSNumber *lastLat;
            if(prefs[lastLatKey] == nil){
                lastLat = @0.0;
            }else{
                lastLat = prefs[lastLatKey];
            }
            NSNumber *lastLong;
            if(prefs[lastLongKey] == nil){
                lastLong = @0.0;
            }else{
                lastLong = prefs[lastLongKey];
            }
            NSNumber *newLat = data[@"location"][@"coords"][@"latitude"];
            NSNumber *newLong = data[@"location"][@"coords"][@"longitude"];

            CLLocation *oldLocation =  [[CLLocation alloc] initWithLatitude:lastLat.doubleValue longitude:lastLong.doubleValue];
            CLLocation *newLocation =  [[CLLocation alloc] initWithLatitude:newLat.doubleValue longitude:newLong.doubleValue];

            CLLocationDistance distanceInMeters = [oldLocation distanceFromLocation:newLocation];

            NSNumber *minDistanceInMeters = @20.0;
            
            //if both are 0.0 or distance>20meter
            if(([lastLat  isEqual: @0.0] && [lastLong  isEqual: @0.0]) || distanceInMeters > minDistanceInMeters.doubleValue){
                //ancak ve ancak büyükse trackine ekle, ve eklediysen shared prefe yaz
                [[[realtimeRef child:collectionName] childByAutoId] setValue:dict withCompletionBlock:^(NSError *error, FIRDatabaseReference *ref) {
                    if (error) {
                        NSLog(@"Data could not be saved: %@", error);
                    } else {
                        NSLog(@"Data saved successfully.");
                        //TODO set last_lat last_long into shared prefs
                        [[NSUserDefaults standardUserDefaults] setDouble:newLat.doubleValue forKey:lastLatKey];
                        [[NSUserDefaults standardUserDefaults] setDouble:newLong.doubleValue forKey:lastLongKey];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                    }
                }];
            }
            
            [[realtimeRef child:userDocumentPath] setValue:dict withCompletionBlock:^(NSError *error, FIRDatabaseReference *ref) {
                if (error) {
                    NSLog(@"Data could not be saved: %@", error);
                } else {
                    NSLog(@"Data saved successfully.");
                }
            }];


            /* __block FIRDocumentReference *ref = [[db collectionWithPath:collectionName] addDocumentWithData:dict completion:^(NSError * _Nullable error) {
                if (error != nil) {
                    NSLog(@"Error adding document: %@", error);
                } else {
                    NSLog(@"Document added with ID: %@", ref.documentID);
                }
            }];
            [[db documentWithPath:userDocumentPath] setData:dict merge:YES completion:^(NSError * _Nullable error) {
                if (error != nil) {
                    NSLog(@"Error writing document: %@", error);
                } else {
                    NSLog(@"Document successfully written");
                }
            }]; */
        } else {
            /* [[db documentWithPath:collectionName] setData:notification.object completion:^(NSError * _Nullable error) {
                if (error != nil) {
                    NSLog(@"Error writing document: %@", error);
                } else {
                    NSLog(@"Document successfully written");
                }
            }]; */
        }
    });
}

-(void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (BOOL) method:(NSString*)method is:(NSString*)action {
    return [method isEqualToString:action];
}


@end
