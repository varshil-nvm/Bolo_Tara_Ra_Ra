import js from '@eslint/js';
import prettier from 'eslint-config-prettier';
import tseslint from '@typescript-eslint/eslint-plugin';
import tsparser from '@typescript-eslint/parser';

export default [
  js.configs.recommended,
  prettier,
  {
    files: ['**/*.js', '**/*.ts'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      parser: tsparser,
      globals: {
        console: 'readonly',
        process: 'readonly',
        Buffer: 'readonly',
        __dirname: 'readonly',
        __filename: 'readonly',
        global: 'readonly',
      },
    },
    plugins: {
      '@typescript-eslint': tseslint,
    },
    rules: {
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': 'warn',
      'no-console': 'off',
      'prefer-const': 'error',
    },
  },
  {
    files: ['test/**/*.js', 'test/**/*.ts'],
    rules: {
      'no-unused-expressions': 'off',
    },
  },
  {
    ignores: ['artifacts/**/*', 'cache/**/*', 'node_modules/**/*', 'dist/**/*', '*.d.ts'],
  },
];
