import type { RoleType } from '../constants'

const ROLE_ILLOS: Record<RoleType, string> = {
  farmer: '🐄',
  mpk: '🏭',
  services: '🔧',
  feed_producer: '🌾',
  expert: '👨‍⚕️',
}

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

  return (
    <div className="reg-benefit-enter space-y-5">
      {/* Illustration card */}
      <div
        className="rounded-2xl border border-[#e8ddd0] overflow-hidden"
        style={{ background: 'linear-gradient(135deg, #fdf6ee 0%, #f0e0c8 100%)' }}
      >
        <div
          className="h-24 flex items-center justify-center text-5xl"
          style={{
            background: 'repeating-linear-gradient(135deg, rgba(196,136,58,0.06) 0 1px, transparent 1px 8px)',
          }}
        >
          {ROLE_ILLOS[role]}
        </div>
        <div className="px-4 pt-3 pb-4">
          <h2 className="text-[18px] font-semibold text-[#2B180A] font-serif leading-snug">
            {content.title}
          </h2>
        </div>
      </div>

      {/* Benefits list */}
      <div className="space-y-3">
        {content.items.map((item, idx) => (
          <div
            key={idx}
            className="flex items-start gap-3 reg-benefit-enter"
            style={{ animationDelay: `${(idx + 1) * 80}ms` }}
          >
            <div className="w-5 h-5 rounded-full bg-[hsl(24,73%,54%)]/10 flex items-center justify-center shrink-0 mt-0.5">
              <svg className="w-3 h-3 text-[hsl(24,73%,54%)]" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={3} d="M5 13l4 4L19 7" />
              </svg>
            </div>
            <p className="text-[14px] text-[#2B180A]/80 leading-relaxed">{item}</p>
          </div>
        ))}
      </div>

      {/* Pager dots */}
      <div className="flex justify-center items-center gap-2 py-1">
        <div className={`rounded-full transition-all duration-300 ${step === 1 ? 'w-5 h-1.5 bg-[hsl(24,73%,54%)]' : 'w-1.5 h-1.5 bg-[#e8ddd0]'}`} />
        <div className={`rounded-full transition-all duration-300 ${step === 2 ? 'w-5 h-1.5 bg-[hsl(24,73%,54%)]' : 'w-1.5 h-1.5 bg-[#e8ddd0]'}`} />
      </div>

      <button onClick={onNext} className="reg-btn-primary w-full">
        Далее
      </button>
    </div>
  )
}
