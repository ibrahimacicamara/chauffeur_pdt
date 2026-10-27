"use strict";

const CLOSED = new Set(["COMPLETED", "CANCELLED", "NO_SHOW", "INTERRUPTED"]);

function statusName(value) {
  return String(value ?? "")
    .replace(/^OrderStatus\./, "")
    .replace(/[- ]/g, "_")
    .toUpperCase();
}

const ORDER_STATUSES = new Set([
  "PENDING_ASSIGNMENT",
  "ASSIGNED",
  "EN_ROUTE",
  "ON_SITE",
  "CLIENT_ON_BOARD",
  "COMPLETED",
  "CANCELLED",
  "NO_SHOW",
  "INTERRUPTED",
]);

function courseCategory(data) {
  const category = data?.category;
  return typeof category === "string" && category.trim().length > 0
    ? category
    : null;
}

function hasCategory(categories, category) {
  return Array.isArray(categories) &&
    typeof category === "string" && category.trim().length > 0 &&
    categories.some((value) =>
      typeof value === "string" &&
      value.toLowerCase() === category.toLowerCase(),
    );
}

function isAvailableCourse(data) {
  if (!data || typeof data !== "object") return false;
  if (data.status != null && typeof data.status !== "string") {
    throw new Error("Statut invalide");
  }
  const history = data.commandStatus ?? [];
  if (!Array.isArray(history)) throw new Error("Historique invalide");
  for (const event of history) {
    if (
      !event ||
      typeof event !== "object" ||
      typeof event.status !== "string" ||
      typeof event.id !== "string" ||
      !ORDER_STATUSES.has(statusName(event.status))
    ) {
      throw new Error("Étape d’historique invalide");
    }
  }
  if (
    data.driverId != null &&
    (typeof data.driverId !== "string" || !data.driverId.trim())
  ) {
    throw new Error("Attribution invalide");
  }
  const reset = history.findLastIndex(
    (event) => statusName(event?.status) === "PENDING_ASSIGNMENT",
  );
  const activeHistory = history.slice(reset + 1);
  const assigned =
    activeHistory.find(
      (event) =>
        statusName(event?.status) === "ASSIGNED" &&
        typeof event.id === "string" &&
        event.id.trim(),
    ) ??
    activeHistory.find(
      (event) => typeof event.id === "string" && event.id.trim(),
    );
  const driverId = assigned?.id?.trim() || (reset < 0 ? data.driverId : null);
  const finalStatus = statusName(
    data.status === "Annulée"
      ? "CANCELLED"
      : data.status === "Terminée"
        ? "COMPLETED"
        : data.status,
  );
  const historyStatus = statusName(activeHistory.at(-1)?.status);
  return !driverId && !CLOSED.has(finalStatus) && !CLOSED.has(historyStatus);
}

module.exports = { courseCategory, hasCategory, isAvailableCourse };
