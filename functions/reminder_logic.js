"use strict";

const HOUR = 60 * 60 * 1000;
const CLOSED = new Set(["COMPLETED", "CANCELLED", "NO_SHOW", "INTERRUPTED"]);

function statusName(value) {
  return String(value ?? "").replace(/^OrderStatus\./, "").toUpperCase();
}

function course(data) {
  if (!data) return null;
  const history = data.commandStatus ?? [];
  if (!Array.isArray(history)) throw new Error("Historique invalide");
  const reset = history.findLastIndex((event) => statusName(event.status) === "PENDING_ASSIGNMENT");
  const activeHistory = history.slice(reset + 1);
  const assigned = activeHistory.find((event) => statusName(event.status) === "ASSIGNED");
  const author = assigned ?? activeHistory.find((event) => event.id?.trim());
  const driverId = author?.id?.trim() || (reset < 0 ? data.driverId : null);
  const rawDate = data.departureDate;
  if (typeof rawDate === "string" && !/(Z|[+-]\d{2}:\d{2})$/i.test(rawDate)) {
    throw new Error("La date ISO de départ doit préciser le fuseau horaire");
  }
  const departure = rawDate?.toMillis ? rawDate.toMillis() :
    rawDate instanceof Date ? rawDate.getTime() : Date.parse(rawDate);
  if (!driverId) return null;
  if (typeof driverId !== "string" || driverId.includes("/") || !Number.isFinite(departure)) {
    throw new Error("Attribution ou date de départ invalide");
  }
  const status = data.status === "Terminée" ? "COMPLETED" :
    data.status === "Annulée" ? "CANCELLED" : statusName(history.at(-1)?.status);
  if (CLOSED.has(status)) return null;
  return {
    driverId, departure, due: departure - HOUR,
    generation: `${driverId}:${departure}${reset >= 0 ? `:release-${reset}` : ""}`,
    address: data.departureAddress,
  };
}

function validatePosition(position, now) {
  const { latitude, longitude, capturedAt } = position ?? {};
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
      !Number.isFinite(longitude) || longitude < -180 || longitude > 180 ||
      !Number.isFinite(capturedAt) || now - capturedAt > 120000 || capturedAt - now > 30000) {
    throw new Error("Position GPS invalide ou trop ancienne. Réessayez.");
  }
  return { latitude, longitude, capturedAt };
}

function distanceMeters(a, b) {
  const radians = (n) => n * Math.PI / 180;
  const dLat = radians(b.latitude - a.latitude);
  const dLng = radians(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(radians(a.latitude)) * Math.cos(radians(b.latitude)) * Math.sin(dLng / 2) ** 2;
  return Math.round(6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(Math.max(0, 1 - h))));
}

module.exports = { course, validatePosition, distanceMeters };
