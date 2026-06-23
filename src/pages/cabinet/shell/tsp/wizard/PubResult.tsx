// AgOS · TSP-1 · SCR-03 · Результат публикации (p1/wizard.jsx PubResult). Варианты A/B/C/D.

import type { ReactNode } from 'react'
import type { Batch, PubVariant } from '../types/batch'
import { NBSP } from '../data/tsp-dicts'
import { fmtMoney } from '../data/tsp-utils'
import { Cta } from '../../components/Cta'

interface PubResultProps {
  variant: PubVariant
  batch: Batch
  onToBatch: () => void
  onToList?: () => void
}

export function PubResult({ variant, batch, onToBatch, onToList }: PubResultProps) {
  const dealPrice = (batch.dealPrice ?? 0) as number
  const price = (batch.price ?? 0) as number
  const variants: Record<PubVariant, { ic: string; tone: string; h: string; body: ReactNode }> = {
    A: {
      ic: '✓', tone: 'ok', h: 'Покупатель найден!',
      body: (
        <>
          <div className="pr-price mono">Цена сделки: <b>{fmtMoney(dealPrice)}{NBSP}₸/кг</b></div>
          {dealPrice > price && <div className="pr-badge">на {fmtMoney(dealPrice - price)}{NBSP}₸/кг выше вашей цены</div>}
          <p>Покупатель сейчас добирает полный заказ. Когда доберёт — сделка подтвердится, и мы покажем, кто покупатель. Обычно это занимает от нескольких часов до нескольких дней.</p>
        </>
      ),
    },
    B: {
      ic: '→', tone: 'send', h: 'Партия отправлена покупателям',
      body: <p>Подходящие покупатели получили ваше предложение. Ответ придёт до <b>{String(batch.deadlineLabel ?? '')}</b>. Если никто не согласится — предложим, что делать дальше.</p>,
    },
    C: {
      ic: '◷', tone: 'wait', h: 'Партия в продаже',
      body: <p>Сейчас подходящего покупателя нет — это нормально, особенно в вашем районе предложение появляется волнами. Как только появится — партия попадёт к нему автоматически, мы сразу сообщим.</p>,
    },
    D: {
      ic: '🗓', tone: 'plan', h: 'Запланировано',
      body: <p>Партия выйдет в продажу <b>{String(batch.publishAtLabel ?? '')}</b> — за неделю до готовности животных. Делать ничего не нужно.</p>,
    },
  }
  const v = variants[variant]
  return (
    <div className="phone" data-screen-label={'SCR-03 · публикация · вариант ' + variant}>
      <div className="phone-body wiz-container">
        <div className="pub-res">
          <div className={'pub-ic ' + v.tone}>{v.ic}</div>
          <h2 className="step-h1 center">{v.h}</h2>
          <div className="pub-body">{v.body}</div>
        </div>
        <Cta onClick={onToBatch}>К партии</Cta>
        {onToList && <button className="link-skip" onClick={onToList}>К моим партиям</button>}
      </div>
    </div>
  )
}
