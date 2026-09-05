#!/usr/bin/php -q
<?php
/* borg-plan.php - resolve settings + container selections into a flat backup
 * plan for borg-backup.sh to execute.
 *
 * Unraid has no jq, but it always has php, so the JSON/docker side stays here
 * (shared with the web UI) and the shell script only executes the plan.
 *
 * Output is line-oriented, one tagged value per line:
 *   C <container>   start of a record
 *   S <0|1>         stop the container while it is archived
 *   P <path>        host path to archive
 *   X <pattern>     exclude pattern
 *   E               end of record
 * Anything on stderr is a warning for the log.
 */

require_once '/usr/local/emhttp/plugins/borgbackup/include/BorgLib.php';

$s    = borg_settings();
$ccfg = borg_container_config();
$mode = $s['CONTAINER_MODE'] ?? 'all';
$all  = borg_list_containers();

if (!$all) {
    fwrite(STDERR, "No Docker containers found (is the Docker service running?)\n");
    exit(3);
}

$globalStop = ($s['STOP_CONTAINERS'] ?? 'no') === 'yes';
$globalEx   = borg_lines(borg_excludes());
$records    = [];

foreach ($all as $name => $c) {
    $sel = $ccfg['containers'][$name] ?? null;

    if ($mode === 'selected') {
        if (!$sel || empty($sel['enabled'])) continue;
    } elseif ($sel && isset($sel['enabled']) && !$sel['enabled']) {
        continue;                                             // explicit opt-out
    }

    // A stored 'mounts' list means the user picked a subset. No such key means
    // "every mount", which is also how a container picks up mounts added after
    // it was configured.
    $custom = $sel && array_key_exists('mounts', $sel) && is_array($sel['mounts']);
    $paths  = $custom
            ? array_values(array_intersect(borg_mount_sources($c), $sel['mounts']))
            : borg_mount_sources($c);

    if (!$paths) {
        if ($custom || $mode === 'selected')
            fwrite(STDERR, "Skipping '$name': no backable mounts selected\n");
        continue;
    }

    $paths = borg_usable_paths($paths, $name);
    if (!$paths) continue;

    $records[] = [
        'name'     => $name,
        'stop'     => isset($sel['stop']) ? (bool)$sel['stop'] : $globalStop,
        'paths'    => $paths,
        'excludes' => array_merge($globalEx, borg_lines($sel['excludes'] ?? '')),
    ];
}

if (!$records) {
    fwrite(STDERR, "Nothing to back up: no container matched the current selection\n");
    exit(4);
}

foreach ($records as $r) {
    echo "C {$r['name']}\n";
    echo 'S '.($r['stop'] ? '1' : '0')."\n";
    foreach ($r['paths']    as $p) echo "P $p\n";
    foreach ($r['excludes'] as $x) echo "X $x\n";
    echo "E\n";
}
exit(0);

/* ------------------------------------------------------------------------- */

function borg_mount_sources($c) {
    return array_values(array_unique(array_column($c['mounts'], 'src')));
}

/** Split a textarea into trimmed, comment-free lines. */
function borg_lines($text) {
    $out = [];
    foreach (preg_split('/\r?\n/', (string)$text) as $l) {
        $l = trim($l);
        if ($l !== '' && $l[0] !== '#') $out[] = $l;
    }
    return $out;
}

/**
 * Drop paths borg cannot archive, and paths whose names would corrupt the
 * line-oriented plan format. Also drops nested paths - archiving both
 * /mnt/user/appdata/x and /mnt/user/appdata/x/y stores y twice.
 */
function borg_usable_paths($paths, $name) {
    $ok = [];
    foreach ($paths as $p) {
        if (strpbrk($p, "\n\r") !== false) {
            fwrite(STDERR, "Skipping a path in '$name': newline in path name\n");
            continue;
        }
        if (!file_exists($p)) {
            fwrite(STDERR, "Skipping '$p' for '$name': path does not exist\n");
            continue;
        }
        $ok[] = rtrim($p, '/') ?: '/';
    }
    $ok = array_unique($ok);

    $out = [];
    foreach ($ok as $p) {
        $nested = false;
        foreach ($ok as $q) {
            if ($p !== $q && str_starts_with($p.'/', $q.'/')) { $nested = true; break; }
        }
        if (!$nested) $out[] = $p;
    }
    sort($out);
    return $out;
}
