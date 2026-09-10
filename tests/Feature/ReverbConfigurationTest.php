<?php

it('uses the configured Reverb origins instead of a fixed wildcard', function () {
    $key = 'REVERB_ALLOWED_ORIGINS';
    $previous = getenv($key);

    putenv("{$key}=sita.example.test,admin.example.test");

    try {
        $reverb = require base_path('config/reverb.php');

        expect($reverb['apps']['apps'][0]['allowed_origins'])
            ->toBe(['sita.example.test', 'admin.example.test']);
    } finally {
        if ($previous === false) {
            putenv($key);
        } else {
            putenv("{$key}={$previous}");
        }
    }
});
