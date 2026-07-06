export const meta = {
  name: 'qa-run-all',
  description: 'Прогон всех тест-кейсов qa/scenarios/ агентами: backend-слой параллельно, UI волнами по портам, сводный отчёт',
  whenToUse: 'Когда нужно прогнать весь QA-реестр (qa/scenarios/, ~177 кейсов) и получить сводку в qa/runs/. Требует staging DATABASE_URL для sql/rpc-слоя и .env для UI против реального бэкенда.',
  phases: [
    { title: 'Backend', detail: 'sql/rpc/e2e-кейсы, rollback-tx, все файлы параллельно' },
    { title: 'UI', detail: 'ui-кейсы через preview_start, волнами по 3 порта' },
    { title: 'Синтез', detail: 'сводный отчёт + check_coverage.sh' },
  ],
}

// args: { files?: string[], runDate: 'YYYY-MM-DD' } — runDate обязателен (Date.now в workflow недоступен)
const FILES = (args && args.files) || [
  '01-registration', '02-auth', '03-onboarding', '04-membership',
  '05-tsp-farmer', '06-tsp-mpk', '07-security-cross', '08-backend-e2e',
]
const D = (args && args.runDate) || 'undated'

const RESULT = {
  type: 'object',
  properties: {
    file: { type: 'string' },
    pass: { type: 'number' }, fail: { type: 'number' },
    partial: { type: 'number' }, skip: { type: 'number' },
    fails: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, note: { type: 'string' } }, required: ['id', 'note'] } },
    report_path: { type: 'string' },
  },
  required: ['file', 'pass', 'fail', 'partial', 'skip', 'fails', 'report_path'],
}

const COMMON = `Ты — QA-исполнитель AgOS. Сначала прочитай .claude/skills/qa-run/SKILL.md и qa/README.md — работай строго по этой процедуре (rollback-tx, никаких правок кода, вердикты PASS/FAIL/PARTIAL/SKIP с evidence). MANDATORY: graphify-out/graph.json существует — перед чтением исходников кода используй \`graphify query\`. Конфиг-значения (тайминги/лимиты) читай из БД, не из хардкода кейса.`

phase('Backend')
const backend = await parallel(FILES.map((f) => () => agent(
  `${COMMON}
Файл: qa/scenarios/${f}.md. Прогони ТОЛЬКО кейсы, чей layer содержит sql, rpc или e2e (чистый ui и ui+rpc НЕ бери — их прогонит UI-волна). Доступ к БД: REST-режим из скилла (source .env → SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY; staging, живых клиентов нет). Соблюдай дисциплину зачистки QA-префиксов. Отчёт: qa/runs/${D}-${f}-backend.md`,
  { label: `backend:${f}`, phase: 'Backend', schema: RESULT },
)))

phase('UI')
const PORTS = ['Frontend (Vite)', 'Frontend (Vite, alt port)', 'Frontend dist (vite preview)']
const uiFiles = FILES.filter((f) => f !== '08-backend-e2e')
const uiResults = []
for (let i = 0; i < uiFiles.length; i += PORTS.length) {
  const wave = uiFiles.slice(i, i + PORTS.length)
  const r = await parallel(wave.map((f, j) => () => agent(
    `${COMMON}
Файл: qa/scenarios/${f}.md. Прогони ТОЛЬКО кейсы слоя ui и ui+rpc. Подними dev-сервер через preview_start, конфиг "${PORTS[j]}" из .claude/launch.json, и работай только со своим сервером. Если фронт в demo-режиме (нет .env с VITE_SUPABASE_*) — кейсы, требующие реального бэкенда, помечай PARTIAL(demo-mode) и проверяй только UI-поведение. Отчёт: qa/runs/${D}-${f}-ui.md`,
    { label: `ui:${f}`, phase: 'UI', schema: RESULT },
  )))
  uiResults.push(...r)
}

phase('Синтез')
const all = [...backend, ...uiResults].filter(Boolean)
const failTotal = all.reduce((n, r) => n + r.fail, 0)
log(`Прогнано файлов-слоёв: ${all.length}; суммарно FAIL: ${failTotal}`)
const summary = await agent(
  `${COMMON}
Собери сводку прогона ${D}. Прочитай отчёты: ${all.map((r) => r.report_path).join(', ')}. Запусти ./qa/check_coverage.sh. Напиши qa/runs/${D}-SUMMARY.md: таблица по файлам (PASS/FAIL/PARTIAL/SKIP), все FAIL одним списком (ID + суть + ссылка на отчёт), находки-кандидаты в IMPL_DEBT, предложения по смене status кейсов. Верни краткий итог (цифры + топ-риски).`,
  { label: 'summary', phase: 'Синтез' },
)
return { perFile: all, failTotal, summary }
