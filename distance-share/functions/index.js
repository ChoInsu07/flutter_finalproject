const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

admin.initializeApp();

function degToRad(deg) {
  return deg * (Math.PI / 180);
}

function haversineMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = degToRad(lat2 - lat1);
  const dLon = degToRad(lon2 - lon1);

  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(degToRad(lat1)) *
      Math.cos(degToRad(lat2)) *
      Math.sin(dLon / 2) ** 2;

  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ✅ 우리가 필요한 트리거
exports.onLocationWrite = onDocumentWritten(
  "sessions/{sessionId}/locations/{locId}",
  async (event) => {
    const { sessionId } = event.params;

    const sessionRef = admin.firestore().doc(`sessions/${sessionId}`);
    const locsSnap = await sessionRef.collection("locations").get();

    let A = null;
    let B = null;

    locsSnap.forEach((doc) => {
      const d = doc.data();
      if (d.role === "A" && typeof d.lat === "number" && typeof d.lon === "number") {
        A = { lat: d.lat, lon: d.lon };
      }
      if (d.role === "B" && typeof d.lat === "number" && typeof d.lon === "number") {
        B = { lat: d.lat, lon: d.lon };
      }
    });

    if (!A || !B) return;

    const distanceMeters = haversineMeters(A.lat, A.lon, B.lat, B.lon);

    await sessionRef.set(
      {
        distanceMeters,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
);
