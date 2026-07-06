# 02 — Вход и восстановление PIN (AUTH-*)

> Реальность: `src/pages/auth/Login.tsx`, `src/pages/auth/ForgotPin.tsx`,
> edge-функция bird-otp (`action=check`, `reset_pin`), `/admin` login.
> Маппинг из концепта: блок D → AUTH-LOG / AUTH-RST / AUTH-ADM.

---

## AUTH-LOG — вход по телефону + PIN

#### AUTH-LOG-01 · HAPPY · Вход по телефону и PIN
`layer:ui+rpc` `canon:code` `impl:src/pages/auth/Login.tsx` `auto:candidate:browser` `status:active`
- **Предусловие:** аккаунт существует.
- **Шаги:** /login: телефон 11 цифр → «Продолжить» → верный PIN.
- **Ожидание:** toast «Вход выполнен»; если пришли с deep-link (RequireAuth) — редирект на исходный путь; иначе `rpc_get_my_context` → pickShellPath: farmer → /cabinet, mpk (без farmer) → /mpk, иначе /cabinet.

#### AUTH-LOG-02 · UNHAPPY · Неполный номер
`layer:ui` `canon:code` `impl:src/pages/auth/Login.tsx` `auto:none` `status:active`
- **Ожидание:** «Введите номер телефона полностью»; шаг PIN не открывается.

#### AUTH-LOG-03 · UNHAPPY · Неверный PIN
`layer:ui` `canon:code` `impl:src/pages/auth/Login.tsx` `auto:none` `status:active`
- **Ожидание:** «Неверный PIN — попробуйте ещё раз»; поле очищено; сессия не создана.

#### AUTH-LOG-04 · EDGE · «Изменить номер» на шаге PIN
`layer:ui` `canon:code` `impl:src/pages/auth/Login.tsx` `auto:none` `status:active`
- **Ожидание:** возврат к вводу телефона; PIN и ошибка сброшены.

---

## AUTH-RST — восстановление PIN

#### AUTH-RST-01 · HAPPY · Восстановление PIN
`layer:ui+rpc` `canon:code` `impl:src/pages/auth/ForgotPin.tsx` `auto:none` `status:active`
- **Шаги:** /forgot-pin (телефон предзаполнен из Login): отправить OTP → верный код → новый PIN → повторить.
- **Ожидание:** bird-otp `reset_pin` меняет пароль через admin API; toast «PIN успешно изменён»; редирект на /login; старый PIN не работает, новый — работает.

#### AUTH-RST-02 · UNHAPPY · Номер не найден
`layer:rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Предусловие:** телефона нет в auth.
- **Ожидание:** «Пользователь с этим номером не найден»; PIN не изменён.

#### AUTH-RST-03 · UNHAPPY · Новый PIN не совпал
`layer:ui` `canon:code` `impl:src/pages/auth/ForgotPin.tsx` `auto:none` `status:active`
- **Ожидание:** «PIN-коды не совпадают — попробуйте снова», возврат к первому вводу.

#### AUTH-RST-04 · UNHAPPY · OTP-ошибки при восстановлении
`layer:rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Ожидание:** неверный/истёкший код, >3 попыток — те же ожидания, что REG-OTP-07…09 (общая edge-функция).

---

## AUTH-ADM — вход админа

#### AUTH-ADM-01 · HAPPY · Вход админа
`layer:ui` `canon:code` `impl:src/pages/auth` `auto:none` `status:active`
- **Предусловие:** админ создан seed-скриптом.
- **Шаги:** /admin login: логин `admin` + пароль.
- **Ожидание:** логин без @ достраивается до admin@agos.local; успешный вход → редирект /admin; разделы дополнительно охраняет RequireExpert/`fn_is_admin`.

#### AUTH-ADM-02 · UNHAPPY · Админ: неверные креды
`layer:ui` `canon:code` `impl:src/pages/auth` `auto:none` `status:active`
- **Ожидание:** «Неверный логин или пароль»; поле пароля очищено.
