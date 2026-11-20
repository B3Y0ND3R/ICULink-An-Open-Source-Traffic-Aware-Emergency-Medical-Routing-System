# ICULink

Real-time emergency medical routing for Bangladesh. An ambulance driver presses
**SOS**; the app scores every hospital with a free ICU bed by traffic-aware
travel time and bed availability, books the best one, streams the ambulance's
live position, and alarms the receiving hospital's staff.

- **Drivers** (Flutter, Android/iOS): GPS fix, hospital scoring, route display, live tracking, history.
- **Hospital staff** (Flutter, tablet/web): bed + ventilator counters, incoming-ambulance alarm with live map, history, add/edit/archive hospitals.
- **Backend**: Firebase Auth (email/phone) and Cloud Firestore only — everything runs on the free Spark plan. Hospital alerts are the in-app alarm driven by Firestore listeners. (`functions/` holds an optional FCM push function that needs the paid Blaze plan; it is not required and not deployed.)

Score(H) = 0.7 x travel-time-minutes - 0.3 x vacant-ICU-beds (lower is better).
Travel times come from the TomTom Matrix API; if it fails, or has no live-traffic
data for some candidate, **every** hospital falls back to a Haversine estimate at
20 km/h so rankings stay comparable. Road geometry comes from OpenRouteService.

## Setup

1. `flutter pub get`
2. Copy `lib/config/secrets.example.dart` to `lib/config/secrets.dart` and add
   your TomTom and OpenRouteService keys (the file is gitignored).
3. Follow `docs/firebase_setup_guide.md` (auth providers, SHA fingerprints, test numbers).
4. Deploy the rules and indexes (free): `firebase deploy --only firestore:rules,firestore:indexes`.
5. `flutter run`

## Access model (see `firestore.rules`)

- A user chooses their role once at registration; it cannot be changed.
- Any signed-in user may create a hospital naming themselves sole owner, with
  validated counts/coordinates. Only owners (`owner_uids`) may edit it or read its bookings.
- Only drivers may create bookings (always `EN_ROUTE`) and may later change just
  position and status. Adding another owner to a hospital is an admin task done in
  the Firebase Console (`hospitals/{id}.owner_uids`).

## Tests

`flutter test` (model unit tests) and `flutter analyze`.
