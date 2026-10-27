"use strict";

const { HttpsError } = require("firebase-functions/v2/https");

async function googleJson(url, options, fetchImpl) {
  let response;
  try {
    response = await fetchImpl(url, {
      ...options,
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new HttpsError("unavailable", "Calcul du trajet indisponible. Réessayez.");
  }
  if (!response.ok) {
    throw new HttpsError(
      "unavailable",
      "Le service Google Maps a refusé le calcul. Réessayez ou contactez l’administrateur.",
    );
  }
  try {
    return await response.json();
  } catch {
    throw new HttpsError("unavailable", "Réponse Google Maps invalide. Réessayez.");
  }
}

async function computeTravel(position, address, apiKey, fetchImpl = fetch) {
  if (typeof address !== "string" || !address.trim()) {
    throw new HttpsError("failed-precondition", "L’adresse de départ est manquante.");
  }
  if (!apiKey) {
    throw new HttpsError("failed-precondition", "Le service de trajet n’est pas configuré.");
  }
  const geocodeUrl = new URL("https://maps.googleapis.com/maps/api/geocode/json");
  geocodeUrl.searchParams.set("address", address);
  geocodeUrl.searchParams.set("key", apiKey);
  const geocoded = await googleJson(geocodeUrl, {}, fetchImpl);
  if (geocoded.status === "ZERO_RESULTS") {
    throw new HttpsError("failed-precondition", "Adresse de départ introuvable. Faites corriger la course.");
  }
  if (geocoded.status !== "OK") {
    throw new HttpsError("unavailable", "Géocodage indisponible. Réessayez ou contactez l’administrateur.");
  }
  const results = geocoded.results;
  if (!Array.isArray(results) || results.length !== 1 || results[0].partial_match) {
    throw new HttpsError("failed-precondition", "Adresse de départ ambiguë. Faites préciser la course.");
  }
  const destination = results[0].geometry?.location;
  if (!Number.isFinite(destination?.lat) || Math.abs(destination.lat) > 90 ||
      !Number.isFinite(destination?.lng) || Math.abs(destination.lng) > 180) {
    throw new HttpsError("unavailable", "Coordonnées de départ invalides.");
  }
  const result = await googleJson(
    "https://routes.googleapis.com/directions/v2:computeRoutes",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "routes.duration,routes.distanceMeters",
      },
      body: JSON.stringify({
        origin: { location: { latLng: {
          latitude: position.latitude, longitude: position.longitude,
        } } },
        destination: { location: { latLng: {
          latitude: destination.lat, longitude: destination.lng,
        } } },
        travelMode: "DRIVE",
        routingPreference: "TRAFFIC_AWARE",
        computeAlternativeRoutes: false,
      }),
    },
    fetchImpl,
  );
  const route = result.routes?.[0];
  const duration = route?.duration;
  if (typeof duration !== "string" || !/^\d+(\.\d+)?s$/.test(duration) ||
      !Number.isFinite(route?.distanceMeters) || route.distanceMeters < 0) {
    throw new HttpsError("unavailable", "Aucun trajet routier exploitable. Réessayez.");
  }
  const durationSeconds = Number(duration.slice(0, -1));
  if (!Number.isFinite(durationSeconds)) {
    throw new HttpsError("unavailable", "Durée du trajet invalide.");
  }
  return {
    durationSeconds,
    routeDistanceMeters: route.distanceMeters,
    destination: { latitude: destination.lat, longitude: destination.lng },
    provider: "google_routes",
  };
}

module.exports = { computeTravel };
