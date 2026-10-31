/*
 * locationbridge — the host's location service, for devlocation.
 *
 * Per-platform implementations:
 *   emu/Android/locationbridge.c   LocationManager, through
 *                                  android-app/.../InfernodeLocationBridge.kt
 *   emu/iOS/locationbridge.m       CoreLocation
 *   emu/port/locationbridge-stub.c every other host: none, unless
 *                                  $INFERNODE_LOCATION_FAKE gives one
 *                                  (for tests)
 *
 * Two directions, as phonebridge.h:
 *
 *   1. Device -> bridge: locationbridge_start when the first reader
 *      opens #g/nmea, locationbridge_stop when the last closes, so the
 *      receiver runs only while something listens.  Both are called
 *      from a kproc and must not block: a platform that must start
 *      its service on another thread posts the work there and
 *      returns.  start returns 0, or -1 with the reason in err (no
 *      location service on this host).  A permission the user has not
 *      yet granted is not a failure: the bridge says so through
 *      locationbridge_post_state, and fixes come once it is granted.
 *
 *   2. Bridge -> device: locationbridge_post_fix for each position the
 *      service gives, locationbridge_post_state when its state
 *      changes.  Defined in emu/port/devlocation.c; they never block
 *      and are safe from any thread.
 */
#ifndef LOCATIONBRIDGE_H
#define LOCATIONBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocFix LocFix;
struct LocFix
{
	double	lat;		/* degrees, north positive */
	double	lon;		/* degrees, east positive */
	int	hasalt;
	double	alt;		/* metres above mean sea level */
	int	hasspeed;
	double	speed;		/* metres a second */
	int	hascourse;
	double	course;		/* degrees true */
	double	hacc;		/* horizontal accuracy, metres, 68%; < 0 unknown */
	double	vacc;		/* vertical accuracy, metres; < 0 unknown */
	long long	utcms;	/* milliseconds since 1970-01-01T00:00:00Z */
};

void	locationbridge_init(void);
int	locationbridge_start(char *err, int errlen);
void	locationbridge_stop(void);

void	locationbridge_post_fix(const LocFix *f);
/* ok, waiting (started, no fix yet), denied, off (services disabled) */
void	locationbridge_post_state(const char *state);

#ifdef __cplusplus
}
#endif

#endif
