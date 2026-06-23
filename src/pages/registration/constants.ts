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

// Районы РК по областям, ключ — id региона из REGIONS.
// P8: пока hardcode (как REGIONS), в будущем грузить из public.regions (level=3, parent_id=область).
// ВНИМАНИЕ: список сгенерирован и требует вычитки перед продом.
export const DISTRICTS: Record<string, { value: string; label: string }[]> = {
  // Алматы (город)
  '6a8fb31b-fd23-494b-9145-24810bc0e312': [
    { value: 'alatauskiy', label: 'Алатауский' },
    { value: 'almalinskiy', label: 'Алмалинский' },
    { value: 'auezovskiy', label: 'Ауэзовский' },
    { value: 'bostandykskiy', label: 'Бостандыкский' },
    { value: 'zhetysuskiy', label: 'Жетысуский' },
    { value: 'medeuskiy', label: 'Медеуский' },
    { value: 'nauryzbayskiy', label: 'Наурызбайский' },
    { value: 'turksibskiy', label: 'Турксибский' },
  ],
  // Астана (город)
  '88e0fb13-c1ec-4682-aaa1-7360ae1728f0': [
    { value: 'almatinskiy', label: 'Алматинский' },
    { value: 'baykonurskiy', label: 'Байконурский' },
    { value: 'esilskiy', label: 'Есильский' },
    { value: 'saryarkinskiy', label: 'Сарыаркинский' },
    { value: 'nura', label: 'Нура' },
  ],
  // Шымкент (город)
  '281318d8-3f90-42bd-a0a8-17a2890d672d': [
    { value: 'abayskiy', label: 'Абайский' },
    { value: 'alfarabiyskiy', label: 'Аль-Фарабийский' },
    { value: 'enbekshinskiy', label: 'Енбекшинский' },
    { value: 'karatauskiy', label: 'Каратауский' },
    { value: 'turan', label: 'Туран' },
  ],
  // Акмолинская область
  '9a2dfc64-1d02-4133-af61-83c06a0061c0': [
    { value: 'akkolskiy', label: 'Аккольский' },
    { value: 'arshalynskiy', label: 'Аршалынский' },
    { value: 'astrahanskiy', label: 'Астраханский' },
    { value: 'atbasarskiy', label: 'Атбасарский' },
    { value: 'bulandynskiy', label: 'Буландынский' },
    { value: 'burabayskiy', label: 'Бурабайский' },
    { value: 'egindykolskiy', label: 'Егиндыкольский' },
    { value: 'birzhan_sal', label: 'Биржан сал (Енбекшильдерский)' },
    { value: 'ereymentauskiy', label: 'Ерейментауский' },
    { value: 'esilskiy', label: 'Есильский' },
    { value: 'zhaksynskiy', label: 'Жаксынский' },
    { value: 'zharkainskiy', label: 'Жаркаинский' },
    { value: 'zerendinskiy', label: 'Зерендинский' },
    { value: 'korgalzhynskiy', label: 'Коргалжынский' },
    { value: 'sandyktauskiy', label: 'Сандыктауский' },
    { value: 'tselinogradskiy', label: 'Целиноградский' },
    { value: 'shortandinskiy', label: 'Шортандинский' },
    { value: 'g_kokshetau', label: 'г. Кокшетау' },
    { value: 'g_stepnogorsk', label: 'г. Степногорск' },
  ],
  // Актюбинская область
  'd8a2de40-cfcc-46a3-a29c-c52c9e1391d1': [
    { value: 'aytekebiyskiy', label: 'Айтекебийский' },
    { value: 'alginskiy', label: 'Алгинский' },
    { value: 'bayganinskiy', label: 'Байганинский' },
    { value: 'irgizskiy', label: 'Иргизский' },
    { value: 'kargalinskiy', label: 'Каргалинский' },
    { value: 'martukskiy', label: 'Мартукский' },
    { value: 'mugalzharskiy', label: 'Мугалжарский' },
    { value: 'uilskiy', label: 'Уилский' },
    { value: 'khobdinskiy', label: 'Хобдинский' },
    { value: 'khromtauskiy', label: 'Хромтауский' },
    { value: 'shalkarskiy', label: 'Шалкарский' },
    { value: 'temirskiy', label: 'Темирский' },
    { value: 'g_aktobe', label: 'г. Актобе' },
  ],
  // Алматинская область
  '0f1abcc1-f598-456a-bd22-b7c0a0c64dab': [
    { value: 'balkhashskiy', label: 'Балхашский' },
    { value: 'enbekshikazahskiy', label: 'Енбекшиказахский' },
    { value: 'zhambylskiy', label: 'Жамбылский' },
    { value: 'iliyskiy', label: 'Илийский' },
    { value: 'karasayskiy', label: 'Карасайский' },
    { value: 'kegenskiy', label: 'Кегенский' },
    { value: 'rayymbekskiy', label: 'Райымбекский' },
    { value: 'talgarskiy', label: 'Талгарский' },
    { value: 'uygurskiy', label: 'Уйгурский' },
    { value: 'g_konaev', label: 'г. Конаев' },
  ],
  // Атырауская область
  '96f2d435-25ba-4a34-82d9-14bab14ddf1d': [
    { value: 'zhylyoyskiy', label: 'Жылыойский' },
    { value: 'inderskiy', label: 'Индерский' },
    { value: 'isatayskiy', label: 'Исатайский' },
    { value: 'kurmangazinskiy', label: 'Курмангазинский' },
    { value: 'kyzylkoginskiy', label: 'Кызылкогинский' },
    { value: 'makatskiy', label: 'Макатский' },
    { value: 'makhambetskiy', label: 'Махамбетский' },
    { value: 'g_atyrau', label: 'г. Атырау' },
  ],
  // Восточно-Казахстанская область
  '3d56538b-d080-40d7-a6ec-bc60d2696dec': [
    { value: 'glubokovskiy', label: 'Глубоковский' },
    { value: 'zaysanskiy', label: 'Зайсанский' },
    { value: 'katon_karagayskiy', label: 'Катон-Карагайский' },
    { value: 'kurchumskiy', label: 'Курчумский' },
    { value: 'tarbagatayskiy', label: 'Тарбагатайский' },
    { value: 'ulanskiy', label: 'Уланский' },
    { value: 'shemonaihinskiy', label: 'Шемонаихинский' },
    { value: 'altay', label: 'Алтай (Зыряновский)' },
    { value: 'samarskiy', label: 'Самарский' },
    { value: 'g_ust_kamenogorsk', label: 'г. Усть-Каменогорск' },
    { value: 'g_ridder', label: 'г. Риддер' },
  ],
  // Жамбылская область
  'b232963a-8cf5-468b-9f8c-234c770bb8b8': [
    { value: 'bayzakskiy', label: 'Байзакский' },
    { value: 'zhambylskiy', label: 'Жамбылский' },
    { value: 'zhualynskiy', label: 'Жуалынский' },
    { value: 'kordayskiy', label: 'Кордайский' },
    { value: 'merkenskiy', label: 'Меркенский' },
    { value: 'moyynkumskiy', label: 'Мойынкумский' },
    { value: 'sarysuskiy', label: 'Сарысуский' },
    { value: 'talasskiy', label: 'Таласский' },
    { value: 'turar_ryskulovskiy', label: 'Турар Рыскуловский' },
    { value: 'shuskiy', label: 'Шуский' },
    { value: 'g_taraz', label: 'г. Тараз' },
  ],
  // Западно-Казахстанская область
  'b841e25c-327d-4e9c-b4d3-be5e74c55f50': [
    { value: 'akzhayykskiy', label: 'Акжайыкский' },
    { value: 'bokeyordinskiy', label: 'Бокейординский' },
    { value: 'burlinskiy', label: 'Бурлинский' },
    { value: 'zhangalinskiy', label: 'Жангалинский' },
    { value: 'zhanibekskiy', label: 'Жанибекский' },
    { value: 'bayterek', label: 'Бәйтерек (Зеленовский)' },
    { value: 'kaztalovskiy', label: 'Казталовский' },
    { value: 'karatobinskiy', label: 'Каратобинский' },
    { value: 'syrymskiy', label: 'Сырымский' },
    { value: 'taskalinskiy', label: 'Таскалинский' },
    { value: 'terektinskiy', label: 'Теректинский' },
    { value: 'chingirlauskiy', label: 'Чингирлауский' },
    { value: 'g_uralsk', label: 'г. Уральск' },
  ],
  // Карагандинская область
  'a950545c-fcdb-487e-87f5-a746f798b9f2': [
    { value: 'abayskiy', label: 'Абайский' },
    { value: 'aktogayskiy', label: 'Актогайский' },
    { value: 'buhar_zhyrauskiy', label: 'Бухар-Жырауский' },
    { value: 'karkaralinskiy', label: 'Каркаралинский' },
    { value: 'nurinskiy', label: 'Нуринский' },
    { value: 'osakarovskiy', label: 'Осакаровский' },
    { value: 'shetskiy', label: 'Шетский' },
    { value: 'g_karaganda', label: 'г. Караганда' },
    { value: 'g_temirtau', label: 'г. Темиртау' },
    { value: 'g_balkhash', label: 'г. Балхаш' },
    { value: 'g_saran', label: 'г. Сарань' },
    { value: 'g_shakhtinsk', label: 'г. Шахтинск' },
  ],
  // Костанайская область
  'b72d8c3b-505a-4986-bb82-a5abcf772174': [
    { value: 'altynsarinskiy', label: 'Алтынсаринский' },
    { value: 'amangeldinskiy', label: 'Амангельдинский' },
    { value: 'auliekolskiy', label: 'Аулиекольский' },
    { value: 'denisovskiy', label: 'Денисовский' },
    { value: 'zhangeldinskiy', label: 'Жангельдинский' },
    { value: 'zhitikarinskiy', label: 'Житикаринский' },
    { value: 'kamystinskiy', label: 'Камыстинский' },
    { value: 'karabalykskiy', label: 'Карабалыкский' },
    { value: 'karasuskiy', label: 'Карасуский' },
    { value: 'kostanayskiy', label: 'Костанайский' },
    { value: 'mendykarinskiy', label: 'Мендыкаринский' },
    { value: 'naurzumskiy', label: 'Наурзумский' },
    { value: 'sarykolskiy', label: 'Сарыкольский' },
    { value: 'beimbet_maylin', label: 'Беимбет Майлина (Тарановский)' },
    { value: 'uzunkolskiy', label: 'Узункольский' },
    { value: 'fedorovskiy', label: 'Федоровский' },
    { value: 'g_kostanay', label: 'г. Костанай' },
    { value: 'g_rudnyy', label: 'г. Рудный' },
    { value: 'g_lisakovsk', label: 'г. Лисаковск' },
    { value: 'g_arkalyk', label: 'г. Аркалык' },
  ],
  // Кызылординская область
  '4dff644d-2ee2-4c7c-8581-5182cf542cbd': [
    { value: 'aralskiy', label: 'Аральский' },
    { value: 'zhalagashskiy', label: 'Жалагашский' },
    { value: 'zhanakorganskiy', label: 'Жанакорганский' },
    { value: 'kazalinskiy', label: 'Казалинский' },
    { value: 'karmakshinskiy', label: 'Кармакшинский' },
    { value: 'syrdarinskiy', label: 'Сырдарьинский' },
    { value: 'shieliyskiy', label: 'Шиелийский' },
    { value: 'g_kyzylorda', label: 'г. Кызылорда' },
  ],
  // Мангистауская область
  '5b2cf821-7808-41ce-943d-ed8fd2a75f1d': [
    { value: 'beyneuskiy', label: 'Бейнеуский' },
    { value: 'karakiyanskiy', label: 'Каракиянский' },
    { value: 'mangistauskiy', label: 'Мангистауский' },
    { value: 'munaylinskiy', label: 'Мунайлинский' },
    { value: 'tupkaraganskiy', label: 'Тупкараганский' },
    { value: 'g_aktau', label: 'г. Актау' },
    { value: 'g_zhanaozen', label: 'г. Жанаозен' },
  ],
  // Павлодарская область
  '7b53b2c0-9b48-47fd-99e6-6aed7d9843e8': [
    { value: 'akkulinskiy', label: 'Аккулинский (Лебяжинский)' },
    { value: 'aktogayskiy', label: 'Актогайский' },
    { value: 'bayanaulskiy', label: 'Баянаульский' },
    { value: 'zhelezinskiy', label: 'Железинский' },
    { value: 'irtyshskiy', label: 'Иртышский' },
    { value: 'terenkol', label: 'Теренкольский (Качирский)' },
    { value: 'mayskiy', label: 'Майский' },
    { value: 'pavlodarskiy', label: 'Павлодарский' },
    { value: 'uspenskiy', label: 'Успенский' },
    { value: 'shcherbaktinskiy', label: 'Щербактинский' },
    { value: 'g_pavlodar', label: 'г. Павлодар' },
    { value: 'g_ekibastuz', label: 'г. Экибастуз' },
    { value: 'g_aksu', label: 'г. Аксу' },
  ],
  // Северо-Казахстанская область
  '8e5fbff0-3616-46cf-985c-682c49779a04': [
    { value: 'ayyrtauskiy', label: 'Айыртауский' },
    { value: 'akkayynskiy', label: 'Аккайынский' },
    { value: 'akzharskiy', label: 'Акжарский' },
    { value: 'esilskiy', label: 'Есильский' },
    { value: 'zhambylskiy', label: 'Жамбылский' },
    { value: 'kyzylzharskiy', label: 'Кызылжарский' },
    { value: 'magzhan_zhumabaev', label: 'Магжана Жумабаева' },
    { value: 'mamlyutskiy', label: 'Мамлютский' },
    { value: 'gabit_musrepov', label: 'Габита Мусрепова' },
    { value: 'tayynshinskiy', label: 'Тайыншинский' },
    { value: 'timiryazevskiy', label: 'Тимирязевский' },
    { value: 'ualihanovskiy', label: 'Уалихановский' },
    { value: 'shal_akyna', label: 'Шал акына' },
    { value: 'g_petropavlovsk', label: 'г. Петропавловск' },
  ],
  // Туркестанская область
  'b83df0fa-ffcb-4733-874d-b45823e6cce7': [
    { value: 'baydibekskiy', label: 'Байдибекский' },
    { value: 'zhetysayskiy', label: 'Жетысайский' },
    { value: 'kazygurtskiy', label: 'Казыгуртский' },
    { value: 'kelesskiy', label: 'Келесский' },
    { value: 'maktaaralskiy', label: 'Мактааральский' },
    { value: 'ordabasynskiy', label: 'Ордабасынский' },
    { value: 'otyrarskiy', label: 'Отырарский' },
    { value: 'sayramskiy', label: 'Сайрамский' },
    { value: 'saryagashskiy', label: 'Сарыагашский' },
    { value: 'sauranskiy', label: 'Сауранский' },
    { value: 'suzakskiy', label: 'Сузакский' },
    { value: 'tolebiyskiy', label: 'Толебийский' },
    { value: 'tyulkubasskiy', label: 'Тюлькубасский' },
    { value: 'shardarinskiy', label: 'Шардаринский' },
    { value: 'g_turkestan', label: 'г. Туркестан' },
    { value: 'g_kentau', label: 'г. Кентау' },
    { value: 'g_arys', label: 'г. Арыс' },
  ],
  // Улытауская область
  'da6051e2-9354-4112-b6a6-cbb68d6b3dc3': [
    { value: 'zhanaarkinskiy', label: 'Жанааркинский' },
    { value: 'ulytauskiy', label: 'Улытауский' },
    { value: 'g_zhezkazgan', label: 'г. Жезказган' },
    { value: 'g_satpaev', label: 'г. Сатпаев' },
    { value: 'g_karazhal', label: 'г. Каражал' },
  ],
  // Область Абай
  'b78de8c7-9922-4ef8-97f7-7596feff8e24': [
    { value: 'ayagozskiy', label: 'Аягозский' },
    { value: 'beskaragayskiy', label: 'Бескарагайский' },
    { value: 'borodulihinskiy', label: 'Бородулихинский' },
    { value: 'zharminskiy', label: 'Жарминский' },
    { value: 'kokpektinskiy', label: 'Кокпектинский' },
    { value: 'urdzharskiy', label: 'Урджарский' },
    { value: 'aksuatskiy', label: 'Аксуатский' },
    { value: 'g_semey', label: 'г. Семей' },
    { value: 'g_kurchatov', label: 'г. Курчатов' },
  ],
  // Область Жетісу
  'f4d073bc-55bc-426b-9237-cf417b58943e': [
    { value: 'aksuskiy', label: 'Аксуский' },
    { value: 'alakolskiy', label: 'Алакольский' },
    { value: 'eskeldinskiy', label: 'Ескельдинский' },
    { value: 'karatalskiy', label: 'Каратальский' },
    { value: 'kerbulakskiy', label: 'Кербулакский' },
    { value: 'koksuskiy', label: 'Коксуский' },
    { value: 'panfilovskiy', label: 'Панфиловский' },
    { value: 'sarkanskiy', label: 'Сарканский' },
    { value: 'g_taldykorgan', label: 'г. Талдыкорган' },
    { value: 'g_tekeli', label: 'г. Текели' },
  ],
}

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
  { value: '101_300', label: '101-300' },
  { value: '301_500', label: '301-500' },
  { value: '501_1000', label: '501-1000' },
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
  district_id: string
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
  district_id: '',
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
