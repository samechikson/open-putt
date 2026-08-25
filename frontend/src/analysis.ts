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
