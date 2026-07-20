// AgOS · ARS-225 · Реальный канал поддержки TURAN (фермер ↔ админ) на живых RPC.
// Источник истины — d12_messaging.sql: rpc_get_or_create_support_channel / rpc_list_messages /
// rpc_send_message / rpc_mark_channel_read. Модель по образцу farm-load.ts:
//   null = контекст не загрузился (аноним / RPC не задеплоен / сбой сети) → caller оставляет
//   ассоциативные дайджесты треда TURAN (мок), НЕ подменяя их. Реальные сообщения приходят
//   ДОБАВОЧНО к дайджестам (HS-2 / P7) — не заменяют их.

import { supabase } from '@/lib/supabase'

// Строка comm_messages в том виде, что отдаёт rpc_list_messages (SETOF comm_messages).
export interface CommMessage {
  id: string
  channel_id: string
  organization_id: string | null
  author_user_id: string | null
  author_actor_type: 'farmer' | 'admin' | 'expert' | 'system'
  body: string
  attachments: unknown[]
  is_deleted: boolean
  created_at: string
}

interface CommChannel {
  id: string
  organization_id: string
  channel_type: string
  status: string
  title: string | null
  last_message_at: string | null
}

export interface SupportThread {
  channelId: string
  messages: CommMessage[]   // по возрастанию времени (для ленты сверху вниз)
}

// get-or-create единый support-канал орг + лента сообщений. null = не загрузилось.
export async function loadSupportThread(orgId: string): Promise<SupportThread | null> {
  try {
    const { data: ch, error: chErr } = await supabase.rpc('rpc_get_or_create_support_channel', {
      p_organization_id: orgId,
    })
    const channel = ch as CommChannel | null
    if (chErr || !channel?.id) {
      if (chErr) console.warn('[messages-load] rpc_get_or_create_support_channel failed:', chErr)
      return null
    }

    const { data: rows, error: msgErr } = await supabase.rpc('rpc_list_messages', {
      p_channel_id: channel.id,
    })
    // Канал уже создан (get-or-create успешен). Если лента не загрузилась — НЕ теряем
    // channelId (иначе отправка упадёт в мок-фолбэк): отдаём канал с пустой лентой,
    // сообщения подтянутся следующим poll.
    if (msgErr) {
      console.warn('[messages-load] rpc_list_messages failed:', msgErr)
      return { channelId: channel.id, messages: [] }
    }
    const list = Array.isArray(rows) ? (rows as CommMessage[]) : []
    // rpc_list_messages отдаёт свежие сверху (created_at desc, keyset) — для ленты
    // разворачиваем в хронологический порядок (старые сверху, новые снизу).
    const ordered = list.slice().reverse().filter((m) => !m.is_deleted)
    return { channelId: channel.id, messages: ordered }
  } catch {
    return null
  }
}

// Отправка сообщения в канал. Возвращает true при успехе (для UI-фидбека).
export async function sendSupportMessage(
  channelId: string,
  body: string,
  attachments: unknown[] = []
): Promise<boolean> {
  try {
    // p_attachments — jsonb. supabase-js сам сериализует params в JSON, поэтому передаём
    // массив КАК ЕСТЬ (JSON.stringify здесь давал бы скалярную строку "[]" вместо []
    // → jsonb_array_length падал бы на скаляре в rpc_send_message).
    const { error } = await supabase.rpc('rpc_send_message', {
      p_channel_id: channelId,
      p_body: body,
      p_attachments: attachments,
    })
    if (error) console.warn('[messages-load] rpc_send_message failed:', error)
    return !error
  } catch (e) {
    console.warn('[messages-load] rpc_send_message threw:', e)
    return false
  }
}

// Пометить канал прочитанным (last_read_at = now) для текущего участника.
export async function markSupportRead(channelId: string): Promise<void> {
  try {
    await supabase.rpc('rpc_mark_channel_read', { p_channel_id: channelId })
  } catch {
    /* noop — best-effort, бейдж пересчитается на следующей загрузке */
  }
}
