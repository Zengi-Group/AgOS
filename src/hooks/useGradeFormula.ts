/**
 * A-GRADE | Загрузка формулы сорта МПК из БД (rpc_get_grade_formula) и гидратация
 * модульных оверрайдов в tsp-utils (фермер) и mpk/types (МПК). Компоненты, которым
 * важна актуальная формула, вызывают этот хук — так они пере-рендерятся, когда данные
 * приходят, и pure-функции (deriveMpkGrade, mpkSortFloor, MPK_CATS-геттеры) читают
 * значения из БД. До загрузки работают захардкоженные фолбэки (= сид, поведение то же).
 */
import { useEffect } from 'react'
import { useRpc } from './useRpc'
import { setGradeFormula, type GradeFormulaRow } from '@/pages/cabinet/shell/tsp/data/tsp-utils'
import { setMpkFormula } from '@/pages/cabinet/shell/mpk/types'

export function useGradeFormula() {
  const q = useRpc<GradeFormulaRow[]>('rpc_get_grade_formula', {}, { staleTime: 300_000 })

  useEffect(() => {
    if (q.data) {
      setGradeFormula(q.data)
      setMpkFormula(q.data)
    }
  }, [q.data])

  return q
}
