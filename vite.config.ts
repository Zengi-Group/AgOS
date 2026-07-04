/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react-swc';
import { VitePWA } from 'vite-plugin-pwa';
import path from 'path';
import { fileURLToPath } from 'node:url';
import { storybookTest } from '@storybook/addon-vitest/vitest-plugin';
import { playwright } from '@vitest/browser-playwright';
const dirname = typeof __dirname !== 'undefined' ? __dirname : path.dirname(fileURLToPath(import.meta.url));

// ── v5-остров для @ionic/react-router (ADR-NATIVE-ROUTER-01 AMEND-1, гейт-спайк ARS-148) ──
// @ionic/react-router статически импортирует v5-only API ('react-router'/'react-router-dom').
// Перенаправляем эти bare-импорты на v5-копии (alias-пакеты react-router-v5 /
// react-router-dom-v5) ТОЛЬКО когда импортёр — внутри island-пакетов; остальное приложение
// продолжает резолвить v6. Redirect унифицирует и вложенную копию react-router внутри
// react-router-dom-v5 — один v5-инстанс, иначе ломается RouterContext.
function ionicV5Island() {
  const ISLAND = ['@ionic/react-router/', 'react-router-dom-v5/', 'react-router-v5/'];
  const inIsland = (importer?: string) =>
    !!importer && ISLAND.some((p) => importer.includes(`node_modules/${p}`));
  return {
    name: 'agos:ionic-v5-island',
    enforce: 'pre' as const,
    resolveId(this: any, source: string, importer?: string) {
      if (!inIsland(importer)) return null;
      if (source === 'react-router') return this.resolve('react-router-v5', importer, { skipSelf: true });
      if (source === 'react-router-dom') return this.resolve('react-router-dom-v5', importer, { skipSelf: true });
      return null;
    },
  };
}

// More info at: https://storybook.js.org/docs/next/writing-tests/integrations/vitest-addon
export default defineConfig({
  optimizeDeps: {
    // island-пакеты не пре-бандлим esbuild'ом (он не видит наш resolveId-plugin) —
    // их импорты должны идти через Vite-пайплайн, где работает redirect.
    exclude: ['@ionic/react-router', 'react-router-v5', 'react-router-dom-v5'],
    // CJS-зависимости исключённых пакетов обязаны пре-бандлиться с ESM-интеропом
    // (иначе `import PropTypes from 'prop-types'` падает) — вложенный include-синтаксис Vite.
    include: [
      'react-router-dom-v5 > prop-types',
      'react-router-v5 > prop-types',
      'react-router-v5 > path-to-regexp',
      'react-router-dom-v5 > path-to-regexp',
      'react-router-v5 > hoist-non-react-statics',
      'react-router-dom-v5 > hoist-non-react-statics',
      'react-router-v5 > react-is',
      'react-router-dom-v5 > react-is',
    ],
  },
  plugins: [
    ionicV5Island(),
    react(),
    // PWA-гигиена (EngSpec §5, ARS-147): SW = precache app-shell, регистрация —
    // вручную через Host Bridge (только web); manifest — свой в public/.
    VitePWA({
      injectRegister: false,
      manifest: false,
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
        // precache = app-shell; тяжёлые маркетинговые фоны публичного сайта (6-8 МБ)
        // не кешируем — 3G-бюджеты Dok6
        globIgnores: ['images/**', 'vision/**'],
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        // SPA-fallback; RPC/поллинг НЕ кешируем — supabase-запросы идут мимо SW.
        navigateFallback: '/index.html',
        runtimeCaching: [],
      },
    }),
  ],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src')
    }
  },
  test: {
    projects: [{
      // S3 (ARS-149): unit-тесты платформенных адаптеров (node, без DOM/браузера).
      extends: true,
      test: {
        name: 'unit',
        environment: 'node',
        include: ['src/platform/**/*.test.ts']
      }
    }, {
      extends: true,
      plugins: [
      // The plugin will run tests for the stories defined in your Storybook config
      // See options at: https://storybook.js.org/docs/next/writing-tests/integrations/vitest-addon#storybooktest
      storybookTest({
        configDir: path.join(dirname, '.storybook')
      })],
      test: {
        name: 'storybook',
        browser: {
          enabled: true,
          headless: true,
          provider: playwright({}),
          instances: [{
            browser: 'chromium'
          }]
        }
      }
    }]
  }
});