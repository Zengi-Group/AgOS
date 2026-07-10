// AgOS · ARS-212 · Мастер профиля фермы — типы черновика + словарь категорий + вывод
// ветки/архетипа/порога. Функциональный канон — Узел 1 v2.1 (F-D14); дизайн — Dok6 Slice7.
// Один словарь категорий (полевой ярлык · саб · код herd · ценовой catKey) — P4, общий для
// F1/F0b/F2. Слова «репродуктор/откорм/архетип» фермеру не показываются (выводится, не спрашивается).

export type HerdKey = 'cows' | 'calves' | 'heifers' | 'steers' | 'bull'

export interface HerdField {
  key: HerdKey
  code: string        // animal_categories.code (d01) — то, что пишем в herd_groups
  label: string       // полевой ярлык
  sub: string         // пояснение полевым языком
  catKey?: string     // ценовая категория (prices.ts CATS) — бык-производитель без цены
}

// Порядок — как фермер считает стадо (Узел 1 §4): коровы → телята → тёлки → бычки → бык.
export const HERD_FIELDS: HerdField[] = [
  { key: 'cows',    code: 'COW',           label: 'Коровы',            sub: 'взрослые матки',            catKey: 'korovy' },
  { key: 'calves',  code: 'YOUNG_CALF',    label: 'Телята',            sub: 'до отъёма, при матерях',    catKey: 'molodnyak' },
  { key: 'heifers', code: 'HEIFER_YOUNG',  label: 'Тёлки',             sub: 'отняты, ещё не телились',   catKey: 'telki' },
  { key: 'steers',  code: 'STEER',         label: 'Бычки',             sub: 'на откорме, доращивании',   catKey: 'bychki' },
  { key: 'bull',    code: 'BULL_BREEDING', label: 'Бык-производитель', sub: 'племенной, в стаде' },
]

export type CalvingAnswer = '' | 'spring' | 'autumn' | 'year_round' | 'varies'
export type YoungAnswer = '' | 'weaners' | 'yearling' | 'keep'
export type HousingAnswer = '' | 'pasture' | 'stall' | 'mixed' | 'feedlot'

// Черновик мастера (ответы до/во время записи). Персист — useFarmDraft (образец useBatchDraft).
export interface FwState {
  heads: Record<HerdKey, number>
  calving: CalvingAnswer
  calvingMonth: number | null   // 1..12 — месяц первого отёла при сезонном ответе
  young: YoungAnswer
  housing: HousingAnswer
}

export const FRESH_FW: FwState = {
  heads: { cows: 0, calves: 0, heifers: 0, steers: 0, bull: 0 },
  calving: '',
  calvingMonth: null,
  young: '',
  housing: '',
}

export const totalHeads = (heads: FwState['heads']): number =>
  (Object.values(heads) as number[]).reduce((s, n) => s + (n || 0), 0)

// Ветвление яруса «План» (Узел 1 §5): отёл — только при маточном; молодняк — при маточном
// или телятах; содержание — всем. Порядок экранов = порядок в массиве.
export type FwStep = 'calving' | 'young' | 'housing'

export function branchSteps(heads: FwState['heads']): FwStep[] {
  const steps: FwStep[] = []
  if (heads.cows > 0) steps.push('calving')
  if (heads.cows > 0 || heads.calves > 0) steps.push('young')
  steps.push('housing')
  return steps
}

// Вывод архетипа из состава (F-D14) → activity_type (d01 CHECK: cow_calf/finishing/mixed).
// Мост activity_type→farm_type (F-D11): mixed→combined. Фермеру эти слова не показываются.
export function deriveActivityType(heads: FwState['heads']): 'cow_calf' | 'finishing' | 'mixed' {
  const breeding = heads.cows > 0
  const finishing = heads.steers > 0
  if (breeding && finishing) return 'mixed'
  if (finishing && !breeding) return 'finishing'
  return 'cow_calf'
}

// calving-ответ → farms.calving_system (d01 CHECK: spring/autumn/year_round/two_season/varies).
// «По-разному» пишется как 'varies' (F-D14: легальный ответ; null «съедал» бы его и порог
// моста ARS-213 не срабатывал — дефект стыка закрыт в d01 расширением CHECK).
export function calvingSystemValue(c: CalvingAnswer): string | null {
  return c === '' ? null : c
}

// housing-ответ → farms.shelter_type (d01 CHECK: stall/pasture/mixed/feedlot).
export function shelterTypeValue(h: HousingAnswer): string | null {
  const map: Record<Exclude<HousingAnswer, ''>, string> = {
    pasture: 'pasture', stall: 'stall', mixed: 'mixed', feedlot: 'feedlot',
  }
  return h ? map[h] : null
}

// Порог ЦТК (Узел 1 §5): маточное>0 + любой ответ про отёл (включая круглый год/по-разному).
// Пропуск отёла (calving='') → порог не достигнут → финал F7 без плана.
export function thresholdReached(s: FwState): boolean {
  return s.heads.cows > 0 && s.calving !== ''
}
