/*
 * locationbridge — iOS: CoreLocation.
 *
 * start and stop are called from the kproc that opened or closed
 * #g/nmea.  CLLocationManager must be made and driven on a thread with
 * a run loop, so both post the work to the main queue and return
 * without waiting (locationbridge.h: they must not block).  Fixes and
 * changes of authorisation arrive on the main queue through the
 * delegate, which hands them to devlocation.
 *
 * Permission is "when in use" (NSLocationWhenInUseUsageDescription in
 * app/Info.plist), asked for the first time something reads #g/nmea.
 * Until it is answered the device says waiting; refused, denied.
 *
 * CLLocation's altitude is above mean sea level, as NMEA's is.  A
 * value CoreLocation marks invalid (a negative accuracy, speed or
 * course) is left out; a fix with no valid horizontal accuracy is not
 * a position and is dropped.
 */

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#include <string.h>
#include <dispatch/dispatch.h>
#include "locationbridge.h"

@interface InfernodeLocationDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *manager;
@property (nonatomic, assign) BOOL running;	/* main queue only */
@end

static InfernodeLocationDelegate *delegate;	/* main queue only */

static CLAuthorizationStatus
authstatus(CLLocationManager *m)
{
	if(@available(iOS 14.0, *))
		return m.authorizationStatus;
	return [CLLocationManager authorizationStatus];
}

@implementation InfernodeLocationDelegate

/* updates begin if they are wanted and allowed */
- (void)resume
{
	if(!self.running)
		return;
	if(![CLLocationManager locationServicesEnabled]){
		locationbridge_post_state("off");
		return;
	}
	switch(authstatus(self.manager)){
	case kCLAuthorizationStatusNotDetermined:
		locationbridge_post_state("waiting");
		[self.manager requestWhenInUseAuthorization];
		break;
	case kCLAuthorizationStatusDenied:
	case kCLAuthorizationStatusRestricted:
		locationbridge_post_state("denied");
		break;
	default:
		locationbridge_post_state("waiting");
		[self.manager startUpdatingLocation];
		break;
	}
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)m
{
	[self resume];
}

/* before iOS 14 */
- (void)locationManager:(CLLocationManager *)m didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
	[self resume];
}

- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray<CLLocation *> *)locations
{
	LocFix f;

	if(!self.running)
		return;
	for(CLLocation *loc in locations){
		if(loc.horizontalAccuracy < 0)
			continue;
		memset(&f, 0, sizeof f);
		f.lat = loc.coordinate.latitude;
		f.lon = loc.coordinate.longitude;
		f.hacc = loc.horizontalAccuracy;
		f.vacc = -1;
		if(loc.verticalAccuracy >= 0){
			f.hasalt = 1;
			f.alt = loc.altitude;
			f.vacc = loc.verticalAccuracy;
		}
		if(loc.speed >= 0){
			f.hasspeed = 1;
			f.speed = loc.speed;
		}
		if(loc.course >= 0){
			f.hascourse = 1;
			f.course = loc.course;
		}
		f.utcms = (long long)(loc.timestamp.timeIntervalSince1970 * 1000.0);
		locationbridge_post_fix(&f);
	}
}

- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)error
{
	if([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorDenied){
		locationbridge_post_state("denied");
		[m stopUpdatingLocation];
	}
	/* kCLErrorLocationUnknown is transient: CoreLocation keeps trying */
}

@end

void
locationbridge_init(void)
{
}

int
locationbridge_start(char *err, int errlen)
{
	(void)err;
	(void)errlen;
	dispatch_async(dispatch_get_main_queue(), ^{
		if(delegate == nil){
			delegate = [[InfernodeLocationDelegate alloc] init];
			delegate.manager = [[CLLocationManager alloc] init];
			delegate.manager.delegate = delegate;
			delegate.manager.desiredAccuracy = kCLLocationAccuracyBest;
			delegate.manager.distanceFilter = kCLDistanceFilterNone;
		}
		delegate.running = YES;
		[delegate resume];
	});
	return 0;
}

void
locationbridge_stop(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if(delegate == nil)
			return;
		delegate.running = NO;
		[delegate.manager stopUpdatingLocation];
	});
}
