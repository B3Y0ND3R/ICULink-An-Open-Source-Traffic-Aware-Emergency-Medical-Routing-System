/**
 * ICULink Cloud Functions
 *
 * Sends a push notification to a hospital's registered staff devices the
 * moment an ambulance booking targeting that hospital becomes EN_ROUTE.
 * Runs with the Admin SDK, so it bypasses firestore.rules entirely (rules
 * are a client-facing concept — this trusted server-side code doesn't need
 * them). Requires the Firebase project to be on the Blaze (pay-as-you-go)
 * plan; Cloud Functions do not deploy on the free Spark plan.
 */

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();
const db = getFirestore();
const messaging = getMessaging();

exports.notifyHospitalOnDispatch = onDocumentWritten(
  "bookings/{bookingId}",
  async (event) => {
    const after = event.data?.after;
    if (!after || !after.exists) return; // deleted — nothing to notify

    const afterData = after.data();
    if (afterData.status !== "EN_ROUTE") return;

    // Only notify on the transition INTO EN_ROUTE (new booking, or a future
    // re-activation) — not on every subsequent write to the same booking.
    // Without this guard, the driver's every-5-second location ping (which
    // rewrites the same EN_ROUTE document) would re-fire a notification.
    const before = event.data?.before;
    const beforeStatus = before && before.exists ? before.data().status : null;
    if (beforeStatus === "EN_ROUTE") return;

    const hospitalId = afterData.target_hospital_id;
    if (!hospitalId) {
      logger.warn(`Booking ${event.params.bookingId} has no target_hospital_id`);
      return;
    }

    const hospitalSnap = await db.collection("hospitals").doc(hospitalId).get();
    if (!hospitalSnap.exists) {
      logger.warn(`Hospital ${hospitalId} not found for booking ${event.params.bookingId}`);
      return;
    }

    const ownerUids = hospitalSnap.data().owner_uids || [];
    if (ownerUids.length === 0) {
      logger.info(`Hospital ${hospitalId} has no assigned staff — nothing to notify`);
      return;
    }

    // Firestore 'in' queries support at most 30 values; hospitals with more
    // assigned staff than that would need batching — not expected at this
    // app's scale, but noted for future-proofing.
    const usersSnap = await db
      .collection("users")
      .where("__name__", "in", ownerUids.slice(0, 30))
      .get();

    const tokenToUid = new Map();
    usersSnap.forEach((doc) => {
      const tokens = doc.data().fcm_tokens || [];
      for (const token of tokens) tokenToUid.set(token, doc.id);
    });

    const tokens = Array.from(tokenToUid.keys());
    if (tokens.length === 0) {
      logger.info(`No FCM tokens registered for hospital ${hospitalId}'s staff`);
      return;
    }

    const hospitalName = hospitalSnap.data().name || "your hospital";
    const ambulanceId = afterData.ambulance_id || "An ambulance";

    const response = await messaging.sendEachForMulticast({
      tokens,
      notification: {
        title: "🚨 Incoming Emergency",
        body: `${ambulanceId} is en route to ${hospitalName}. Prepare ICU.`,
      },
      data: {
        bookingId: event.params.bookingId,
        hospitalId,
      },
      android: { priority: "high" },
    });

    // Prune tokens that are no longer valid (app uninstalled, token
    // rotated, etc.) so future sends don't keep retrying dead endpoints.
    const staleByUid = new Map();
    response.responses.forEach((result, i) => {
      if (result.success) return;
      const code = result.error?.code;
      const isStale =
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token";
      if (!isStale) return;
      const token = tokens[i];
      const uid = tokenToUid.get(token);
      if (!staleByUid.has(uid)) staleByUid.set(uid, []);
      staleByUid.get(uid).push(token);
    });

    await Promise.all(
      Array.from(staleByUid.entries()).map(([uid, staleTokens]) =>
        db.collection("users").doc(uid).update({
          fcm_tokens: FieldValue.arrayRemove(...staleTokens),
        })
      )
    );

    logger.info(
      `Sent ${response.successCount}/${tokens.length} notifications for booking ${event.params.bookingId} (${staleByUid.size} stale tokens pruned)`
    );
  }
);
