export function mean(nums: number[]): number | null {
  if (nums.length === 0) return null;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

// Sample standard deviation — the spread of values around their mean. Needs at
// least two values; a single putt has no dispersion to speak of.
export function stdev(nums: number[]): number | null {
  if (nums.length < 2) return null;
  const m = nums.reduce((a, b) => a + b, 0) / nums.length;
  const variance =
    nums.reduce((a, b) => a + (b - m) ** 2, 0) / (nums.length - 1);
  return Math.sqrt(variance);
}
