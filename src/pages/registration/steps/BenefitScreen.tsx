import { Check } from '@phosphor-icons/react'
import { T } from '@/lib/auth-ui/tokens'
import { StickyDock, CTA } from '@/lib/auth-ui/primitives'
import { ROLE_ICONS } from '../roleIcons'
import type { RoleType } from '../constants'

const BENEFIT_CONTENT: Record<
  RoleType,
  { step1: BenefitData; step2: BenefitData }
> = {
  farmer: {
    step1: {
      title: 'TURAN помогает вашему хозяйству',
      items: [
        'AI-ветеринар: анализ симптомов и рекомендации 24/7',
        'Расчёт рационов кормления по нормам NASEM',
        'План сезонных работ с напоминаниями',
        'Справедливые цены через координацию ассоциации',
      ],
    },
    step2: {
      title: 'Всё для фермера в одном кабинете',
      items: [
        'Учёт поголовья по группам и породам',
        'Отслеживание ветеринарных случаев',
        'Контроль складских запасов кормов',
        'Прозрачный рынок сбыта скота',
      ],
    },
  },
  mpk: {
    step1: {
      title: 'TURAN для закупщиков',
      items: [
        'Прямой доступ к фермерам ассоциации',
        'Актуальная информация о предложении',
        'Стандартизированная система грейдинга',
        'Координация закупок и логистики',
      ],
    },
    step2: {
      title: 'Преимущества работы через платформу',
      items: [
        'Агрегированное предложение по регионам',
        'Прозрачное ценообразование',
        'Сертификация и ветеринарные данные',
        'Система пулов для оптимизации логистики',
      ],
    },
  },
  services: {
    step1: {
      title: 'TURAN для сервисных компаний',
      items: [
        'Доступ к базе фермеров ассоциации',
        'Маркетплейс ветеринарных и зоотехнических услуг',
        'Система заявок на консультации',
        'Репутация и рейтинг среди фермеров',
      ],
    },
    step2: {
      title: 'Расширьте свою клиентскую базу',
      items: [
        'Автоматическое направление заявок по специализации',
        'Удобный календарь и управление заявками',
        'Рекомендации от AI-системы',
        'Аналитика по обращениям',
      ],
    },
  },
  feed_producer: {
    step1: {
      title: 'TURAN для кормопроизводителей',
      items: [
        'Каталог продукции для фермеров',
        'Система рекомендаций в рационах',
        'Прямые контакты с хозяйствами',
        'Аналитика спроса по регионам',
      ],
    },
    step2: {
      title: 'Ваши корма в рационах фермеров',
      items: [
        'Интеграция с калькулятором рационов',
        'Автоматические рекомендации на основе потребностей',
        'Логистическая координация доставки',
        'Отзывы и рейтинг от фермеров',
      ],
    },
  },
  expert: {
    step1: {
      title: 'Работайте с фермерами ТУРАН',
      items: [
        'Фермеры из вашего региона находят вас сами',
        'Заявки приходят прямо в приложение',
        'Рейтинг и отзывы — репутация на платформе',
        'Календарь и управление расписанием',
      ],
    },
    step2: {
      title: 'Всё для эксперта в одном месте',
      items: [
        'Заявки только из выбранных регионов',
        'Чат с фермерами прямо в приложении',
        'История консультаций и документы',
        'Прозрачные условия и безопасные расчёты',
      ],
    },
  },
}

interface BenefitData {
  title: string
  items: string[]
}

interface BenefitScreenProps {
  role: RoleType
  step: 1 | 2
  onNext: () => void
}

export function BenefitScreen({ role, step, onNext }: BenefitScreenProps) {
  const content = step === 1
    ? BENEFIT_CONTENT[role].step1
    : BENEFIT_CONTENT[role].step2
  const RoleIcon = ROLE_ICONS[role]

  return (
    <div style={{ fontFamily: T.font }}>
      {/* Illustration card */}
      <div style={{ borderRadius: 16, border: `1px solid ${T.bd}`, overflow: 'hidden', marginTop: 8 }}>
        <div
          style={{
            height: 96,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            background: `linear-gradient(135deg, ${T.bgS} 0%, ${T.bgM} 100%)`,
          }}
        >
          <RoleIcon size={44} weight="light" color={T.accent} />
        </div>
        <div style={{ padding: '14px 16px 16px', background: T.bgC }}>
          <h2 style={{ fontFamily: T.font, fontSize: 18, fontWeight: 600, color: T.fg, lineHeight: 1.3, letterSpacing: '-0.01em', margin: 0 }}>
            {content.title}
          </h2>
        </div>
      </div>

      {/* Benefits list */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 20 }}>
        {content.items.map((item, idx) => (
          <div key={idx} style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
            <div style={{ width: 20, height: 20, borderRadius: 999, background: T.bgM, display: 'grid', placeItems: 'center', flexShrink: 0, marginTop: 2 }}>
              <Check size={12} weight="bold" color={T.accent} />
            </div>
            <p style={{ fontSize: 14, color: T.fg2, lineHeight: 1.5, margin: 0 }}>{item}</p>
          </div>
        ))}
      </div>

      {/* Pager dots */}
      <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 8, paddingTop: 20 }}>
        <div style={{ borderRadius: 999, transition: 'all 300ms', width: step === 1 ? 20 : 6, height: 6, background: step === 1 ? T.accent : T.bd }} />
        <div style={{ borderRadius: 999, transition: 'all 300ms', width: step === 2 ? 20 : 6, height: 6, background: step === 2 ? T.accent : T.bd }} />
      </div>

      <StickyDock>
        <CTA onClick={onNext}>Далее</CTA>
      </StickyDock>
    </div>
  )
}
