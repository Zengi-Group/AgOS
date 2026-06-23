// AgOS · Этап 2 · Ферма (пилотный контракт, M7-lite): цикл, горизонт «Впереди», задачи.
// Перенесено из прототипа shell/farm-data.jsx (seedFarm), focus — поля, нужные Главной.
// FARM — константа хозяйства из p1/data.jsx.

export const FARM = {
  name: 'КХ «Алтын Дала»',
  district: 'Сайрамский район',
}

export interface FarmTask {
  id: string
  title: string
  done?: boolean
  postponed?: boolean
  dismissed?: boolean
  overdue?: string | boolean
}
export interface FarmCycle { name: string; day: number; total: number; phase: string }
export interface FarmPlanItem { name: string; dates: string }

// Реальная сводка стада из rpc_get_farm_summary (herd_groups). undefined = демо/сид.
export interface HerdGroupSummary { name: string; heads: number; weightKg: number | null }
export interface HerdSummary {
  totalHeads: number
  groupCount: number
  groups: HerdGroupSummary[]
}

export interface FarmState {
  // cycle опционален: реальная схема БД не хранит «день цикла/фазу отёла» — это поле
  // прототипа. Для вошедшего аккаунта строка фермы строится из herd (реальное стадо),
  // cycle остаётся только демо-фолбэком для анонима (seedFarm).
  cycle?: FarmCycle
  planFuture: FarmPlanItem[]
  tasks: FarmTask[]
  herd?: HerdSummary   // реальное стадо (есть только у вошедшего аккаунта с заполненным стадом)
}

// сид: сезон отёла (день 34)
export function seedFarm(): FarmState {
  return {
    cycle: { name: 'Маточное стадо · цикл 2026', day: 34, total: 60, phase: 'Отёл' },
    planFuture: [
      { name: 'Случная кампания', dates: '≈ 15 августа' },
      { name: 'Отъём телят', dates: '≈ октябрь' },
    ],
    tasks: [
      { id: 't1', title: 'Обход родильной группы' },
      { id: 't2', title: 'Биркование телят', overdue: '2 дн' },
      { id: 't3', title: 'Вет-осмотр коров после отёла' },
      { id: 't4', title: 'Контроль сосания у новорождённых' },
      { id: 't5', title: 'Выборочное взвешивание телят' },
      { id: 't6', title: 'Осмотр телят месячного возраста' },
      { id: 't7', title: 'Заказать корм на июль' },
    ],
  }
}

// тихий сезон (демо «штиль»): открытых задач нет, горизонт «Впереди» остаётся
export function seedFarmQuiet(): FarmState {
  const f = seedFarm()
  return { ...f, tasks: f.tasks.map((t) => ({ ...t, done: true })) }
}

export const farmOpenTasks = (f: FarmState): FarmTask[] => f.tasks.filter((t) => !t.done && !t.postponed && !t.dismissed)
