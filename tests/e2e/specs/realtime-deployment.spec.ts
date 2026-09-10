import {
    expect,
    request,
    test,
    type APIRequestContext,
    type Page,
} from '@playwright/test';

type AuthState = Awaited<ReturnType<APIRequestContext['storageState']>>;

async function authenticate(baseURL: string, email: string): Promise<AuthState> {
    const api = await request.newContext({ baseURL });

    try {
        const loginPage = await api.get('/login');
        const loginHtml = await loginPage.text();
        const csrfToken =
            loginHtml.match(/<meta name="csrf-token" content="([^"]+)"/i)?.[1] ??
            loginHtml.match(/<input[^>]+name="_token"[^>]+value="([^"]+)"/i)?.[1] ??
            '';

        const loginResponse = await api.post('/login', {
            form: {
                _token: csrfToken,
                email,
                password: 'password',
            },
            headers: {
                'X-CSRF-TOKEN': csrfToken,
                Referer: new URL('/login', baseURL).toString(),
            },
        });

        expect(loginResponse.ok()).toBeTruthy();

        return await api.storageState();
    } finally {
        await api.dispose();
    }
}

async function openMahasiswaBimbinganThread(page: Page): Promise<void> {
    await page.goto('/mahasiswa/pesan');
    await expect(page).toHaveTitle(/Pesan/i);

    const threadButton = page
        .locator('button')
        .filter({ hasText: 'Bimbingan' })
        .first();

    await expect(threadButton).toBeVisible();
    await threadButton.click();
    await expect(page.getByPlaceholder('Tulis pesan...')).toBeEnabled();
}

async function openDosenBimbinganThread(page: Page): Promise<void> {
    await page.goto('/dosen/pesan-bimbingan');
    await expect(page).toHaveTitle(/Pesan Dosen/i);
    await page
        .getByPlaceholder(/Cari (mahasiswa|grup)\.\.\./)
        .fill('Mahasiswa SiTA');

    const threadButton = page
        .locator('button')
        .filter({ hasText: 'Mahasiswa SiTA' })
        .filter({ hasText: 'Bimbingan' })
        .first();

    await expect(threadButton).toBeVisible();
    await threadButton.click();
    await expect(page.getByPlaceholder('Tulis pesan...')).toBeEnabled();
}

async function waitForRealtimeConnection(page: Page): Promise<void> {
    await expect
        .poll(
            () =>
                page.evaluate(
                    () =>
                        window.Echo?.connector.pusher.connection.state ??
                        'missing',
                ),
            { timeout: 20_000 },
        )
        .toBe('connected');
}

async function waitForRealtimeSubscriptions(page: Page): Promise<void> {
    await expect
        .poll(
            () =>
                page.evaluate(() => {
                    const channels = Object.values(
                        window.Echo?.connector.pusher.channels.channels ?? {},
                    ).filter((channel) =>
                        channel.name.startsWith('private-mentorship.thread.'),
                    );

                    return channels.length > 0 && channels.every(
                        (channel) => channel.subscribed,
                    );
                }),
            { timeout: 20_000 },
        )
        .toBe(true);
}

test.describe('Realtime deployment verification', () => {
    test.setTimeout(45_000);

    test.skip(
        process.env.E2E_REALTIME_TARGET !== 'true',
        'requires a deployment with Reverb enabled',
    );

    test('delivers a chat message to an already-open recipient page without refresh', async ({
        baseURL,
        browser,
    }) => {
        const resolvedBaseUrl = baseURL ?? 'http://127.0.0.1:9010';
        const [mahasiswaState, dosenState] = await Promise.all([
            authenticate(resolvedBaseUrl, 'mahasiswa@sita.test'),
            authenticate(resolvedBaseUrl, 'dosen@sita.test'),
        ]);
        const mahasiswaContext = await browser.newContext({
            storageState: mahasiswaState,
        });
        const dosenContext = await browser.newContext({
            storageState: dosenState,
        });
        const message = `Realtime deployment verification ${Date.now()}`;

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await Promise.all([
                openMahasiswaBimbinganThread(mahasiswaPage),
                openDosenBimbinganThread(dosenPage),
            ]);
            await Promise.all([
                waitForRealtimeConnection(mahasiswaPage),
                waitForRealtimeConnection(dosenPage),
            ]);
            await Promise.all([
                waitForRealtimeSubscriptions(mahasiswaPage),
                waitForRealtimeSubscriptions(dosenPage),
            ]);

            const postedMessage = mahasiswaPage.waitForResponse(
                (response) =>
                    response.request().method() === 'POST' &&
                    /\/mahasiswa\/pesan\/\d+\/messages$/.test(response.url()),
            );

            await mahasiswaPage.getByPlaceholder('Tulis pesan...').fill(message);
            await mahasiswaPage.getByPlaceholder('Tulis pesan...').press('Enter');
            await postedMessage;

            await expect(mahasiswaPage.getByText(message).last()).toBeVisible();
            await expect(dosenPage.getByText(message).last()).toBeVisible({
                timeout: 15_000,
            });
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });
});
