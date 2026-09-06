<?php
/* BorgLib.php - shared helpers for the Unraid Borg Backup plugin.
 *
 * Everything that must survive a reboot lives on the flash drive under
 * BORG_BOOT. Note the flash is vfat: file modes there are cosmetic, which is
 * why the passphrase can optionally be kept on the array instead.
 */

define('BORG_PLUGIN', 'borgbackup');
define('BORG_BOOT',   '/boot/config/plugins/'.BORG_PLUGIN);
define('BORG_CFG',    BORG_BOOT.'/'.BORG_PLUGIN.'.cfg');
define('BORG_JSON',   BORG_BOOT.'/containers.json');
define('BORG_PASSFILE', BORG_BOOT.'/passphrase');
define('BORG_EXCLUDES', BORG_BOOT.'/excludes.txt');
define('BORG_DEFAULTS', '/usr/local/emhttp/plugins/'.BORG_PLUGIN.'/default.cfg');
define('BORG_LOG',    '/var/log/'.BORG_PLUGIN.'.log');
define('BORG_INSTALL_LOG',  '/var/log/'.BORG_PLUGIN.'-install.log');
// Written by borg-install.sh's exit trap, followed by its exit code.
define('BORG_INSTALL_DONE', '__BORG_INSTALL_DONE__');
define('BORG_STATE',  '/var/local/emhttp/'.BORG_PLUGIN.'.state');

/* ---------------------------------------------------------------- config -- */

/** Parse a key="value" style Unraid cfg file. */
function borg_parse_cfg($file) {
    if (!is_file($file)) return [];
    $out = @parse_ini_file($file, false, INI_SCANNER_RAW);
    return is_array($out) ? $out : [];
}

/** Settings with defaults applied. Multi-line and secret values live in
 *  their own files and are never part of this array. */
function borg_settings() {
    $cfg = array_merge(borg_parse_cfg(BORG_DEFAULTS), borg_parse_cfg(BORG_CFG));
    unset($cfg['PASSPHRASE'], $cfg['EXCLUDES']);
    return $cfg;
}

/**
 * The cfg file is `source`d by the backup and cron shell scripts, so a value
 * containing $, ` or \ would be expanded as code on the next run. Settings are
 * therefore single-line scalars with those characters removed - anything that
 * genuinely needs them (exclude patterns, the passphrase) has its own file.
 */
function borg_sanitize_value($v) {
    return preg_replace('/[\r\n"`$\\\\]/', '', (string)$v);
}

function borg_save_settings($vals) {
    @mkdir(BORG_BOOT, 0777, true);
    $lines = [];
    foreach ($vals as $k => $v) {
        if ($k === 'PASSPHRASE' || $k === 'EXCLUDES') continue;   // stored separately
        $k = preg_replace('/[^A-Z0-9_]/', '', strtoupper($k));
        if ($k === '') continue;
        $lines[] = $k.'="'.borg_sanitize_value($v).'"';
    }
    sort($lines);
    return borg_atomic_write(BORG_CFG, implode("\n", $lines)."\n");
}

/* -------------------------------------------------------------- excludes -- */

/* Kept out of the cfg because it is multi-line and full of shell metacharacters.
 * Patterns reach borg as argv from the plan file, never via the shell. */

function borg_excludes() {
    return is_file(BORG_EXCLUDES) ? (string)@file_get_contents(BORG_EXCLUDES) : '';
}

function borg_save_excludes($text) {
    $text = str_replace("\r\n", "\n", (string)$text);
    return borg_atomic_write(BORG_EXCLUDES, rtrim($text, "\n")."\n");
}

/** Write via temp file + rename so a crash can't leave a half-written config. */
function borg_atomic_write($path, $data, $mode = 0644) {
    @mkdir(dirname($path), 0777, true);
    $tmp = $path.'.tmp';
    if (@file_put_contents($tmp, $data) === false) return false;
    @chmod($tmp, $mode);
    return @rename($tmp, $path);
}

/* ------------------------------------------------------------ passphrase -- */

/* An empty passphrase is legitimate (an unencrypted repo), so "is it set" is
 * tracked by the file existing, not by the string being non-empty. */

function borg_passphrase_is_set() {
    $s = borg_settings();
    if (($s['PASSPHRASE_MODE'] ?? 'stored') === 'file')
        return $s['PASSPHRASE_FILE'] !== '' && is_file($s['PASSPHRASE_FILE']);
    return is_file(BORG_PASSFILE);
}

function borg_save_passphrase($pass) {
    $ok = borg_atomic_write(BORG_PASSFILE, $pass, 0600);
    @chmod(BORG_PASSFILE, 0600);
    return $ok;
}

function borg_clear_passphrase() {
    return !is_file(BORG_PASSFILE) || @unlink(BORG_PASSFILE);
}

/* ------------------------------------------------------- container config -- */

/** Per-container selections: which containers, which of their mounts. */
function borg_container_config() {
    $raw = is_file(BORG_JSON) ? @file_get_contents(BORG_JSON) : '';
    $cfg = json_decode($raw ?: '{}', true);
    if (!is_array($cfg)) $cfg = [];
    $cfg['containers'] = isset($cfg['containers']) && is_array($cfg['containers'])
                       ? $cfg['containers'] : [];
    return $cfg;
}

function borg_save_container_config($cfg) {
    return borg_atomic_write(BORG_JSON,
        json_encode($cfg, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
}

/* ------------------------------------------------------------ docker info -- */

/** True when the Docker service is up; docker commands hang badly when it isn't. */
function borg_docker_running() {
    return is_file('/var/run/dockerd.pid') && file_exists('/var/run/docker.sock');
}

/**
 * All containers with their bind mounts.
 *
 * Returns: [ name => ['name','state','image','mounts'=>[ ['src','dst','rw'] ]] ]
 * Only bind mounts are listed - named docker volumes have no meaningful host
 * path to hand to borg.
 */
function borg_list_containers() {
    if (!borg_docker_running()) return [];

    $fmt = '{{json .}}';
    $json = shell_exec('docker inspect --format '.escapeshellarg($fmt).
                       ' $(docker ps -aq) 2>/dev/null');
    if (!$json) return [];

    $out = [];
    foreach (preg_split('/\r?\n/', trim($json)) as $line) {
        if ($line === '') continue;
        $c = json_decode($line, true);
        if (!is_array($c)) continue;

        $name   = ltrim($c['Name'] ?? '', '/');
        if ($name === '') continue;
        $mounts = [];
        foreach (($c['Mounts'] ?? []) as $m) {
            if (($m['Type'] ?? '') !== 'bind') continue;
            $src = $m['Source'] ?? '';
            if ($src === '' || borg_is_noise_mount($src)) continue;
            $mounts[] = [
                'src' => $src,
                'dst' => $m['Destination'] ?? '',
                'rw'  => (bool)($m['RW'] ?? true),
            ];
        }
        usort($mounts, fn($a, $b) => strcmp($a['src'], $b['src']));

        $out[$name] = [
            'name'   => $name,
            'state'  => $c['State']['Status'] ?? 'unknown',
            'image'  => $c['Config']['Image'] ?? '',
            'mounts' => $mounts,
        ];
    }
    ksort($out, SORT_NATURAL|SORT_FLAG_CASE);
    return $out;
}

/** Host paths that are never worth archiving (sockets, device passthrough, ...). */
function borg_is_noise_mount($src) {
    static $skip = ['/var/run/', '/run/', '/dev/', '/sys/', '/proc/',
                    '/etc/localtime', '/etc/timezone', '/etc/hosts',
                    '/etc/resolv.conf', '/etc/hostname'];
    foreach ($skip as $p) {
        if ($p[strlen($p)-1] === '/' ? str_starts_with($src, $p) : $src === $p)
            return true;
    }
    return false;
}

/* ----------------------------------------------------------------- status -- */

function borg_binary() {
    foreach (['/usr/local/bin/borg', BORG_BOOT.'/borg'] as $p)
        if (is_file($p) && is_executable($p)) return $p;
    return '';
}

function borg_version() {
    $bin = borg_binary();
    if (!$bin) return '';
    return trim(shell_exec(escapeshellarg($bin).' --version 2>/dev/null') ?: '');
}

function borg_is_running() {
    return trim(shell_exec("pgrep -f '/borg-backup\\.sh' 2>/dev/null") ?: '') !== '';
}

function borg_install_running() {
    return trim(shell_exec("pgrep -f '/borg-install\\.sh' 2>/dev/null") ?: '') !== '';
}

/** Last-run summary written by borg-backup.sh. */
function borg_state() {
    $s = is_file(BORG_STATE) ? borg_parse_cfg(BORG_STATE) : [];
    return array_merge(['LAST_RUN'=>'', 'LAST_RESULT'=>'', 'LAST_DURATION'=>'',
                        'LAST_ARCHIVES'=>'', 'LAST_ERROR'=>''], $s);
}

/* ------------------------------------------------------------------- misc -- */

function borg_h($s) { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }

/** Human-readable summary of the cron schedule, for the settings page. */
function borg_schedule_text($s) {
    $t = sprintf('%02d:%02d', (int)($s['HOUR'] ?? 3), (int)($s['MINUTE'] ?? 0));
    switch ($s['SCHEDULE'] ?? 'daily') {
        case 'disabled': return 'Disabled - manual runs only';
        case 'hourly':   return 'Every hour at :'.sprintf('%02d', (int)($s['MINUTE'] ?? 0));
        case 'daily':    return 'Every day at '.$t;
        case 'weekly':
            $d = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
            return 'Every '.($d[(int)($s['WEEKDAY'] ?? 0)] ?? 'Sunday').' at '.$t;
        case 'monthly':  return 'Day '.(int)($s['MONTHDAY'] ?? 1).' of each month at '.$t;
        case 'custom':   return 'Custom cron: '.($s['CRON'] ?? '');
    }
    return '';
}

/* --------------------------------------------------------------- running -- */

/** Passphrase text, or null when none is configured. Never send this to a browser. */
function borg_read_passphrase() {
    $s = borg_settings();
    $f = ($s['PASSPHRASE_MODE'] ?? 'stored') === 'file'
       ? ($s['PASSPHRASE_FILE'] ?? '') : BORG_PASSFILE;
    if ($f === '' || !is_readable($f)) return null;
    // A trailing newline is nearly always an editing artefact, not the secret.
    return preg_replace('/\n$/', '', (string)file_get_contents($f));
}

/**
 * Environment for a borg invocation. The passphrase goes here rather than on
 * the command line so it never shows up in `ps` output.
 */
function borg_env() {
    $s   = borg_settings();
    $env = [
        'PATH' => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME' => '/root',
        'BORG_REPO' => $s['REPO'] ?? '',
        'BORG_RELOCATED_REPO_ACCESS_IS_OK' => 'no',
        'BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK' => 'no',
        'BORG_HOST_ID_NOT_UNIQUE_IS_OK' => 'yes',
    ];
    $pass = borg_read_passphrase();
    if ($pass !== null) $env['BORG_PASSPHRASE'] = $pass;
    if (!empty($s['SSH_KEY']))
        $env['BORG_RSH'] = 'ssh -i '.$s['SSH_KEY'].
                           ' -o BatchMode=yes -o StrictHostKeyChecking=accept-new';
    return $env;
}

/**
 * Run borg with the given argument list and capture its output.
 * Returns ['rc' => int, 'out' => string]. rc 124 means it hit the timeout -
 * a hung SSH repository must not hold the web request open forever.
 */
function borg_run(array $args, $timeout = 120) {
    $bin = borg_binary();
    if (!$bin) return ['rc' => 127, 'out' => "borg is not installed"];

    // Borg would otherwise sit waiting on a prompt that nobody can answer.
    array_splice($args, 0, 0, ['--lock-wait', '10']);
    return borg_proc(array_merge([$bin], $args), borg_env(), $timeout);
}

/** proc_open wrapper with a wall-clock timeout and merged stdout/stderr. */
function borg_proc(array $argv, array $env, $timeout) {
    $spec = [0 => ['file', '/dev/null', 'r'],
             1 => ['pipe', 'w'],
             2 => ['pipe', 'w']];
    $p = @proc_open($argv, $spec, $pipes, '/', $env);
    if (!is_resource($p)) return ['rc' => 126, 'out' => 'could not start '.$argv[0]];

    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $out = '';
    $deadline = microtime(true) + $timeout;
    $open = [$pipes[1], $pipes[2]];

    while ($open) {
        $left = $deadline - microtime(true);
        if ($left <= 0) {
            proc_terminate($p, SIGKILL);
            $out .= "\n[timed out after {$timeout}s]";
            foreach ($pipes as $i => $pp) if ($i) @fclose($pp);
            proc_close($p);
            return ['rc' => 124, 'out' => $out];
        }
        $r = $open; $w = $e = [];
        if (@stream_select($r, $w, $e, (int)$left, 0) === false) break;
        foreach ($r as $fh) {
            $chunk = fread($fh, 65536);
            if ($chunk === '' || $chunk === false) {
                if (feof($fh)) {
                    $open = array_values(array_filter($open, fn($x) => $x !== $fh));
                    @fclose($fh);
                }
                continue;
            }
            $out .= $chunk;
            if (strlen($out) > 2 * 1024 * 1024) {           // don't buffer forever
                $out = substr($out, 0, 2 * 1024 * 1024)."\n[output truncated]";
                proc_terminate($p, SIGKILL);
                $open = [];
            }
        }
    }
    foreach ($pipes as $i => $pp) if ($i && is_resource($pp)) @fclose($pp);
    return ['rc' => proc_close($p), 'out' => $out];
}
