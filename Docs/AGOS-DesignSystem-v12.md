# AGOS Design System — v12

**Status:** Adopted 2026-04-25 (see [DECISIONS_LOG.md](../DECISIONS_LOG.md) → "TURAN DS v12 — token refresh from Claude Design handoff").
**Source:** Claude Design handoff bundle `sUQuD5CZM096QCWYHxG0NQ` → exported HTML/CSS prototypes.
**Scope in production code:** `[data-shell]` only — `/admin` (and expert console). Landing (`:root`) and Registration (`.reg-*`) are **not governed** by this doc; they have their own legacy palette.
**Farmer zone carve-out (2026-07-10, D-UI-FARMER-RULES-01):** the farmer cabinet `/cabinet` (`.agos-cabinet-stage`) and the auth funnel were redesigned from the `Zengi-Group/agos-farmer` prototype and are governed by **`Docs/AGOS-DesignRules-FarmerCabinet.md`** — notably **Phosphor icons via `PhIcon`**, not lucide. Token *names* (`--bg/--fg/--bd/…`) stay v12-compatible; values differ (warm daylight palette).

---

## Authority chain

| Layer | Authoritative file |
|---|---|
| Tokens (deployed) | `src/index.css` — `[data-shell]` and `[data-shell][data-theme="light"]` blocks |
| Tokens (canonical reference) | `Docs/design-system-v12/colors_and_type.css` — exported from Claude Design, frozen as the v12 baseline |
| Preview cards | `Docs/design-system-v12/preview/*.html` — 40 self-contained HTML files, open in any browser |
| Foundations rules | this file (§ Visual foundations, § Iconography) |
| Component contracts (per screen) | Dok 6 slice files (`AGOS-Dok6-Slice*.md`) |

When the deployed CSS and the canonical reference disagree → the deployed CSS is the actual product behavior; the reference is the design intent. Both must be reconciled (architect responsibility).

---

## Preview catalog

Open any file in a browser — they import `_shared.css` which loads Geist via Google Fonts. No build, no React, no JS framework — just CSS.

### Foundations (15)
- Colors: `colors-brand.html`, `colors-cta.html`, `colors-neutral-light.html`, `colors-neutral-dark.html`, `colors-status.html`
- Type: `type-scale.html`, `type-weights.html`, `type-mono.html`, `type-roles.html`, `letter-spacing.html`, `brand-fonts.html`
- Layout: `spacing.html`, `radii.html`, `heights.html`, `surface-hierarchy.html`
- Effects: `shadows.html`, `motion.html`

### Brand (3)
- `logo-mark.html` — star + wordmark, horizontal/stacked/compact
- `logo-usage.html` — clearspace, do/don't
- `iconography.html` — lucide stroke 1.5/1.8 catalogue

### Components (22)
- Inputs: `inputs.html`, `textarea.html`, `token-input.html`, `select-dropdown.html`, `date-picker.html`
- Buttons: `buttons.html`, `button-pill.html`
- Display: `badges.html`, `avatars.html`, `card-component.html`, `table-row.html`
- Navigation: `menu-dropdown.html`, `tabs.html`, `pagination.html`, `option-list.html`, `filter-chips.html`
- Feedback: `disclaimer.html`, `toast.html`, `skeleton.html`
- Misc: `scrollbar.html`

---

## Visual foundations (governing rules for `/cabinet` and `/admin`)

### Surface hierarchy (4 levels — Attio/Vercel pattern)

```
L0 page    → var(--bg)     deepest base
L1 sidebar → var(--bg-s)   +1 step
L2 card    → var(--bg-c)   elevated above page
L3 hover   → var(--bg-m)   active state
```

**Inputs sit one step darker than the card they live in** — inverse of mainstream UX but matches Attio/Vercel. This is why `--background` (shadcn input bg) is mapped to `--bg-c` (which is dark on dark theme, light on light theme) — the input *appears* recessed inside its card.

### CTA discipline

- **One CTA per screen.** It carries the dark CTA color (`--cta` = `#3d2b1f` in light, `#e6e2dc` in dark).
- `--accent` (orange `#E8920B` / `#F0A020`) is **brand-only** — Turan star, never on buttons. ≤ 5% of any surface.
- All other actions are ghost/secondary (transparent or `--bg-m` background).

### Borders

- `1px solid var(--bd)` default, `var(--bd-s)` for dense table dividers, `var(--bd-h)` for hover/focus.
- Focus ring: `2px solid var(--bd-h)` with `outline-offset: 2px` (already global on `[data-shell] *:focus-visible` per `src/index.css`).
- No border thicker than 2px outside focus.

### Type

- Family: **Geist** (UI), **Geist Mono** (numbers, IDs, code, keyboard hints). Inter and JetBrains Mono remain as fallbacks for users on slow networks who haven't cached Geist yet.
- Strict scale: `10 / 11 / 12 / 13 / 14 / 15 / 20 px`. **No half-steps.**
- Weights: `400 / 500 / 600 / 700`. `500` for medium emphasis (name in a table row), `600` for headings and labels, `700` for `XL 20px` only.
- Letter-spacing: `-0.01em` on logo and 20px headings; `0.04–0.06em` on UPPERCASE section labels; `0` everywhere else.

### Heights (calibrated to AGOS surfaces)

| Token | Px | Use |
|---|---|---|
| `--h-xs` | 24 | filter chips, tag inputs, tiny badges |
| `--h-sm` | 28 | dense/compact mode, icon buttons |
| `--h-md` | 32 | **default** for all interactive controls (CTA, input, nav item) |
| `--h-lg` | 36 | edit-form inputs, dense table row |
| `--h-row` | 48 | **default table row** (farmer list, herd list) |
| `--h-xl` | 56 | page header / main toolbar |

40 and 44 are intentionally absent — pick 36 (compact) or 48 (comfortable). 44 is a touch-target heuristic for mobile-first apps; AGOS is desktop-first ERP.

### Motion

One easing across the system: `cubic-bezier(0.16, 1, 0.3, 1)` (spring-like). Four durations:
- `--dur-fast 60ms` — hover, dropdown open, focus ring
- `--dur-default 80ms` — color, border
- `--dur-slow 150ms` — modal, command palette
- `--dur-layout 250ms` — sidebar collapse, panel slide

Skeleton shimmer is the only `linear` easing. Page transitions are instant (no animation).

### Forbidden

- Gradients on backgrounds
- Glow / colored shadows
- Inner shadows
- Scale-transform on press (`scale(0.95)` etc.)
- Bounce / spring effects on UI controls
- Emoji anywhere in interface copy
- Decorative illustrations
- `--accent` (orange) on anything except the Turan star

---

## Iconography

> **Zone split (D-UI-FARMER-RULES-01):** the rules below apply to `[data-shell]` (admin/expert) only. Farmer zone (`/cabinet`, auth funnel) = **Phosphor via `PhIcon`**, canon: `Docs/AGOS-DesignRules-FarmerCabinet.md` §3. Never mix the two libraries within one zone.

- **Library:** `lucide-react` (matches our shadcn/ui stack)
- **Stroke:** 1.5 default, 1.8 for active nav item (gives +15% weight without changing the icon)
- **Sizes:** 11 (kbd inline) · 12 (dot badge) · 13 (ghost button) · 14 (CTA / sheet close) · 15 (icon button default) · 16 (nav, inputs) · 28 (workspace logo) · 48 (empty states)
- **Color:** `var(--fg3)` default, `var(--fg2)` hover, `var(--fg)` active — icons are never tinted with brand color.
- **Status dots:** geometric 5px circles filled with status color — not icons.
- **Turan star:** separate SVG (`src/assets/turan-icon.svg`), stroke-free 8-pointed star in `--accent`. The only orange element in the UI.

---

## Apply checklist (for any new component in `/cabinet` or `/admin`)

1. **Background:** card → `var(--bg-c)`. Page → `var(--bg)`. Hover → `var(--bg-m)`. No literal hex.
2. **Border:** `1px solid var(--bd)`. Focus → `var(--bd-h)`. No literal hex.
3. **Text:** `color: var(--fg)`, secondary `var(--fg2)`, tertiary `var(--fg3)`. No literal hex.
4. **Font-family:** inherits from `[data-shell]` — do not override unless mono (`var(--font-mono)`).
5. **Font-size:** one of 7 scale steps via `var(--fs-*)` or literal matching value.
6. **Heights:** snap to `var(--h-*)` token, not free pixels.
7. **Spacing:** snap to `var(--sp-*)` token (4px grid).
8. **Radius:** `var(--r-md)` (button, input), `var(--r-lg)` (card), `var(--r-xl)` (modal), `var(--r-full)` (avatar, pill). No `8.5px` or other off-scale values.
9. **CTA:** `background: var(--cta)`, `color: var(--cta-fg)`, `:hover { background: var(--cta-h) }`. One per screen.
10. **Accent:** if you typed `var(--accent)` or `#E8920B` / `#F0A020`, you're rendering the Turan star. Otherwise, you're wrong.

If a design needs a value not in the token list, that's a tokens conversation — not a literal-hex shortcut.

---

## Out of scope (deferred)

- React/Storybook conversion of preview cards — they live as static HTML reference until/unless we add Storybook to the build.
- Landing/Registration restyling — separate sprint, separate decision.
- Component refactors of existing `src/components/` to the v12 tokens — they consume tokens via CSS vars and update automatically; manual refactor only if a component still uses literal hex.

---

## Maintenance

- Tokens change → update `src/index.css` AND `Docs/design-system-v12/colors_and_type.css` together, append to `DECISIONS_LOG.md`.
- New component pattern → add a new HTML preview to `Docs/design-system-v12/preview/`, then list it in the catalog above.
- Foundations rule change → edit this file, append to `DECISIONS_LOG.md`.
