<?php
/* Actions.php - the single POST endpoint behind the Borg Backup pages.
 *
 * Every request must be a POST carrying Unraid's CSRF token. Input is
 * whitelisted per key rather than written through, because the settings file
 * is later sourced by the backup and cron shell scripts.
 */

require_once '/usr/local/emhttp/plugins/borgbackup/include/BorgLib.php';

header('Content-Type: application/json');
header('X-Content-Type-Options: nosniff');

function reply($ok, $msg = '', $extra = []) {
    echo json_encode(array_merge(['ok' => (bool)$ok, 'msg' => $msg], $extra));
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST')
    reply(false, 'POST required');

$expected = borg_parse_cfg('/var/local/emhttp/var.ini')['csrf_token'] ?? '';
if ($expected === '' || !hash_equals($expected, (string)($_POST['csrf_token'] ?? '')))
    reply(false, 'Invalid CSRF token - reload the page and try again');

/* ------------------------------------------------------------- validation -- */

/** Per-key rules. Anything not listed here never reaches the config file. */
function borg_field_rules() {
    return [
        'REPO'            => ['type'=>'line',  'max'=>1024],
        'SSH_KEY'         => ['type'=>'line',  'max'=>1024],
        'PASSPHRASE_MODE' => ['type'=>'enum',  'in'=>['stored','file']],
        'PASSPHRASE_FILE' => ['type'=>'line',  'max'=>1024],
        'ENCRYPTION'      => ['type'=>'enum',  'in'=>['repokey-blake2','repokey','keyfile-blake2','keyfile','none']],
        'ARCHIVE_FORMAT'  => ['type'=>'line',  'max'=>256],
        'COMPRESSION'     => ['type'=>'enum',  'in'=>['zstd,1','zstd,3','zstd,8','lz4','none']],
        'CONTAINER_MODE'  => ['type'=>'enum',  'in'=>['all','selected']],
        'STOP_CONTAINERS' => ['type'=>'enum',  'in'=>['yes','no']],
        'STOP_TIMEOUT'    => ['type'=>'int',   'min'=>5,  'max'=>600],
        'PRUNE_ENABLED'   => ['type'=>'enum',  'in'=>['yes','no']],
        'KEEP_DAILY'      => ['type'=>'int',   'min'=>0,  'max'=>9999],
        'KEEP_WEEKLY'     => ['type'=>'int',   'min'=>0,  'max'=>9999],
        'KEEP_MONTHLY'    => ['type'=>'int',   'min'=>0,  'max'=>9999],
        'KEEP_YEARLY'     => ['type'=>'int',   'min'=>0,  'max'=>9999],
        'COMPACT'         => ['type'=>'enum',  'in'=>['yes','no']],
        'SCHEDULE'        => ['type'=>'enum',  'in'=>['disabled','hourly','daily','weekly','monthly','custom']],
        'MINUTE'          => ['type'=>'int',   'min'=>0,  'max'=>59],
        'HOUR'            => ['type'=>'int',   'min'=>0,  'max'=>23],
        'WEEKDAY'         => ['type'=>'int',   'min'=>0,  'max'=>6],
        'MONTHDAY'        => ['type'=>'int',   'min'=>1,  'max'=>28],
        'CRON'            => ['type'=>'cron'],
        'NOTIFY'          => ['type'=>'enum',  'in'=>['none','failure','all']],
        'LOG_LEVEL'       => ['type'=>'enum',  'in'=>['info','debug']],
    ];
}

/** Returns [cleanValues, errors]. */
function borg_validate($post) {
    $clean = $errors = [];
    foreach (borg_field_rules() as $key => $r) {
        if (!array_key_exists($key, $post)) continue;
        $v = (string)$post[$key];

        switch ($r['type']) {
            case 'enum':
                if (!in_array($v, $r['in'], true)) { $errors[] = "$key: invalid value"; continue 2; }
                break;
            case 'int':
                if (!preg_match('/^-?\d+$/', trim($v))) { $errors[] = "$key: must be a number"; continue 2; }
                $n = (int)$v;
                if ($n < $r['min'] || $n > $r['max']) { $errors[] = "$key: must be between {$r['min']} and {$r['max']}"; continue 2; }
                $v = (string)$n;
                break;
            case 'cron':
                $v = trim($v);
                if ($v !== '' && !preg_match('/^[0-9*,\/-]+(\s+[0-9*,\/-]+){4}$/', $v)) {
                    $errors[] = 'Cron expression must be five fields, e.g. 0 3 * * *';
                    continue 2;
                }
                break;
            default:
                $v = trim($v);
                if (strlen($v) > $r['max']) { $errors[] = "$key: too long"; continue 2; }
                // These land in a file that the shell sources; strip anything
                // that could be expanded there.
                if ($v !== borg_sanitize_value($v)) {
                    $errors[] = "$key: the characters \" \$ ` \\ and line breaks are not allowed";
                    continue 2;
                }
        }
        $clean[$key] = $v;
    }
    return [$clean, $errors];
}

/* ---------------------------------------------------------------- actions -- */

$action = $_POST['action'] ?? '';

switch ($action) {

case 'save_settings': {
    [$clean, $errors] = borg_validate($_POST);
    if ($errors) reply(false, implode("\n", $errors));

    if (($clean['SCHEDULE'] ?? '') === 'custom' && ($clean['CRON'] ?? '') === '')
        reply(false, 'Choose a cron expression, or pick a different schedule.');

    if (($clean['PASSPHRASE_MODE'] ?? '') === 'file' && ($clean['PASSPHRASE_FILE'] ?? '') === '')
        reply(false, 'Enter the path to the passphrase file.');

    $merged = array_merge(borg_settings(), $clean);
    if (!borg_save_settings($merged))
        reply(false, 'Could not write the settings file - is the flash drive writable?');

    // Blank means "leave the stored passphrase alone"; clearing it is a
    // separate, explicit action.
    $p1 = (string)($_POST['PASSPHRASE'] ?? '');
    $p2 = (string)($_POST['PASSPHRASE2'] ?? '');
    if ($p1 !== '' || $p2 !== '') {
        if ($p1 !== $p2) reply(false, 'The two passphrases do not match.');
        if (!borg_save_passphrase($p1))
            reply(false, 'Settings saved, but the passphrase could not be written.');
    }

    borg_save_excludes((string)($_POST['EXCLUDES'] ?? ''));

    // Rewrite the crontab so a schedule change takes effect immediately.
    borg_proc(['/usr/local/emhttp/plugins/borgbackup/scripts/borg-cron.sh'],
              ['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'], 20);

    reply(true, 'Settings saved. '.borg_schedule_text($merged));
}

case 'clear_passphrase':
    reply(borg_clear_passphrase(), 'Stored passphrase removed.');

case 'save_containers': {
    $in = json_decode((string)($_POST['containers'] ?? ''), true);
    if (!is_array($in)) reply(false, 'Malformed container selection');

    $known = borg_list_containers();
    $out   = ['containers' => []];

    foreach ($in as $name => $c) {
        if (!isset($known[$name]) || !is_array($c)) continue;   // ignore stale entries
        $available = array_column($known[$name]['mounts'], 'src');
        $picked    = array_values(array_intersect($available, (array)($c['mounts'] ?? [])));

        $entry = ['enabled' => !empty($c['enabled'])];

        // Storing the list only when it is a real subset keeps "all mounts"
        // meaning "all mounts, including ones added later".
        if (count($picked) !== count($available)) $entry['mounts'] = $picked;

        if (($c['stop'] ?? 'default') === 'yes')     $entry['stop'] = true;
        elseif (($c['stop'] ?? 'default') === 'no')  $entry['stop'] = false;

        $ex = trim(str_replace("\r\n", "\n", (string)($c['excludes'] ?? '')));
        if ($ex !== '') $entry['excludes'] = $ex;

        $out['containers'][$name] = $entry;
    }
    ksort($out['containers']);

    reply(borg_save_container_config($out),
          'Container selection saved ('.count(array_filter($out['containers'],
              fn($e) => $e['enabled'])).' enabled).');
}

case 'test_repo': {
    $s = borg_settings();
    if (($s['REPO'] ?? '') === '') reply(false, 'No repository configured.');
    $r = borg_run(['info'], 90);
    reply($r['rc'] === 0,
          $r['rc'] === 0 ? "Repository is reachable.\n\n".$r['out']
                         : "Could not open the repository (exit $r[rc]).\n\n".$r['out']);
}

case 'init_repo': {
    $s = borg_settings();
    if (($s['REPO'] ?? '') === '') reply(false, 'No repository configured.');

    $probe = borg_run(['info'], 60);
    if ($probe['rc'] === 0)
        reply(false, 'A repository already exists at that location - nothing to do.');

    $enc = $s['ENCRYPTION'] ?? 'repokey-blake2';
    if ($enc !== 'none' && borg_read_passphrase() === null)
        reply(false, 'Set a passphrase before creating an encrypted repository.');

    $r = borg_run(['init', '--encryption', $enc], 180);
    reply($r['rc'] === 0,
          $r['rc'] === 0
            ? "Repository created with encryption '$enc'.\n\n".$r['out']
              ."\n\nBack up your passphrase now. Without it the archives cannot be read."
            : "Could not create the repository (exit $r[rc]).\n\n".$r['out']);
}

case 'install_borg': {
    $r = borg_proc(['/usr/local/emhttp/plugins/borgbackup/scripts/borg-install.sh'],
                   ['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                    'HOME'=>'/root'], 600);
    reply($r['rc'] === 0, $r['out'], ['version' => borg_version()]);
}

case 'run':
case 'dry_run': {
    if (borg_is_running()) reply(false, 'A backup is already running.');
    if (!borg_binary())    reply(false, 'Install borg first.');
    if ((borg_settings()['REPO'] ?? '') === '') reply(false, 'No repository configured.');

    $cmd = '/usr/local/emhttp/plugins/borgbackup/scripts/borg-backup.sh';
    if ($action === 'dry_run') $cmd .= ' --dry-run';
    // Detach: the run outlives this request, and progress is read from the log.
    @exec('nohup setsid '.$cmd.' >/dev/null 2>&1 & echo started');

    reply(true, $action === 'dry_run'
        ? 'Dry run started - watch the log on the Archives & Log tab.'
        : 'Backup started - watch the log on the Archives & Log tab.');
}

case 'status':
    reply(true, '', ['running' => borg_is_running(), 'state' => borg_state()]);

case 'log': {
    $n = max(20, min(2000, (int)($_POST['lines'] ?? 300)));
    if (!is_file(BORG_LOG)) reply(true, '', ['log' => 'No log yet.', 'running' => false]);
    $r = borg_proc(['/usr/bin/tail', '-n', (string)$n, BORG_LOG],
                   ['PATH'=>'/usr/bin:/bin'], 15);
    reply(true, '', ['log' => $r['out'], 'running' => borg_is_running()]);
}

case 'preview': {
    $r = borg_proc(['/usr/bin/php', '-q',
                    '/usr/local/emhttp/plugins/borgbackup/scripts/borg-plan.php'],
                   ['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'], 60);
    reply(true, '', ['plan' => borg_format_plan($r['out']), 'rc' => $r['rc']]);
}

case 'archives': {
    $r = borg_run(['list', '--json'], 180);
    if ($r['rc'] !== 0) reply(false, "Could not list archives (exit $r[rc]).\n\n".$r['out']);
    $j = json_decode($r['out'], true);
    reply(true, '', ['archives' => $j['archives'] ?? []]);
}

case 'repo_info': {
    $r = borg_run(['info', '--json'], 120);
    if ($r['rc'] !== 0) reply(false, "Could not read repository info (exit $r[rc]).\n\n".$r['out']);
    reply(true, '', ['info' => json_decode($r['out'], true)]);
}

default:
    reply(false, 'Unknown action');
}

/** Turn borg-plan.php's tagged output into something readable in the UI. */
function borg_format_plan($raw) {
    $lines = [];
    foreach (preg_split('/\r?\n/', (string)$raw) as $l) {
        if ($l === '') continue;
        // stdout is tagged; stderr warnings are mixed in and must not be
        // mistaken for tags just because they start with the same letter.
        if (!preg_match('/^(?:([CPX]) (.*)|(S) ([01])|(E))$/', $l, $m)) {
            $lines[] = '! '.$l;                            // warning from stderr
            continue;
        }
        if (!empty($m[5])) continue;                       // end of record
        if (!empty($m[3])) { $lines[] = '    stop while archiving: '.($m[4] === '1' ? 'yes' : 'no'); continue; }
        switch ($m[1]) {
            case 'C': $lines[] = "\n".$m[2]; break;
            case 'P': $lines[] = '    + '.$m[2]; break;
            case 'X': $lines[] = '    - exclude '.$m[2]; break;
        }
    }
    return trim(implode("\n", $lines)) ?: 'Nothing would be backed up with the current selection.';
}
