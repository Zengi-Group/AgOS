// AgOS · TSP · Слайс 9 (S4) · Документ сделки (deal doc) — общий билдер для фермера и МПК.
// Когда пул собран, обе стороны могут скачать спецификацию сделки. Печатаем через
// системное окно печати (window.print → «Сохранить как PDF») — без сторонних библиотек.
// Обе стороны маппят свои данные в DealDocData; вёрстка и печать — здесь.

import { fmtMoney } from '../tsp/data/tsp-utils'

export interface DealDocParty {
  role: string                 // «Продавец» | «Покупатель»
  name: string
  bin?: string | null
  phone?: string | null
  region?: string | null
}

// Один проданный кусок (allocation) в таблице документа.
export interface DealDocChunk {
  counterparty?: string | null       // контрагент по куску (покупатель у фермера / поставщик у МПК)
  counterpartyPhone?: string | null
  heads: number
  price: number                       // ₸/кг
  weight?: number | null              // средний вес, кг
  statusLabel?: string
}

export interface DealDocData {
  side: 'farmer' | 'mpk'
  dealNo: string                      // короткий номер (id партии/пула)
  self: DealDocParty                  // сторона, скачивающая документ (её реквизиты)
  subject: {
    catName: string
    grade?: string | null             // «КРС · Высшая» и т.п.
    breed?: string | null
    avgWeight?: number | null
    fatness?: string | null
    age?: number | null               // мес.
  }
  totalHeads: number
  dealPrice?: number | null           // ₸/кг (средняя/сделки)
  chunks: DealDocChunk[]
  statusLabel: string
  timeline: { label: string; value: string }[]   // готовые пары «этап — дата»
}

// ── helpers ──────────────────────────────────────────────────────────────────
const esc = (s: unknown): string =>
  String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')

const NB = ' '

export function fmtDealDate(iso?: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' }).format(d)
}
const fmtDate = fmtDealDate

// Сумма по куску: голов × средний вес × цена (₸). Если веса нет — 0 (пропускаем в UI).
function chunkSum(c: DealDocChunk, fallbackWeight?: number | null): number {
  const w = c.weight ?? fallbackWeight ?? 0
  return Math.round(c.heads * w * c.price)
}

function partyBlock(p: DealDocParty): string {
  const rows: string[] = []
  rows.push(`<div class="p-name">${esc(p.name || '—')}</div>`)
  if (p.bin)    rows.push(`<div class="p-line">БИН/ИИН: ${esc(p.bin)}</div>`)
  if (p.phone)  rows.push(`<div class="p-line">Телефон: ${esc(p.phone)}</div>`)
  if (p.region) rows.push(`<div class="p-line">Регион: ${esc(p.region)}</div>`)
  return `<div class="party"><div class="p-role">${esc(p.role)}</div>${rows.join('')}</div>`
}

// ── HTML билдер ────────────────────────────────────────────────────────────────
export function buildDealDocHtml(d: DealDocData): string {
  const totalWeight = d.subject.avgWeight ?? null
  const totalSum = d.chunks.reduce((s, c) => s + chunkSum(c, totalWeight), 0)

  const subjRows: [string, string | number | null | undefined][] = [
    ['Категория', d.subject.catName],
    ['Сорт', d.subject.grade],
    ['Порода', d.subject.breed],
    ['Средний вес', d.subject.avgWeight != null ? `${d.subject.avgWeight}${NB}кг` : null],
    ['Упитанность', d.subject.fatness],
    ['Возраст', d.subject.age != null && d.subject.age > 0 ? `${d.subject.age}${NB}мес.` : null],
    ['Всего голов', d.totalHeads],
    ['Цена сделки', d.dealPrice != null ? `${fmtMoney(d.dealPrice)}${NB}₸/кг` : null],
  ]
  const subjHtml = subjRows
    .filter(([, v]) => v != null && v !== '')
    .map(([k, v]) => `<tr><td class="k">${esc(k)}</td><td class="v">${esc(v)}</td></tr>`)
    .join('')

  // Заголовок таблицы контрагентов зависит от стороны.
  const cpHead = d.side === 'farmer' ? 'Покупатель' : 'Поставщик'
  const chunkRows = d.chunks.map((c) => {
    const sum = chunkSum(c, totalWeight)
    const cp = c.counterparty
      ? `${esc(c.counterparty)}${c.counterpartyPhone ? ` · ${esc(c.counterpartyPhone)}` : ''}`
      : '—'
    return `<tr>
      <td>${cp}</td>
      <td class="num">${c.heads}</td>
      <td class="num">${fmtMoney(c.price)}</td>
      <td class="num">${sum > 0 ? fmtMoney(sum) : '—'}</td>
      <td>${esc(c.statusLabel ?? '')}</td>
    </tr>`
  }).join('')

  const timelineHtml = d.timeline
    .filter((t) => t.value && t.value !== '—')
    .map((t) => `<tr><td class="k">${esc(t.label)}</td><td class="v">${esc(t.value)}</td></tr>`)
    .join('')

  // Единственный контрагент (1 кусок) → раскрываем имя/телефон прямо в блоке «Стороны».
  const soleChunk = d.chunks.length === 1 ? d.chunks[0] : undefined

  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>Спецификация сделки № ${esc(d.dealNo)}</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif; color: #1a1a1a;
         margin: 0; padding: 32px 40px; font-size: 13px; line-height: 1.5; }
  .doc { max-width: 720px; margin: 0 auto; }
  .head { display: flex; justify-content: space-between; align-items: flex-start;
          border-bottom: 2px solid #2e9c5a; padding-bottom: 12px; margin-bottom: 20px; }
  .brand { font-size: 20px; font-weight: 700; color: #2e9c5a; letter-spacing: .5px; }
  .brand small { display: block; font-size: 11px; font-weight: 500; color: #666; letter-spacing: 0; }
  .meta { text-align: right; font-size: 12px; color: #444; }
  .meta b { color: #1a1a1a; }
  h1 { font-size: 16px; margin: 0 0 16px; }
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .5px; color: #2e9c5a;
       margin: 22px 0 8px; border-bottom: 1px solid #e5e5e5; padding-bottom: 4px; }
  .parties { display: flex; gap: 16px; }
  .party { flex: 1; background: #f7f9f7; border: 1px solid #e5e5e5; border-radius: 8px; padding: 12px 14px; }
  .p-role { font-size: 11px; text-transform: uppercase; color: #888; margin-bottom: 4px; }
  .p-name { font-weight: 700; font-size: 14px; margin-bottom: 4px; }
  .p-line { font-size: 12px; color: #444; }
  table { width: 100%; border-collapse: collapse; }
  .kv td { padding: 4px 8px; border-bottom: 1px solid #f0f0f0; }
  .kv td.k { color: #666; width: 40%; }
  .kv td.v { font-weight: 600; }
  .chunks th, .chunks td { padding: 7px 8px; border-bottom: 1px solid #eee; text-align: left; font-size: 12px; }
  .chunks th { background: #f2f5f2; font-weight: 600; color: #333; }
  .chunks td.num, .chunks th.num { text-align: right; }
  .chunks tfoot td { font-weight: 700; border-top: 2px solid #ccc; border-bottom: none; }
  .disc { margin-top: 26px; padding: 12px 14px; background: #fafafa; border: 1px solid #eee;
          border-radius: 8px; font-size: 11px; color: #777; line-height: 1.5; }
  .foot { margin-top: 20px; font-size: 11px; color: #aaa; text-align: center; }
  @media print { body { padding: 0; } .doc { max-width: none; } }
</style>
</head>
<body onload="setTimeout(function(){window.focus();window.print();},250)">
  <div class="doc">
    <div class="head">
      <div class="brand">TURAN<small>Ассоциация · Торгово-сбытовая площадка</small></div>
      <div class="meta">
        <div>Спецификация сделки</div>
        <div><b>№ ${esc(d.dealNo)}</b></div>
        <div>Дата: ${esc(fmtDate(new Date().toISOString()))}</div>
      </div>
    </div>

    <h1>Документ о сделке · ${esc(d.subject.catName)}</h1>

    <h2>Стороны</h2>
    <div class="parties">
      ${partyBlock(d.self)}
      ${partyBlock({
        role: d.side === 'farmer' ? 'Покупатель' : 'Продавец',
        name: soleChunk?.counterparty
          ? soleChunk.counterparty
          : (d.side === 'farmer' ? 'Покупатели (см. таблицу)' : 'Поставщики (см. таблицу)'),
        phone: soleChunk?.counterpartyPhone ?? null,
      })}
    </div>

    <h2>Предмет сделки</h2>
    <table class="kv">${subjHtml}</table>

    <h2>Состав сделки</h2>
    <table class="chunks">
      <thead>
        <tr>
          <th>${esc(cpHead)}</th>
          <th class="num">Голов</th>
          <th class="num">₸/кг</th>
          <th class="num">Сумма, ₸</th>
          <th>Статус</th>
        </tr>
      </thead>
      <tbody>${chunkRows}</tbody>
      <tfoot>
        <tr>
          <td>Итого</td>
          <td class="num">${d.totalHeads}</td>
          <td class="num"></td>
          <td class="num">${totalSum > 0 ? fmtMoney(totalSum) : '—'}</td>
          <td>${esc(d.statusLabel)}</td>
        </tr>
      </tfoot>
    </table>

    ${timelineHtml ? `<h2>Статус и даты</h2><table class="kv">${timelineHtml}</table>` : ''}

    <div class="disc">
      Документ сформирован автоматически платформой TURAN и носит информационный характер.
      Цены на площадке — это ориентир и результат добровольного согласования сторон;
      площадка является инфраструктурой координации и не устанавливает цены (ст. 171 ПК РК).
    </div>
    <div class="foot">Сформировано в кабинете TURAN · ${esc(fmtDate(new Date().toISOString()))}</div>
  </div>
</body>
</html>`
}

// Открывает окно печати с документом. Возвращает false, если браузер заблокировал popup.
export function printDealDoc(d: DealDocData): boolean {
  const html = buildDealDocHtml(d)
  const w = window.open('', '_blank', 'width=820,height=1040')
  if (!w) return false
  w.document.open()
  w.document.write(html)
  w.document.close()
  return true
}
