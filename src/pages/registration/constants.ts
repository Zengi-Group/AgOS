// UUIDs from public.regions table (deployed Supabase)
// P8: In future, load dynamically. For now, hardcoded with real UUIDs.
export const REGIONS = [
  { id: '6a8fb31b-fd23-494b-9145-24810bc0e312', name: 'Алматы' },
  { id: '88e0fb13-c1ec-4682-aaa1-7360ae1728f0', name: 'Астана' },
  { id: '281318d8-3f90-42bd-a0a8-17a2890d672d', name: 'Шымкент' },
  { id: '9a2dfc64-1d02-4133-af61-83c06a0061c0', name: 'Акмолинская область' },
  { id: 'd8a2de40-cfcc-46a3-a29c-c52c9e1391d1', name: 'Актюбинская область' },
  { id: '0f1abcc1-f598-456a-bd22-b7c0a0c64dab', name: 'Алматинская область' },
  { id: '96f2d435-25ba-4a34-82d9-14bab14ddf1d', name: 'Атырауская область' },
  { id: '3d56538b-d080-40d7-a6ec-bc60d2696dec', name: 'Восточно-Казахстанская область' },
  { id: 'b232963a-8cf5-468b-9f8c-234c770bb8b8', name: 'Жамбылская область' },
  { id: 'b841e25c-327d-4e9c-b4d3-be5e74c55f50', name: 'Западно-Казахстанская область' },
  { id: 'a950545c-fcdb-487e-87f5-a746f798b9f2', name: 'Карагандинская область' },
  { id: 'b72d8c3b-505a-4986-bb82-a5abcf772174', name: 'Костанайская область' },
  { id: '4dff644d-2ee2-4c7c-8581-5182cf542cbd', name: 'Кызылординская область' },
  { id: '5b2cf821-7808-41ce-943d-ed8fd2a75f1d', name: 'Мангистауская область' },
  { id: '7b53b2c0-9b48-47fd-99e6-6aed7d9843e8', name: 'Павлодарская область' },
  { id: '8e5fbff0-3616-46cf-985c-682c49779a04', name: 'Северо-Казахстанская область' },
  { id: 'b83df0fa-ffcb-4733-874d-b45823e6cce7', name: 'Туркестанская область' },
  { id: 'da6051e2-9354-4112-b6a6-cbb68d6b3dc3', name: 'Улытауская область' },
  { id: 'b78de8c7-9922-4ef8-97f7-7596feff8e24', name: 'Область Абай' },
  { id: 'f4d073bc-55bc-426b-9237-cf417b58943e', name: 'Область Жетісу' },
]

export const BREEDS = [
  { id: 'kazakh_whiteheaded', name: 'Казахская белоголовая' },
  { id: 'angus', name: 'Ангус' },
  { id: 'hereford', name: 'Герефорд' },
  { id: 'simmental', name: 'Симментальская' },
  { id: 'auliekol', name: 'Аулиекольская' },
  { id: 'kalmyk', name: 'Калмыцкая' },
  { id: 'mixed', name: 'Смешанная' },
]

export const HERD_SIZES = [
  { value: 'under_50', label: 'до 50' },
  { value: '51_100', label: '51-100' },
  { value: '100_300', label: '100-300' },
  { value: '300_500', label: '300-500' },
  { value: '500_1000', label: '500-1000' },
  { value: 'over_1000', label: '1000+' },
]

export const LEGAL_FORMS = [
  { value: 'kh', label: 'КХ' },
  { value: 'ip', label: 'ИП' },
  { value: 'too', label: 'ТОО' },
  { value: 'individual', label: 'Физлицо' },
]

export const COMPANY_TYPES = [
  { value: 'feedlot', label: 'Откормочная площадка' },
  { value: 'meatpacking', label: 'Мясокомбинат' },
  { value: 'feedlot_processing', label: 'Откорм+переработка' },
  { value: 'trader', label: 'Трейдер' },
]

export const MONTHLY_VOLUMES = [
  { value: 'under_100', label: 'до 100 голов' },
  { value: '100_500', label: '100-500' },
  { value: '500_1000', label: '500-1000' },
  { value: 'over_1000', label: '1000+' },
]

export const TARGET_WEIGHTS = [
  { value: '350_400', label: '350-400 кг' },
  { value: '400_450', label: '400-450 кг' },
  { value: '450_500', label: '450-500 кг' },
  { value: 'over_500', label: '500+ кг' },
  { value: 'various', label: 'Разный' },
]

export const PROCUREMENT_FREQUENCIES = [
  { value: 'weekly', label: 'Еженедельно' },
  { value: 'biweekly', label: 'Раз в 2 недели' },
  { value: 'monthly', label: 'Ежемесячно' },
  { value: 'seasonal', label: 'Сезонно' },
]

export const SERVICE_TYPES = [
  { value: 'veterinary', label: 'Ветеринария' },
  { value: 'zootechnics', label: 'Зоотехния' },
  { value: 'logistics', label: 'Логистика' },
  { value: 'insurance', label: 'Страхование' },
  { value: 'legal', label: 'Юридические услуги' },
  { value: 'certification', label: 'Сертификация' },
  { value: 'other', label: 'Другое' },
]

export const FEED_TYPES = [
  { value: 'hay', label: 'Сено' },
  { value: 'haylage', label: 'Сенаж' },
  { value: 'silage', label: 'Силос' },
  { value: 'compound_feed', label: 'Комбикорм' },
  { value: 'grain', label: 'Зерновые' },
  { value: 'oilcake', label: 'Жмых/шрот' },
  { value: 'minerals', label: 'Минеральные добавки' },
  { value: 'other', label: 'Другое' },
]

export const PRODUCTION_VOLUMES = [
  { value: 'small', label: 'Малый (до 100 т/мес)' },
  { value: 'medium', label: 'Средний (100-500)' },
  { value: 'large', label: 'Крупный (500-1000)' },
  { value: 'industrial', label: 'Промышленный (1000+)' },
]

export const READY_TO_SELL = [
  { value: 'now', label: 'Готов сейчас' },
  { value: '1_3_months', label: '1-3 мес' },
  { value: '3_6_months', label: '3-6 мес' },
  { value: 'exploring', label: 'Пока изучаю' },
]

export const HOW_HEARD = [
  { value: 'recommendation', label: 'Рекомендация' },
  { value: 'messenger', label: 'WhatsApp/Telegram' },
  { value: 'social', label: 'Соцсети' },
  { value: 'event', label: 'Мероприятие' },
  { value: 'feed_supplier', label: 'Поставщик кормов' },
  { value: 'other', label: 'Другое' },
]

export const EXPERT_SPECIALIZATIONS = [
  { value: 'vet', label: 'Ветеринар' },
  { value: 'zootechnics', label: 'Зоотехник' },
  { value: 'agronomist', label: 'Агроном' },
  { value: 'lawyer', label: 'Юрист' },
]

export const EXPERT_EXPERIENCE = [
  { value: 'under_3', label: 'до 3 лет' },
  { value: '3_5', label: '3–5 лет' },
  { value: '5_10', label: '5–10 лет' },
  { value: 'over_10', label: '10+ лет' },
]

export type RoleType = 'farmer' | 'mpk' | 'services' | 'feed_producer' | 'expert'

export interface RegistrationFormData {
  role: RoleType | null
  full_name: string
  phone: string
  region_id: string
  // Auth
  otp_sent: boolean
  otp_verified: boolean
  verification_id: string
  password: string
  // Farmer
  farm_name: string
  bin_iin: string
  legal_form: string
  herd_size: string
  primary_breed: string
  ready_to_sell: string
  // MPK
  company_name: string
  bin: string
  company_type: string
  monthly_volume: string
  target_breeds: string[]
  target_weight: string
  procurement_frequency: string
  // Services
  service_types: string[]
  service_regions: string[]
  // Feed producer
  feed_types: string[]
  production_volume: string
  delivery_regions: string[]
  // Expert
  expert_specializations: string[]
  expert_experience: string
  expert_visit_price: string
  expert_about: string
  expert_docs: Record<string, boolean>
  // Agreement
  consent_terms: boolean
  consent_data: boolean
  how_heard: string
  // Membership
  membership_notes: string
}

export const INITIAL_FORM_DATA: RegistrationFormData = {
  role: null,
  full_name: '',
  phone: '',
  region_id: '',
  otp_sent: false,
  otp_verified: false,
  verification_id: '',
  password: '',
  farm_name: '',
  bin_iin: '',
  legal_form: '',
  herd_size: '',
  primary_breed: '',
  ready_to_sell: '',
  company_name: '',
  bin: '',
  company_type: '',
  monthly_volume: '',
  target_breeds: [],
  target_weight: '',
  procurement_frequency: '',
  service_types: [],
  service_regions: [],
  feed_types: [],
  production_volume: '',
  delivery_regions: [],
  expert_specializations: [],
  expert_experience: '',
  expert_visit_price: '',
  expert_about: '',
  expert_docs: {},
  consent_terms: false,
  consent_data: false,
  how_heard: '',
  membership_notes: '',
}
