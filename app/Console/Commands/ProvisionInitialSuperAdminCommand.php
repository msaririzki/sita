<?php

namespace App\Console\Commands;

use App\Enums\AppRole;
use App\Models\Role;
use App\Models\User;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\Rules\Password;

class ProvisionInitialSuperAdminCommand extends Command
{
    protected $signature = 'sita:provision-initial-super-admin';

    protected $description = 'Create the first SiTA super admin on an empty database';

    public function handle(): int
    {
        if (User::query()->exists()) {
            $this->info('Akun SiTA sudah tersedia; pembuatan Super Admin awal dilewati.');

            return self::SUCCESS;
        }

        if (! $this->input->isInteractive()) {
            $this->error('Database belum memiliki akun. Jalankan dari terminal interaktif untuk membuat Super Admin awal.');

            return self::FAILURE;
        }

        $this->line('Database baru terdeteksi. Isi akun Super Admin pertama untuk melanjutkan.');
        $this->line('Password tidak ditampilkan, tidak disimpan di profile, dan tidak ditulis ke log.');

        while (true) {
            $name = trim((string) $this->ask('Nama lengkap Super Admin'));
            $email = trim((string) $this->ask('Email Super Admin'));
            $password = (string) $this->secret('Password Super Admin');
            $passwordConfirmation = (string) $this->secret('Ulangi password Super Admin');

            $validator = Validator::make([
                'name' => $name,
                'email' => $email,
                'password' => $password,
                'password_confirmation' => $passwordConfirmation,
            ], [
                'name' => ['required', 'string', 'max:255'],
                'email' => ['required', 'string', 'email', 'max:255', 'unique:users,email'],
                'password' => [
                    'required',
                    'string',
                    'confirmed',
                    Password::min(12)
                        ->mixedCase()
                        ->letters()
                        ->numbers()
                        ->symbols(),
                ],
            ]);

            if ($validator->fails()) {
                foreach ($validator->errors()->all() as $error) {
                    $this->error($error);
                }

                $this->newLine();

                continue;
            }

            DB::transaction(function () use ($name, $email, $password): void {
                $role = Role::query()->firstOrCreate([
                    'name' => AppRole::SuperAdmin->value,
                ]);

                $user = User::query()->create([
                    'name' => $name,
                    'email' => $email,
                    'password' => $password,
                    'last_active_role' => AppRole::SuperAdmin->value,
                ]);

                $user->roles()->syncWithoutDetaching([$role->id]);
            });

            $this->info(sprintf('Super Admin awal berhasil dibuat untuk %s.', $email));
            $this->line('Masuk melalui /admin untuk membuat akun operator, dosen, dan mahasiswa.');

            return self::SUCCESS;
        }
    }
}
