import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { defineConfig } from '@playwright/test';

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const baseURL = process.env.PLAYWRIGHT_BASE_URL ?? 'http://127.0.0.1:9010';
const databasePath = path.join(
    currentDirectory,
    'database',
    'playwright.sqlite',
);

const webServerEnvironment = {
    ...process.env,
    APP_ENV: 'playwright',
    APP_URL: baseURL,
    DB_CONNECTION: 'sqlite',
    DB_DATABASE: databasePath,
    CACHE_STORE: 'array',
    MAIL_MAILER: 'array',
    QUEUE_CONNECTION: 'sync',
    SESSION_DRIVER: 'file',
    BROADCAST_CONNECTION: 'log',
    PULSE_ENABLED: 'false',
    TELESCOPE_ENABLED: 'false',
    NIGHTWATCH_ENABLED: 'false',
};

export default defineConfig({
    testDir: './tests/e2e',
    fullyParallel: false,
    workers: 1,
    retries: process.env.CI ? 1 : 0,
    timeout: 90_000,
    expect: {
        timeout: 10_000,
    },
    use: {
        baseURL,
        trace: 'retain-on-failure',
        screenshot: 'only-on-failure',
        video: 'retain-on-failure',
        launchOptions: process.env.PLAYWRIGHT_EXECUTABLE_PATH
            ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH }
            : undefined,
    },
    projects: [
        {
            name: 'setup',
            testMatch: /setup[\\/].*\.spec\.ts/,
        },
        {
            name: 'chromium',
            testMatch: /specs[\\/].*\.spec\.ts/,
            dependencies: ['setup'],
        },
    ],
    webServer: {
        command:
            'npm run build && php artisan serve --host=127.0.0.1 --port=9010',
        url: `${baseURL}/up`,
        reuseExistingServer: !process.env.CI,
        timeout: 180_000,
        env: webServerEnvironment,
    },
});
