import path from 'node:path';

import { expect, test, type Page } from '@playwright/test';

import {
    authStatePath,
    thesisFixtures,
    thesisScenarios,
} from '../support/thesis-fixtures';

function toDateTimeLocalString(date: Date): string {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');

    return `${year}-${month}-${day}T${hours}:${minutes}`;
}

async function uploadThesisDocument(
    page: Page,
    title: string,
    categoryLabel: 'Draft Skripsi' | 'Proposal' | 'Laporan' | 'Lampiran',
) {
    await page.goto('/mahasiswa/upload-dokumen?open=unggah');
    await expect(page).toHaveTitle(/Upload Dokumen/i);
    await expect(
        page.getByRole('dialog', { name: 'Upload Dokumen' }),
    ).toBeVisible();

    await page.getByLabel('Judul Dokumen').fill(title);
    await page.getByLabel('Kategori Dokumen').click();
    await page.getByRole('option', { name: categoryLabel }).click();
    await page
        .getByLabel('File Dokumen')
        .setInputFiles(
            path.join(process.cwd(), thesisFixtures.thesisDocumentUploadPath),
        );
    await page.getByRole('button', { name: 'Upload' }).click();

    await expect(
        page.getByText(
            'Dokumen berhasil diunggah dan notifikasi terkirim ke thread terkait.',
        ),
    ).toBeVisible();
}

async function openMahasiswaBimbinganThread(page: Page): Promise<void> {
    await page.goto('/mahasiswa/pesan');
    await expect(page).toHaveTitle(/Pesan/i);

    const bimbinganThreadButton = page
        .locator('button')
        .filter({ hasText: 'Bimbingan' })
        .first();

    await expect(bimbinganThreadButton).toBeVisible();
    await bimbinganThreadButton.click();
    await expect(page.getByPlaceholder('Tulis pesan...')).toBeEnabled();
}

async function openDosenBimbinganThread(
    page: Page,
    studentName: string,
): Promise<void> {
    await page.goto('/dosen/pesan-bimbingan');
    await expect(page).toHaveTitle(/Pesan(?: Bimbingan)? Dosen/i);
    await page.getByPlaceholder(/Cari (mahasiswa|grup)\.\.\./).fill(studentName);

    const threadButton = page
        .locator('button')
        .filter({ hasText: studentName })
        .filter({ hasText: 'Bimbingan' })
        .first();

    await expect(threadButton).toBeVisible();
    await threadButton.click();
    await expect(page.getByText(studentName).first()).toBeVisible();
}

async function sendChatMessage(
    page: Page,
    urlPattern: RegExp,
    message: string,
): Promise<void> {
    const messageInput = page.getByPlaceholder('Tulis pesan...');
    const submitRequest = page.waitForResponse(
        (response) =>
            response.request().method() === 'POST' &&
            urlPattern.test(response.url()),
    );

    await messageInput.fill(message);
    await messageInput.press('Enter');
    await submitRequest;
    await expect(page.getByText(message).last()).toBeVisible();
}

async function requestBimbinganSchedule(
    page: Page,
    {
        topic,
        requestedFor,
        studentNote,
        recurring,
    }: {
        topic: string;
        requestedFor: string;
        studentNote: string;
        recurring?: {
            pattern: 'Mingguan' | '2 Mingguan' | 'Bulanan';
            count: string;
        };
    },
): Promise<void> {
    await page.goto('/mahasiswa/jadwal-bimbingan?open=ajukan');
    await expect(page).toHaveTitle(/Jadwal Bimbingan/i);
    await expect(
        page.getByRole('dialog', { name: 'Ajukan Jadwal Bimbingan' }),
    ).toBeVisible();

    await page.getByLabel('Topik Bimbingan').fill(topic);
    await page.getByLabel('Tanggal & Waktu Preferensi').fill(requestedFor);
    await page.getByLabel('Catatan Tambahan (Opsional)').fill(studentNote);

    if (recurring !== undefined) {
        await page.getByLabel('Jadwalkan Berulang').check();
        await page.getByLabel('Pola Pengulangan').click();
        await page
            .getByRole('option', {
                name: recurring.pattern,
                exact: true,
            })
            .click();
        await page.getByLabel('Jumlah Pertemuan').click();
        await page
            .getByRole('option', {
                name: `${recurring.count} pertemuan`,
                exact: true,
            })
            .click();
    }

    await page.getByRole('button', { name: 'Kirim Permintaan' }).click();
}

test.describe('Bimbingan and chat integration', () => {
    test('mahasiswa and dosen can both see the seeded mentorship workspace for the same thesis project', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await mahasiswaPage.goto('/mahasiswa/pesan');
            await expect(mahasiswaPage).toHaveTitle(/Pesan/i);
            await expect(
                mahasiswaPage.getByText('Thread bimbingan dan sempro Anda'),
            ).toBeVisible();
            await expect(
                mahasiswaPage.getByText('Mahasiswa SiTA').first(),
            ).toBeVisible();

            await dosenPage.goto('/dosen/pesan-bimbingan');
            await expect(dosenPage).toHaveTitle(/Pesan Bimbingan Dosen/i);
            await expect(
                dosenPage
                    .getByText(thesisScenarios.activeResearch.studentName)
                    .first(),
            ).toBeVisible();
            await expect(
                dosenPage.getByPlaceholder('Tulis pesan...'),
            ).toBeEnabled();

            await dosenPage.goto('/dosen/dokumen-revisi');
            await expect(dosenPage).toHaveTitle(/Dokumen & Revisi Dosen/i);
            await expect(
                dosenPage.getByText('Draft Bab 1').first(),
            ).toBeVisible();

            await mahasiswaPage.goto('/mahasiswa/jadwal-bimbingan');
            await expect(mahasiswaPage).toHaveTitle(/Jadwal Bimbingan/i);
            await expect(
                mahasiswaPage
                    .getByText('Review Bab II dan kesiapan implementasi')
                    .first(),
            ).toBeVisible();
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('mahasiswa uploads a new thesis document and it appears in both chat and dosen review queue', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        const documentTitle = 'Draft Bab 3 Metodologi Playwright';
        const documentFileName = path.basename(
            thesisFixtures.thesisDocumentUploadPath,
        );

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await mahasiswaPage.goto('/mahasiswa/upload-dokumen?open=unggah');
            await expect(mahasiswaPage).toHaveTitle(/Upload Dokumen/i);
            await expect(
                mahasiswaPage.getByRole('dialog', { name: 'Upload Dokumen' }),
            ).toBeVisible();

            await mahasiswaPage.getByLabel('Judul Dokumen').fill(documentTitle);
            await mahasiswaPage
                .getByLabel('File Dokumen')
                .setInputFiles(
                    path.join(
                        process.cwd(),
                        thesisFixtures.thesisDocumentUploadPath,
                    ),
                );
            await mahasiswaPage.getByRole('button', { name: 'Upload' }).click();

            await expect(
                mahasiswaPage.getByText(
                    'Dokumen berhasil diunggah dan notifikasi terkirim ke thread terkait.',
                ),
            ).toBeVisible();
            await expect(
                mahasiswaPage.getByText(documentTitle).first(),
            ).toBeVisible();

            await mahasiswaPage.goto('/mahasiswa/pesan');
            await expect(mahasiswaPage).toHaveTitle(/Pesan/i);
            await expect(
                mahasiswaPage.getByText('Dokumen Baru Diunggah').first(),
            ).toBeVisible();
            await expect(
                mahasiswaPage.getByText(documentFileName).first(),
            ).toBeVisible();

            await dosenPage.goto('/dosen/dokumen-revisi');
            await expect(dosenPage).toHaveTitle(/Dokumen & Revisi Dosen/i);
            await expect(
                dosenPage
                    .getByText(thesisScenarios.activeResearch.studentName)
                    .first(),
            ).toBeVisible();
            await expect(
                dosenPage.getByText(documentTitle).first(),
            ).toBeVisible();
            await expect(
                dosenPage.getByText(documentFileName).first(),
            ).toBeVisible();
            await expect(
                dosenPage.getByText('Perlu Review').first(),
            ).toBeVisible();
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('mahasiswa requests a new bimbingan slot and dosen approves it from the lecturer workspace', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        const topic = 'Bimbingan Playwright Bab 5 Integrasi';
        const lecturerFeedback =
            'Silakan siapkan evaluasi akhir dan ringkasan hasil eksperimen.';
        const confirmedLocation = 'Ruang Bimbingan Playwright';
        const requestedFor = toDateTimeLocalString(
            new Date(Date.now() + 3 * 24 * 60 * 60 * 1000),
        );

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await mahasiswaPage.goto('/mahasiswa/jadwal-bimbingan?open=ajukan');
            await expect(mahasiswaPage).toHaveTitle(/Jadwal Bimbingan/i);
            await expect(
                mahasiswaPage.getByRole('dialog', {
                    name: 'Ajukan Jadwal Bimbingan',
                }),
            ).toBeVisible();

            await mahasiswaPage.getByLabel('Topik Bimbingan').fill(topic);
            await mahasiswaPage
                .getByLabel('Tanggal & Waktu Preferensi')
                .fill(requestedFor);
            await mahasiswaPage
                .getByLabel('Catatan Tambahan (Opsional)')
                .fill('Mohon validasi kesiapan presentasi dan bab penutup.');
            await mahasiswaPage
                .getByRole('button', { name: 'Kirim Permintaan' })
                .click();

            await expect(
                mahasiswaPage.getByText(
                    'Permintaan jadwal bimbingan berhasil dikirim.',
                ),
            ).toBeVisible();

            const mahasiswaPendingRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: topic })
                .first();
            await expect(mahasiswaPendingRow).toBeVisible();
            await expect(mahasiswaPendingRow).toContainText(
                'Menunggu Konfirmasi',
            );

            await dosenPage.goto('/dosen/jadwal-bimbingan');
            await expect(dosenPage).toHaveTitle(/Jadwal Bimbingan Dosen/i);

            const requestCard = dosenPage
                .locator('div.rounded-xl.border.bg-card.p-5.shadow-sm')
                .filter({ hasText: topic })
                .first();

            await expect(requestCard).toBeVisible();
            await requestCard
                .locator('textarea[id^="note-"]')
                .fill(lecturerFeedback);
            await requestCard
                .locator('input[id^="location-"]')
                .fill(confirmedLocation);
            await requestCard
                .getByRole('button', { name: 'Konfirmasi' })
                .click();

            await expect(
                dosenPage.getByText('Keputusan jadwal berhasil disimpan.'),
            ).toBeVisible();
            await expect(requestCard).toHaveCount(0);

            const dosenUpcomingRow = dosenPage
                .locator('tr')
                .filter({ hasText: topic })
                .first();
            await expect(dosenUpcomingRow).toBeVisible();
            await expect(dosenUpcomingRow).toContainText(
                thesisScenarios.activeResearch.studentName,
            );

            await mahasiswaPage.goto('/mahasiswa/jadwal-bimbingan');
            await expect(mahasiswaPage).toHaveTitle(/Jadwal Bimbingan/i);

            const mahasiswaApprovedRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: topic })
                .first();
            await expect(mahasiswaApprovedRow).toBeVisible();
            await expect(mahasiswaApprovedRow).toContainText('Terjadwal');
            await expect(mahasiswaApprovedRow).toContainText(confirmedLocation);
            await expect(mahasiswaApprovedRow).toContainText(lecturerFeedback);
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('dosen requests revision for an uploaded document and later approves the revised version', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        const initialTitle = 'Draft Bab 4 Evaluasi Playwright';
        const revisedTitle = 'Draft Bab 4 Evaluasi Playwright Revisi';
        const revisionNotes =
            'Perjelas interpretasi hasil uji dan tambahkan ringkasan temuan utama.';

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await uploadThesisDocument(
                mahasiswaPage,
                initialTitle,
                'Draft Skripsi',
            );

            await dosenPage.goto('/dosen/dokumen-revisi');
            await expect(dosenPage).toHaveTitle(/Dokumen & Revisi Dosen/i);
            await dosenPage
                .getByPlaceholder('Cari mahasiswa atau file...')
                .fill(initialTitle);

            const initialReviewRow = dosenPage
                .locator('tr')
                .filter({ hasText: thesisScenarios.activeResearch.studentName })
                .filter({ hasText: initialTitle })
                .first();

            await expect(initialReviewRow).toBeVisible();
            await expect(initialReviewRow).toContainText('Perlu Review');
            await initialReviewRow.locator('button').nth(1).click();

            const revisionDialog = dosenPage.getByRole('dialog', {
                name: 'Kirim Catatan Revisi',
            });

            await expect(revisionDialog).toBeVisible();
            await revisionDialog
                .getByRole('textbox', { name: 'Catatan Revisi' })
                .fill(revisionNotes);
            await dosenPage
                .getByRole('button', { name: 'Kirim Catatan' })
                .click();

            await expect(
                dosenPage.getByText('Status dokumen berhasil diperbarui.'),
            ).toBeVisible();
            await expect(initialReviewRow).toContainText('Perlu Revisi');
            await expect(initialReviewRow).toContainText(revisionNotes);

            await mahasiswaPage.goto('/mahasiswa/upload-dokumen');
            await expect(mahasiswaPage).toHaveTitle(/Upload Dokumen/i);
            await mahasiswaPage
                .getByPlaceholder('Cari judul atau file...')
                .fill(initialTitle);

            const initialStudentRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: initialTitle })
                .first();

            await expect(initialStudentRow).toBeVisible();
            await expect(initialStudentRow).toContainText('Perlu Revisi');
            await expect(initialStudentRow).toContainText(revisionNotes);

            await uploadThesisDocument(
                mahasiswaPage,
                revisedTitle,
                'Draft Skripsi',
            );

            await mahasiswaPage
                .getByPlaceholder('Cari judul atau file...')
                .fill(revisedTitle);

            const revisedStudentPendingRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: revisedTitle })
                .first();

            await expect(revisedStudentPendingRow).toBeVisible();
            await expect(revisedStudentPendingRow).toContainText(
                'Menunggu Review',
            );

            await dosenPage.goto('/dosen/dokumen-revisi');
            await expect(dosenPage).toHaveTitle(/Dokumen & Revisi Dosen/i);
            await dosenPage
                .getByPlaceholder('Cari mahasiswa atau file...')
                .fill(revisedTitle);

            const revisedReviewRow = dosenPage
                .locator('tr')
                .filter({ hasText: thesisScenarios.activeResearch.studentName })
                .filter({ hasText: revisedTitle })
                .first();

            await expect(revisedReviewRow).toBeVisible();
            await expect(revisedReviewRow).toContainText('Perlu Review');
            await revisedReviewRow.locator('button').nth(2).click();

            await expect(
                dosenPage.getByText('Status dokumen berhasil diperbarui.'),
            ).toBeVisible();
            await expect(revisedReviewRow).toContainText('Disetujui');

            await mahasiswaPage.goto('/mahasiswa/upload-dokumen');
            await expect(mahasiswaPage).toHaveTitle(/Upload Dokumen/i);
            await mahasiswaPage
                .getByPlaceholder('Cari judul atau file...')
                .fill(revisedTitle);

            const revisedStudentApprovedRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: revisedTitle })
                .first();

            await expect(revisedStudentApprovedRow).toBeVisible();
            await expect(revisedStudentApprovedRow).toContainText('Disetujui');
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('mahasiswa and dosen can exchange new chat messages from the shared bimbingan thread', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        const mahasiswaMessage = `Playwright mahasiswa message ${Date.now()}`;
        const dosenMessage = `Playwright dosen reply ${Date.now()}`;

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await openMahasiswaBimbinganThread(mahasiswaPage);
            await openDosenBimbinganThread(
                dosenPage,
                thesisScenarios.activeResearch.studentName,
            );

            await sendChatMessage(
                mahasiswaPage,
                /\/mahasiswa\/pesan\/\d+\/messages$/,
                mahasiswaMessage,
            );

            await expect(
                dosenPage.getByText(mahasiswaMessage).last(),
            ).toBeVisible({ timeout: 15_000 });

            await sendChatMessage(
                dosenPage,
                /\/dosen\/pesan-bimbingan\/\d+\/messages$/,
                dosenMessage,
            );

            await expect(
                mahasiswaPage.getByText(dosenMessage).last(),
            ).toBeVisible({ timeout: 15_000 });
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('dosen can reject a bimbingan request and mahasiswa sees it in history with feedback', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        const topic = `Bimbingan ditolak Playwright ${Date.now()}`;
        const rejectionNote =
            'Topik perlu dipersempit dulu sebelum sesi bimbingan dijadwalkan.';
        const requestedFor = toDateTimeLocalString(
            new Date(Date.now() + 4 * 24 * 60 * 60 * 1000),
        );

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await requestBimbinganSchedule(mahasiswaPage, {
                topic,
                requestedFor,
                studentNote:
                    'Mohon masukan terkait fokus pembahasan bab evaluasi.',
            });
            await expect(
                mahasiswaPage.getByText(
                    'Permintaan jadwal bimbingan berhasil dikirim.',
                ),
            ).toBeVisible();

            const mahasiswaPendingRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: topic })
                .first();
            await expect(mahasiswaPendingRow).toBeVisible();
            await expect(mahasiswaPendingRow).toContainText(
                'Menunggu Konfirmasi',
            );

            await dosenPage.goto('/dosen/jadwal-bimbingan');
            await expect(dosenPage).toHaveTitle(/Jadwal Bimbingan Dosen/i);

            const requestCard = dosenPage
                .locator('div.rounded-xl.border.bg-card.p-5.shadow-sm')
                .filter({ hasText: topic })
                .first();
            await expect(requestCard).toBeVisible();
            await requestCard
                .locator('textarea[id^="note-"]')
                .fill(rejectionNote);
            await requestCard.getByRole('button', { name: 'Tolak' }).click();

            await expect(
                dosenPage.getByText('Keputusan jadwal berhasil disimpan.'),
            ).toBeVisible();
            await expect(requestCard).toHaveCount(0);

            await mahasiswaPage.goto('/mahasiswa/jadwal-bimbingan');
            await expect(mahasiswaPage).toHaveTitle(/Jadwal Bimbingan/i);

            const mahasiswaHistoryRow = mahasiswaPage
                .locator('tr')
                .filter({ hasText: topic })
                .first();
            await expect(mahasiswaHistoryRow).toBeVisible();
            await expect(mahasiswaHistoryRow).toContainText('Ditolak');
            await expect(mahasiswaHistoryRow).toContainText(rejectionNote);
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('dosen can approve a recurring bimbingan request group and mahasiswa sees all sessions scheduled', async ({
        browser,
    }) => {
        const mahasiswaContext = await browser.newContext({
            storageState: authStatePath(
                thesisScenarios.activeResearch.studentKey,
            ),
        });
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        const topic = `Bimbingan berulang Playwright ${Date.now()}`;
        const lecturerNote =
            'Semua sesi berulang disetujui untuk monitoring progres bab akhir.';
        const location = 'Ruang Bimbingan Reguler Playwright';
        const requestedFor = toDateTimeLocalString(
            new Date(Date.now() + 5 * 24 * 60 * 60 * 1000),
        );

        try {
            const mahasiswaPage = await mahasiswaContext.newPage();
            const dosenPage = await dosenContext.newPage();

            await requestBimbinganSchedule(mahasiswaPage, {
                topic,
                requestedFor,
                studentNote:
                    'Mohon persetujuan untuk seri bimbingan mingguan menjelang finalisasi.',
                recurring: {
                    pattern: 'Mingguan',
                    count: '3',
                },
            });
            await expect(
                mahasiswaPage.getByText(
                    '3 permintaan jadwal bimbingan berulang berhasil dikirim.',
                ),
            ).toBeVisible();

            await dosenPage.goto('/dosen/jadwal-bimbingan');
            await expect(dosenPage).toHaveTitle(/Jadwal Bimbingan Dosen/i);

            const recurringCard = dosenPage
                .locator('div.rounded-xl.border.bg-card.p-5.shadow-sm')
                .filter({ hasText: topic })
                .first();
            await expect(recurringCard).toBeVisible();
            await expect(recurringCard).toContainText('3 Pertemuan');
            await recurringCard
                .locator('input[id^="recurring-location-"]')
                .fill(location);
            await recurringCard
                .locator('textarea[id^="recurring-note-"]')
                .fill(lecturerNote);
            await recurringCard
                .getByRole('button', { name: 'Konfirmasi Semua' })
                .click();

            await expect(
                dosenPage.getByText('3 jadwal berhasil dikonfirmasi.'),
            ).toBeVisible();
            await expect(recurringCard).toHaveCount(0);

            await mahasiswaPage.goto('/mahasiswa/jadwal-bimbingan');
            await expect(mahasiswaPage).toHaveTitle(/Jadwal Bimbingan/i);

            const scheduledRows = mahasiswaPage
                .locator('tr')
                .filter({ hasText: topic });

            await expect(scheduledRows).toHaveCount(3);
            await expect(scheduledRows.first()).toContainText('Terjadwal');
            await expect(scheduledRows.first()).toContainText(location);
            await expect(scheduledRows.first()).toContainText(lecturerNote);
        } finally {
            await mahasiswaContext.close();
            await dosenContext.close();
        }
    });

    test('dosen can manage mahasiswa-bimbingan workspace and open chat from an active student row', async ({
        browser,
    }) => {
        const dosenContext = await browser.newContext({
            storageState: authStatePath('dosen1'),
        });

        try {
            const dosenPage = await dosenContext.newPage();

            await dosenPage.goto('/dosen/mahasiswa-bimbingan');
            await expect(dosenPage).toHaveTitle(/Mahasiswa Bimbingan/i);

            const activeSection = dosenPage
                .locator('section')
                .filter({ hasText: 'Mahasiswa Aktif' })
                .first();
            const historySection = dosenPage
                .locator('section')
                .filter({ hasText: 'Riwayat Bimbingan' })
                .first();

            await expect(activeSection).toBeVisible();
            await expect(activeSection).toContainText(
                thesisScenarios.activeResearch.studentName,
            );
            await expect(activeSection).toContainText('Pembimbing 1');

            await activeSection
                .getByPlaceholder('Cari nama atau NIM...')
                .fill(thesisScenarios.activeResearch.studentName);
            await activeSection
                .getByRole('button', { name: 'Pembimbing 1' })
                .click();

            const activeStudentRow = activeSection
                .locator('tr')
                .filter({
                    hasText: thesisScenarios.activeResearch.studentName,
                })
                .first();

            await expect(activeStudentRow).toBeVisible();

            await activeStudentRow.getByRole('link', { name: 'Chat' }).click();
            await expect(dosenPage).toHaveURL(
                /\/dosen\/pesan-bimbingan\?thread=/,
            );
            await expect(dosenPage).toHaveTitle(/Pesan Bimbingan Dosen/i);
            await expect(
                dosenPage
                    .getByText(thesisScenarios.activeResearch.studentName)
                    .first(),
            ).toBeVisible();
            await expect(
                dosenPage.getByPlaceholder('Tulis pesan...'),
            ).toBeEnabled();

            await dosenPage.goto('/dosen/mahasiswa-bimbingan');
            await expect(dosenPage).toHaveTitle(/Mahasiswa Bimbingan/i);
            await expect(historySection).toBeVisible();
            await expect(
                historySection.getByRole('link', { name: 'Chat' }),
            ).toHaveCount(0);
        } finally {
            await dosenContext.close();
        }
    });
});
