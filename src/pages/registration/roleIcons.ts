/**
 * Иконки ролей вход-фаннела — единый источник (P4).
 * Тонкий минималистичный набор Phosphor (weight="light"), используется
 * и в выборе роли (RoleSelect), и в шапке экрана возможностей (BenefitScreen).
 */
import { Cow, Factory, Wrench, Plant, GraduationCap, type Icon as PhosphorIcon } from '@phosphor-icons/react'
import type { RoleType } from './constants'

export const ROLE_ICONS: Record<RoleType, PhosphorIcon> = {
  farmer: Cow,
  mpk: Factory,
  services: Wrench,
  feed_producer: Plant,
  expert: GraduationCap,
}
