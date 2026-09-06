/* borg.js - front-end for the Borg Backup plugin pages.
 * Every page loads this; each init function no-ops when its markup is absent.
 */
(function () {
  'use strict';

  var EP = '/plugins/borgbackup/include/Actions.php';
  var $  = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  /* ------------------------------------------------------------ transport -- */

  function post(action, data) {
    var body = new FormData();
    body.append('action', action);
    body.append('csrf_token', typeof BORG_CSRF !== 'undefined' ? BORG_CSRF : '');
    Object.keys(data || {}).forEach(function (k) { body.append(k, data[k]); });

    return fetch(EP, { method: 'POST', body: body, credentials: 'same-origin' })
      .then(function (r) { return r.text(); })
      .then(function (t) {
        try { return JSON.parse(t); }
        catch (e) { return { ok: false, msg: 'Unexpected response from the server:\n\n' + t }; }
      })
      .catch(function (e) { return { ok: false, msg: 'Request failed: ' + e.message }; });
  }

  /* ----------------------------------------------------------- output pane -- */

  function out(text, kind) {
    var el = $('#borg-output');
    if (!el) { if (!kind || kind === 'error') alert(text); return; }
    el.hidden = false;
    el.className = 'borg-output' + (kind ? ' borg-' + kind : '');
    el.textContent = text;
    el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  /** Disable a button while its request is in flight. */
  function busy(btn, label, fn) {
    if (btn.disabled) return;
    var original = btn.textContent;
    btn.disabled = true;
    btn.textContent = label;
    Promise.resolve(fn()).then(function () {
      btn.disabled = false;
      btn.textContent = original;
    });
  }

  function on(sel, handler) {
    var el = $(sel);
    if (el) el.addEventListener('click', handler);
  }

  /* --------------------------------------------------- archive name preview -- */

  var PAD = function (n, w) { return String(n).padStart(w || 2, '0'); };

  function strftime(d, fmt) {
    var days   = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
    var months = ['January','February','March','April','May','June','July',
                  'August','September','October','November','December'];
    return fmt.replace(/%([A-Za-z%])/g, function (_, c) {
      switch (c) {
        case 'Y': return d.getFullYear();
        case 'y': return PAD(d.getFullYear() % 100);
        case 'm': return PAD(d.getMonth() + 1);
        case 'd': return PAD(d.getDate());
        case 'H': return PAD(d.getHours());
        case 'M': return PAD(d.getMinutes());
        case 'S': return PAD(d.getSeconds());
        case 'j': return PAD(Math.floor((d - new Date(d.getFullYear(), 0, 0)) / 864e5), 3);
        case 'A': return days[d.getDay()];
        case 'a': return days[d.getDay()].slice(0, 3);
        case 'B': return months[d.getMonth()];
        case 'b': return months[d.getMonth()].slice(0, 3);
        case '%': return '%';
        default:  return '%' + c;
      }
    });
  }

  /** Best-effort local render of borg's placeholders, for the settings preview. */
  function renderFormat(fmt, container) {
    var now = new Date();
    return fmt
      .replace(/\{container\}/g, container)
      .replace(/\{(now|utcnow):([^}]*)\}/g, function (_, which, f) {
        return strftime(which === 'utcnow'
          ? new Date(now.getTime() + now.getTimezoneOffset() * 60000) : now, f);
      })
      .replace(/\{now\}/g,      strftime(now, '%Y-%m-%dT%H:%M:%S'))
      .replace(/\{utcnow\}/g,   strftime(now, '%Y-%m-%dT%H:%M:%S'))
      .replace(/\{hostname\}/g, location.hostname.split('.')[0] || 'tower')
      .replace(/\{fqdn\}/g,     location.hostname || 'tower')
      .replace(/\{user\}/g,     'root')
      .replace(/\{pid\}/g,      '12345')
      .replace(/\{borgversion\}/g, '1.4.1');
  }

  /* ------------------------------------------------------------- settings -- */

  function initSettings() {
    var form = $('#borg-settings');
    if (!form) return;

    var val = function (n) { var e = form.elements[n]; return e ? e.value : ''; };

    function syncFormatPreview() {
      var el = $('#borg-format-preview');
      if (!el) return;
      var fmt = val('ARCHIVE_FORMAT');
      if (!fmt.trim()) { el.textContent = '(no format set)'; return; }
      var text = renderFormat(fmt, 'plex');
      el.textContent = text;
      // Two containers colliding on one name is the failure mode worth warning
      // about: prune matches archives by this pattern.
      var collides = renderFormat(fmt, 'sonarr') === text;
      el.classList.toggle('borg-bad', collides);
      el.title = collides
        ? 'This format does not include {container}, so every container writes archives under the same name.'
        : '';
    }

    function syncSchedule() {
      var mode = val('SCHEDULE');
      var show = {
        disabled: [],
        hourly:  ['minute'],
        daily:   ['hour', 'minute'],
        weekly:  ['weekly', 'hour', 'minute'],
        monthly: ['monthly', 'hour', 'minute'],
        custom:  ['custom']
      }[mode] || [];
      $$('.borg-sched').forEach(function (el) {
        el.style.display = show.some(function (c) {
          return el.classList.contains('borg-sched-' + c);
        }) ? '' : 'none';
      });
    }

    function syncPassMode() {
      var stored = val('PASSPHRASE_MODE') === 'stored';
      $$('.borg-when-stored').forEach(function (e) { e.style.display = stored ? '' : 'none'; });
      $$('.borg-when-file').forEach(function (e) { e.style.display = stored ? 'none' : ''; });
    }

    form.addEventListener('input', function (e) {
      if (e.target.name === 'ARCHIVE_FORMAT') syncFormatPreview();
    });
    form.addEventListener('change', function (e) {
      if (e.target.name === 'SCHEDULE')        syncSchedule();
      if (e.target.name === 'PASSPHRASE_MODE') syncPassMode();
    });

    var show = $('#borg-pass-show');
    if (show) show.addEventListener('change', function () {
      ['#borg-pass', '#borg-pass2'].forEach(function (s) {
        var e = $(s); if (e) e.type = show.checked ? 'text' : 'password';
      });
    });

    syncFormatPreview(); syncSchedule(); syncPassMode();

    function settingsPayload() {
      var d = {};
      $$('input, select, textarea', form).forEach(function (el) {
        if (!el.name) return;
        d[el.name] = el.type === 'checkbox' ? (el.checked ? 'yes' : 'no') : el.value;
      });
      return d;
    }

    on('#borg-save', function (e) {
      busy(e.target, 'Saving...', function () {
        return post('save_settings', settingsPayload()).then(function (r) {
          out(r.msg, r.ok ? 'ok' : 'error');
          if (r.ok) { $('#borg-pass').value = ''; $('#borg-pass2').value = ''; }
        });
      });
    });

    on('#borg-test', function (e) {
      busy(e.target, 'Testing...', function () {
        return post('test_repo', {}).then(function (r) { out(r.msg, r.ok ? 'ok' : 'error'); });
      });
    });

    on('#borg-init', function (e) {
      if (!confirm('Create a new borg repository at the configured location?\n\n' +
                   'This does nothing if a repository is already there.')) return;
      busy(e.target, 'Initialising...', function () {
        return post('init_repo', {}).then(function (r) { out(r.msg, r.ok ? 'ok' : 'error'); });
      });
    });

    on('#borg-install', function (e) {
      busy(e.target, 'Starting...', function () {
        return post('install_borg', {}).then(function (r) {
          if (!r.ok) { out(r.msg, 'error'); return; }
          // ~26MB: this runs detached and we watch its log.
          liveLog('Installing borg', 'install_status', function (ok) {
            if (ok) setTimeout(function () { location.reload(); }, 2500);
          });
        });
      });
    });

    on('#borg-dry', function (e) {
      busy(e.target, 'Starting...', function () {
        return post('dry_run', {}).then(function (r) { out(r.msg, r.ok ? 'ok' : 'error'); });
      });
    });

    on('#borg-run', function (e) {
      if (!confirm('Start a backup now?')) return;
      busy(e.target, 'Starting...', function () {
        return post('run', {}).then(function (r) { out(r.msg, r.ok ? 'ok' : 'error'); });
      });
    });
  }

  /* ----------------------------------------------------------- containers -- */

  function initContainers() {
    var form = $('#borg-containers');
    if (!form) return;

    function refreshCount(box) {
      var n = $$('.borg-mount', box).filter(function (m) { return m.checked; }).length;
      var el = $('.borg-n', box);
      if (el) el.textContent = n;
      // "auto" only holds while every mount is selected.
      var auto = $('.borg-auto', box);
      var all  = n === $$('.borg-mount', box).length;
      if (auto) auto.style.display = all ? '' : 'none';
      box.classList.toggle('borg-off', !$('.borg-c-enabled', box).checked);
    }

    form.addEventListener('change', function (e) {
      var box = e.target.closest('.borg-container');
      if (!box) return;
      // Ticking a container with nothing selected should select everything.
      if (e.target.classList.contains('borg-c-enabled') && e.target.checked &&
          !$$('.borg-mount', box).some(function (m) { return m.checked; })) {
        $$('.borg-mount', box).forEach(function (m) { m.checked = true; });
      }
      refreshCount(box);
    });

    form.addEventListener('click', function (e) {
      if (!e.target.classList.contains('borg-toggle')) return;
      var body = $('.borg-cbody', e.target.closest('.borg-container'));
      body.hidden = !body.hidden;
      e.target.setAttribute('aria-expanded', String(!body.hidden));
    });

    on('#borg-expand',   function () { $$('.borg-cbody').forEach(function (b) { b.hidden = false; }); });
    on('#borg-collapse', function () { $$('.borg-cbody').forEach(function (b) { b.hidden = true; }); });

    function setAll(state) {
      $$('.borg-container').forEach(function (box) {
        var cb = $('.borg-c-enabled', box);
        if (!cb || cb.disabled) return;
        cb.checked = state;
        if (state) $$('.borg-mount', box).forEach(function (m) { m.checked = true; });
        refreshCount(box);
      });
    }
    on('#borg-all-on',  function () { setAll(true); });
    on('#borg-all-off', function () { setAll(false); });

    $$('.borg-container').forEach(refreshCount);

    function payload() {
      var d = {};
      $$('.borg-container').forEach(function (box) {
        var cb = $('.borg-c-enabled', box);
        if (!cb) return;
        d[box.dataset.name] = {
          enabled:  cb.checked,
          mounts:   $$('.borg-mount', box).filter(function (m) { return m.checked; })
                      .map(function (m) { return m.value; }),
          stop:     ($('.borg-c-stop', box)     || { value: 'default' }).value,
          excludes: ($('.borg-c-excludes', box) || { value: '' }).value
        };
      });
      return d;
    }

    on('#borg-save-containers', function (e) {
      busy(e.target, 'Saving...', function () {
        return post('save_containers', { containers: JSON.stringify(payload()) })
          .then(function (r) { out(r.msg, r.ok ? 'ok' : 'error'); });
      });
    });

    on('#borg-preview', function (e) {
      busy(e.target, 'Building...', function () {
        return post('preview', {}).then(function (r) {
          out(r.ok ? r.plan : r.msg, r.ok ? 'plain' : 'error');
        });
      });
    });
  }

  /* ------------------------------------------------------------- archives -- */

  function bytes(n) {
    if (!n && n !== 0) return '';
    var u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i ? n.toFixed(1) : n) + ' ' + u[i];
  }

  function initArchives() {
    var target = $('#borg-archives');
    if (!target) return;

    on('#borg-load-archives', function (e) {
      busy(e.target, 'Loading...', function () {
        target.innerHTML = '<p class="borg-hint">Reading the repository...</p>';
        return post('archives', {}).then(function (r) {
          if (!r.ok) { target.innerHTML = ''; out(r.msg, 'error'); return; }
          if (!r.archives.length) {
            target.innerHTML = '<p class="borg-hint">The repository has no archives yet.</p>';
            return;
          }
          var rows = r.archives.slice().reverse().map(function (a) {
            return '<tr><td><code>' + esc(a.name) + '</code></td><td>' +
                   esc((a.start || '').replace('T', ' ').split('.')[0]) + '</td></tr>';
          }).join('');
          target.innerHTML =
            '<p class="borg-hint">' + r.archives.length + ' archive(s), newest first.</p>' +
            '<table class="borg-mounts"><thead><tr><th>Archive</th><th>Created</th></tr></thead>' +
            '<tbody>' + rows + '</tbody></table>';
        });
      });
    });

    on('#borg-repo-info', function (e) {
      busy(e.target, 'Reading...', function () {
        return post('repo_info', {}).then(function (r) {
          if (!r.ok) { out(r.msg, 'error'); return; }
          var c = (r.info && r.info.cache && r.info.cache.stats) || {};
          out('Original size:     ' + bytes(c.total_size) +
              '\nAfter compression: ' + bytes(c.total_csize) +
              '\nActually on disk:  ' + bytes(c.unique_csize) +
              '\n\nDeduplication and compression are why the last number is the one' +
              '\nthat matters for free space.', 'plain');
        });
      });
    });

    var timer = null;
    function loadLog() {
      return post('log', { lines: 400 }).then(function (r) {
        var el = $('#borg-log');
        if (!el) return;
        var atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
        el.textContent = r.log || 'No log yet.';
        if (atBottom) el.scrollTop = el.scrollHeight;

        var follow = $('#borg-follow');
        if (follow && follow.checked && r.running) {
          timer = setTimeout(loadLog, 3000);
        } else if (follow && follow.checked && !r.running) {
          follow.checked = false;                 // nothing left to follow
        }
      });
    }

    on('#borg-load-log', function (e) { busy(e.target, 'Loading...', loadLog); });

    var follow = $('#borg-follow');
    if (follow) follow.addEventListener('change', function () {
      clearTimeout(timer);
      if (follow.checked) loadLog();
    });
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------------------------------------------------------- live output -- */

  var liveTimer = null;

  /**
   * Show a job's output while it runs.
   *
   * `poll` is an action returning {log, done, rc}. Polling stops on done, and
   * the box stays open afterwards so the result can actually be read - closing
   * automatically would hide exactly the errors this exists to surface.
   */
  function liveLog(title, poll, onDone) {
    var box   = $('#borg-modal'),
        body  = $('#borg-modal-body'),
        state = $('#borg-modal-state');
    if (!box) return;

    clearTimeout(liveTimer);
    $('#borg-modal-title').textContent = title;
    body.textContent = 'Starting...';
    state.textContent = 'running';
    state.className = 'borg-modal-state running';
    box.hidden = false;

    var misses = 0;

    (function tick() {
      post(poll, {}).then(function (r) {
        if (!r.ok) {
          // A dropped poll is not a failed job; only give up after several.
          if (++misses > 5) {
            state.textContent = 'lost contact';
            state.className = 'borg-modal-state failed';
            return;
          }
          liveTimer = setTimeout(tick, 2000);
          return;
        }
        misses = 0;

        var atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40;
        body.textContent = r.log || 'Starting...';
        if (atBottom) body.scrollTop = body.scrollHeight;

        if (!r.done) { liveTimer = setTimeout(tick, 1000); return; }

        var ok = r.rc === 0;
        state.textContent = ok ? 'finished' : 'failed';
        state.className = 'borg-modal-state ' + (ok ? 'ok' : 'failed');
        if (onDone) onDone(ok, r);
      });
    })();
  }

  function initModal() {
    var box = $('#borg-modal');
    if (!box) return;
    function close() { clearTimeout(liveTimer); box.hidden = true; }

    $('#borg-modal-close').addEventListener('click', close);
    // Click the backdrop, but not the box itself.
    box.addEventListener('click', function (e) { if (e.target === box) close(); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !box.hidden) close();
    });
  }

  /* ----------------------------------------------------------------- tabs -- */

  /* Both panes are always in the DOM - only visibility changes - so every
   * handler binds once at load and nothing needs re-wiring on a tab switch. */
  function initTabs() {
    var strip = $('.borg-tabs');
    if (!strip) return;

    function show(name) {
      $$('.borg-pane').forEach(function (p) {
        p.hidden = p.id !== 'borg-pane-' + name;
      });
      $$('.borg-tab').forEach(function (t) {
        t.classList.toggle('active', t.dataset.borgTab === name);
      });
      try { localStorage.setItem('borg-tab', name); } catch (e) { /* private mode */ }
    }

    // Anchors inside the help text switch tabs too, not just the strip.
    document.addEventListener('click', function (e) {
      var el = e.target.closest('[data-borg-tab]');
      if (!el) return;
      e.preventDefault();
      show(el.dataset.borgTab);
    });

    var saved = null;
    try { saved = localStorage.getItem('borg-tab'); } catch (e) { /* ignore */ }
    if (saved && $('#borg-pane-' + saved)) show(saved);
  }

  function init() { initModal(); initTabs(); initSettings(); initContainers(); initArchives(); }

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', init);
  else
    init();
})();
