#!/usr/bin/php -q
<?php
/* borg-assets.php - list the downloadable borg binaries for a release, best
 * candidate first.
 *
 *   borg-assets.php <version> [local-glibc]     e.g. 1.4.1 2.37
 *
 * Prints "name<TAB>url" lines. Exits 1 if the release cannot be read.
 *
 * Upstream asset names are not stable across releases - 1.2.x shipped
 * borg-linux64 / borg-linuxnew64, 1.4.0-1.4.1 borg-linux-glibc236, and 1.4.5
 * borg-linux-glibc231-x86_64 - so the names are read from the GitHub release
 * rather than guessed. A binary built against a newer glibc than the running
 * system downloads happily and then refuses to execute, which is why the
 * ordering matters: highest glibc the box can actually run, first.
 */

$version = $argv[1] ?? '';
$local   = (float)($argv[2] ?? 0);

if ($version === '') {
    fwrite(STDERR, "usage: borg-assets.php <version> [local-glibc]\n");
    exit(2);
}

$api  = "https://api.github.com/repos/borgbackup/borg/releases/tags/".rawurlencode($version);
$ctx  = stream_context_create(['http' => [
    'timeout' => 30,
    // GitHub rejects requests without one.
    'header'  => "User-Agent: unraid-borgbackup-plugin\r\nAccept: application/vnd.github+json\r\n",
]]);

$raw = @file_get_contents($api, false, $ctx);
if ($raw === false) {
    fwrite(STDERR, "Could not reach the GitHub API for release '$version'\n");
    exit(1);
}
$rel = json_decode($raw, true);
if (!is_array($rel) || empty($rel['assets'])) {
    fwrite(STDERR, "Release '$version' has no downloadable assets\n");
    exit(1);
}

$cands = [];
foreach ($rel['assets'] as $a) {
    $name = $a['name'] ?? '';
    $url  = $a['browser_download_url'] ?? '';
    if ($name === '' || $url === '') continue;

    // Linux x86_64 executables only: no archives, signatures, source, or
    // builds for other platforms and architectures.
    if (!str_contains($name, 'linux'))                    continue;
    if (preg_match('/\.(tgz|tar\.gz|asc|sha256)$/', $name)) continue;
    if (preg_match('/arm64|aarch64|freebsd|macos/i', $name)) continue;

    // glibc236 -> 2.36. Assets with no marker (borg-linux64) are last-resort.
    $glibc = preg_match('/glibc(\d)(\d+)/', $name, $m)
           ? (float)($m[1].'.'.$m[2]) : 0.0;

    if ($local > 0 && $glibc > 0 && $glibc > $local) continue;   // cannot run here

    $cands[] = ['name' => $name, 'url' => $url, 'glibc' => $glibc];
}

if (!$cands) {
    fwrite(STDERR, "No Linux x86_64 build in release '$version'".
                   ($local > 0 ? " that runs on glibc $local" : '')."\n");
    exit(1);
}

// Highest usable glibc first: newer builds are the ones upstream tests most.
// Unmarked assets sort last, as a fallback rather than a first choice.
usort($cands, fn($a, $b) => $b['glibc'] <=> $a['glibc']);

foreach ($cands as $c) echo $c['name']."\t".$c['url']."\n";
exit(0);
