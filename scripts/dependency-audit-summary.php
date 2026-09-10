<?php

declare(strict_types=1);

/**
 * Summarises Composer and npm audit JSON without a Laravel bootstrap.
 *
 * The input files must come from production-scoped audit commands:
 * - composer audit --locked --no-dev --format=json
 * - npm audit --omit=dev --json
 */

const SEVERITY_RANKS = [
    'unknown' => 0,
    'low' => 1,
    'moderate' => 2,
    'high' => 3,
    'critical' => 4,
];

function usage(): never
{
    fwrite(STDERR, "Usage: php scripts/dependency-audit-summary.php --composer-report=PATH --npm-report=PATH --output=PATH [--mode=report|enforce] [--threshold=low|moderate|high|critical]\n");
    exit(2);
}

function readJson(string $path): array
{
    if (! is_file($path)) {
        throw new RuntimeException("Audit report tidak ditemukan: {$path}");
    }

    $contents = file_get_contents($path);
    if ($contents === false || trim($contents) === '') {
        throw new RuntimeException("Audit report kosong: {$path}");
    }

    try {
        $data = json_decode($contents, true, flags: JSON_THROW_ON_ERROR);
    } catch (JsonException $exception) {
        throw new RuntimeException("Audit report bukan JSON valid: {$path}", previous: $exception);
    }

    if (! is_array($data)) {
        throw new RuntimeException("Audit report harus berupa objek JSON: {$path}");
    }

    return $data;
}

function severity(string|null $value): string
{
    $normalized = strtolower((string) $value);

    return array_key_exists($normalized, SEVERITY_RANKS) ? $normalized : 'unknown';
}

function emptySeverityCounts(): array
{
    return array_fill_keys(array_keys(SEVERITY_RANKS), 0);
}

function composerSummary(array $report): array
{
    $counts = emptySeverityCounts();
    $affectedPackages = 0;
    $advisoryCount = 0;

    foreach (($report['advisories'] ?? []) as $advisories) {
        if (! is_array($advisories) || $advisories === []) {
            continue;
        }

        $affectedPackages++;

        foreach ($advisories as $advisory) {
            if (! is_array($advisory)) {
                continue;
            }

            $counts[severity($advisory['severity'] ?? null)]++;
            $advisoryCount++;
        }
    }

    return [
        'affected_packages' => $affectedPackages,
        'advisories' => $advisoryCount,
        'severity' => $counts,
    ];
}

function npmSummary(array $report): array
{
    $counts = emptySeverityCounts();
    $affectedPackages = 0;

    foreach (($report['vulnerabilities'] ?? []) as $vulnerability) {
        if (! is_array($vulnerability)) {
            continue;
        }

        $counts[severity($vulnerability['severity'] ?? null)]++;
        $affectedPackages++;
    }

    return [
        'affected_packages' => $affectedPackages,
        'advisories' => array_sum($counts),
        'severity' => $counts,
    ];
}

function countAtOrAbove(array $summary, string $threshold): int
{
    $thresholdRank = SEVERITY_RANKS[$threshold];
    $total = 0;

    foreach ($summary['severity'] as $level => $count) {
        if (SEVERITY_RANKS[$level] >= $thresholdRank) {
            $total += $count;
        }
    }

    return $total;
}

$options = getopt('', ['composer-report:', 'npm-report:', 'output:', 'mode::', 'threshold::']);
if (! isset($options['composer-report'], $options['npm-report'], $options['output'])) {
    usage();
}

$mode = $options['mode'] ?? 'report';
$threshold = $options['threshold'] ?? 'high';
if (! in_array($mode, ['report', 'enforce'], true) || ! array_key_exists($threshold, SEVERITY_RANKS) || $threshold === 'unknown') {
    usage();
}

try {
    $composer = composerSummary(readJson($options['composer-report']));
    $npm = npmSummary(readJson($options['npm-report']));
} catch (RuntimeException $exception) {
    fwrite(STDERR, "FAIL  {$exception->getMessage()}\n");
    exit(2);
}

$blockingAdvisories = countAtOrAbove($composer, $threshold) + countAtOrAbove($npm, $threshold);
$status = $blockingAdvisories === 0 ? 'pass' : ($mode === 'enforce' ? 'fail' : 'report');
$summary = [
    'schema_version' => 1,
    'generated_at' => gmdate('c'),
    'scope' => 'production-dependencies',
    'policy' => [
        'mode' => $mode,
        'threshold' => $threshold,
    ],
    'composer' => $composer,
    'npm' => $npm,
    'blocking_advisories' => $blockingAdvisories,
    'status' => $status,
];

$encoded = json_encode($summary, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
if (file_put_contents($options['output'], $encoded) === false) {
    fwrite(STDERR, "FAIL  Ringkasan audit tidak dapat ditulis: {$options['output']}\n");
    exit(2);
}

printf("Dependency audit production: Composer %d advisory/%d paket, npm %d advisory/%d paket.\n", $composer['advisories'], $composer['affected_packages'], $npm['advisories'], $npm['affected_packages']);
printf("Ambang %s: %d advisory. Mode=%s, hasil=%s.\n", $threshold, $blockingAdvisories, $mode, $status);
printf("Ringkasan: %s\n", $options['output']);

exit($status === 'fail' ? 1 : 0);
