// Hermit mark: golden-ratio rectangle with spiral, redrawn as SVG from the brand logo.
export default function Logo({ size = 24, color = 'var(--accent)', stroke = 44 }) {
  return (
    <svg width={size * 1.62} height={size} viewBox="225 432 1150 735" aria-label="Hermit">
      <g fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
        <rect x="255" y="462" width="1090" height="675" rx="6" />
        <path d="M928 462V1137M928 880H1345M1088 880V1137M928 978H1088" />
        <path d="M255 1137A673 675 0 0 1 928 462A417 418 0 0 1 1345 880A257 257 0 0 1 1088 1137A160 159 0 0 1 928 978A100 98 0 0 1 1028 880" />
      </g>
    </svg>
  )
}
