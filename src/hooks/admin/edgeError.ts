// supabase.functions.invoke на не-2xx ответе возвращает FunctionsHttpError,
// тело ответа лежит в error.context (Response). Достаём из него поле error.
export async function readEdgeError(error: unknown, fallback: string): Promise<string> {
  const ctx = (error as { context?: Response } | null)?.context
  if (ctx && typeof ctx.json === 'function') {
    try {
      const body = await ctx.clone().json()
      if (body?.error) return body.error as string
    } catch {
      /* тело не JSON — используем fallback */
    }
  }
  return (error as Error)?.message || fallback
}
