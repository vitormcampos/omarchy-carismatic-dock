import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['tests/js/**/*.test.mjs'],
    // These sources are read via fs/CommonJS, outside Vite's import graph.
    watchTriggerPatterns: [
      {
        pattern: /(?:^|[/\\])(?:DockWindow\.qml|DockModel\.js)$/,
        testsToRun: () => ['./tests/js/file-drop-target.test.mjs'],
      },
    ],
  },
});
