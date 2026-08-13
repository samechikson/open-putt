// The Putting Gate mark: two accent gate posts joined by a top bar, with a
// dashed accent-2 laser line across the middle — the physical laser gate the
// app measures putts through.
export default function Logo({ size = 24 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <rect x="16" y="17" width="6.5" height="31" rx="3.25" fill="var(--color-accent)" />
      <rect x="41.5" y="17" width="6.5" height="31" rx="3.25" fill="var(--color-accent)" />
      <rect x="16" y="17" width="32" height="6.5" rx="3.25" fill="var(--color-accent)" />
      <line
        x1="22.5"
        y1="29"
        x2="41.5"
        y2="29"
        stroke="var(--color-accent-2-600)"
        strokeWidth="2.5"
        strokeDasharray="3 4"
      />
    </svg>
  );
}
