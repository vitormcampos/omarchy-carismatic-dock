import { configDefaults, defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['tests/js/**/*.test.mjs'],
    // Tests read QML/JS via fs/CommonJS, outside Vite's import graph.
    // Rerun the suite for these sources, including files in subdirectories.
    forceRerunTriggers: [
      ...configDefaults.forceRerunTriggers,
      '**/*.{qml,js}',
    ],
  },
});
