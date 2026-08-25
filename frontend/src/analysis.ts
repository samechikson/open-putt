// Shared helpers for presenting putt data. Putts come only from the hardware
// gate now (relayed by the iOS app); there's no video/CV pipeline in the client.

export type Side = "left" | "right" | "center";

// The stored offset_mm is pre-inverted when a device putt is ingested (see the
// backend's /device/putts), so `golferSide` negates it to recover the golfer's
// left/right — matching how the iOS Gate view presents a putt. A putt right of
// the line reads "right" (a push); left of it, "left" (a pull).
export function golferSide(offsetMm: number): Side {
  const v = -offsetMm; // recover the golfer's-eye sign
  return v > 0 ? "right" : v < 0 ? "left" : "center";
}

// A putt that finishes right of the target is a "push"; left of it, a "pull".
export function biasWord(side: Side): string {
  return side === "right" ? "push" : side === "left" ? "pull" : "none";
}

// Backend base URL. Same-origin `/api` by default: in production Firebase
// Hosting rewrites /api/** to Cloud Run (no CORS); in dev the Vite server
// proxies /api to the local backend (see vite.config.ts). Overridable via
// VITE_API_BASE (see .env.production).
export const API_BASE = import.meta.env.VITE_API_BASE ?? "/api";
