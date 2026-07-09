// TURAN AgOS · бренд-звезда (лого) — портировано из прототипа shell.jsx TuranStar.
import turanLogo from '@/assets/turan/turan-logo.png'

export function TuranStar({ size = 16 }: { size?: number }) {
  return <img src={turanLogo} width={size} height={size} alt="TURAN" style={{ flexShrink: 0, display: 'block', objectFit: 'contain' }} />
}
