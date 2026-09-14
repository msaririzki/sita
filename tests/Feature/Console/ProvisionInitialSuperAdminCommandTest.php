<?php

use App\Enums\AppRole;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;

uses(RefreshDatabase::class);

it('creates the initial super admin from an interactive terminal', function () {
    $this->artisan('sita:provision-initial-super-admin')
        ->expectsQuestion('Nama lengkap Super Admin', 'Operator SiTA')
        ->expectsQuestion('Email Super Admin', 'operator@sita.test')
        ->expectsQuestion('Password Super Admin', 'Passphrase!123')
        ->expectsQuestion('Ulangi password Super Admin', 'Passphrase!123')
        ->expectsOutput('Super Admin awal berhasil dibuat untuk operator@sita.test.')
        ->assertExitCode(0);

    $user = User::query()->where('email', 'operator@sita.test')->firstOrFail();

    expect($user->name)->toBe('Operator SiTA')
        ->and($user->last_active_role)->toBe(AppRole::SuperAdmin->value)
        ->and($user->hasRole(AppRole::SuperAdmin))->toBeTrue()
        ->and(Hash::check('Passphrase!123', $user->password))->toBeTrue();
});

it('does not create another initial account when an account already exists', function () {
    User::factory()->create();

    $this->artisan('sita:provision-initial-super-admin')
        ->expectsOutput('Akun SiTA sudah tersedia; pembuatan Super Admin awal dilewati.')
        ->assertExitCode(0);

    expect(User::query()->count())->toBe(1);
});

it('refuses non-interactive provisioning on an empty database', function () {
    $this->artisan('sita:provision-initial-super-admin --no-interaction')
        ->expectsOutput('Database belum memiliki akun. Jalankan dari terminal interaktif untuk membuat Super Admin awal.')
        ->assertExitCode(1);

    expect(User::query()->count())->toBe(0);
});
