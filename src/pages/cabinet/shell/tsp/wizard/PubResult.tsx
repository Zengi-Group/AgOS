// AgOS · TSP-1 · SCR-03 · Результат публикации — реcкин под прототип (market-wizard.jsx PubResult).
// Варианты A/B/C/D. Рендерится внутри внешнего <IonPage className="agos-flow-page">
// (CabinetApp.renderMarket): IonContent (.mk-res) + док-футер .sh-foot.

import { useEffect, useState, type ReactNode } from 'react'
import { IonContent } from '@ionic/react'
import type { Batch, PubVariant } from '../types/batch'
import { NBSP } from '../data/tsp-dicts'
import { fmtMoney } from '../data/tsp-utils'
import { MkCta } from '../components/MkCta'
import { TuranLoader } from '@/components/TuranLoader'
import { PhIcon, type PhIconName } from '../../components/icons/PhIcon'

interface PubResultProps {
  variant: PubVariant
  batch: Batch
  onToBatch: () => void
  onToList?: () => void
}

// Пауза-поиск между публикацией и результатом. Автоматч уже отработал синхронно
// (см. BatchWizard.handlePublish) — реального ожидания нет, это минимальное время
// показа, чтобы «покупатель найден сразу» (вариант A) читался как исход поиска,
// а не как мгновенный глюк. Вариант D (запланировано) поиск не запускает.
const SEARCH_MS = 2200
const SEARCH_PHRASES = [
  'Ищем покупателя для вашей партии…',
  'Сверяем цену с активными заказами…',
  'Проверяем покупателей в вашем районе…',
]

export function PubResult({ variant, batch, onToBatch, onToList }: PubResultProps) {
  const [searching, setSearching] = useState(variant !== 'D')
  const [phraseIdx, setPhraseIdx] = useState(0)

  useEffect(() => {
    if (!searching) return
    const step = Math.round(SEARCH_MS / SEARCH_PHRASES.length)
    const rot = setInterval(
      () => setPhraseIdx((i) => Math.min(i + 1, SEARCH_PHRASES.length - 1)),
      step,
    )
    const done = setTimeout(() => setSearching(false), SEARCH_MS)
    return () => { clearInterval(rot); clearTimeout(done) }
  }, [searching])

  if (searching) {
    return (
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk" data-screen-label={'SCR-03 · публикация · поиск · вариант ' + variant}>
            <div className="mk-loader">
              <TuranLoader variant="breathe" size={44} />
              <div>{SEARCH_PHRASES[phraseIdx]}</div>
            </div>
          </div>
        </div>
      </IonContent>
    )
  }

  const dealPrice = (batch.dealPrice ?? 0) as number
  const price = (batch.price ?? 0) as number
  const variants: Record<PubVariant, { ic: PhIconName; tone: string; h: string; body: ReactNode }> = {
    A: {
      ic: 'checkCircle', tone: 'green', h: 'Покупатель найден',
      body: (
        <>
          <div className="mk-pr-price">Цена сделки: <b className="mk-mono">{fmtMoney(dealPrice)}{NBSP}₸/кг</b></div>
          {dealPrice > price && <div className="mk-pr-badge">на {fmtMoney(dealPrice - price)}{NBSP}₸/кг выше вашей цены</div>}
          <p>Покупатель сейчас добирает полный заказ. Когда доберёт — сделка подтвердится, и мы покажем, кто покупатель. Обычно это занимает от нескольких часов до нескольких дней.</p>
        </>
      ),
    },
    B: {
      ic: 'send', tone: 'amber', h: 'Партия отправлена покупателям',
      body: <p>Подходящие покупатели получили ваше предложение. Ответ придёт до <b>{String(batch.deadlineLabel ?? '')}</b>. Если никто не согласится — предложим, что делать дальше.</p>,
    },
    C: {
      ic: 'clock', tone: 'blue', h: 'Партия в продаже',
      body: <p>Сейчас подходящего покупателя нет — это нормально, особенно в вашем районе предложение появляется волнами. Как только появится — партия попадёт к нему автоматически, мы сразу сообщим.</p>,
    },
    D: {
      ic: 'calendar', tone: 'blue', h: 'Запланировано',
      body: <p>Партия выйдет в продажу <b>{String(batch.publishAtLabel ?? '')}</b> — за неделю до готовности животных. Делать ничего не нужно.</p>,
    },
  }
  const v = variants[variant]
  return (
    <>
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk" data-screen-label={'SCR-03 · публикация · вариант ' + variant}>
            <div className="mk-res">
              <div className={'mk-res-ic tone-' + v.tone}><PhIcon name={v.ic} size={30} /></div>
              <h1 className="mk-res-h">{v.h}</h1>
              <div className="mk-res-b">{v.body}</div>
            </div>
          </div>
        </div>
      </IonContent>
      <div className="sh-foot">
        <MkCta onClick={onToBatch}>К партии</MkCta>
        {onToList && <button className="mk-link" onClick={onToList}>К моим партиям</button>}
      </div>
    </>
  )
}
