#!/usr/bin/env node
'use strict';

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const SRC        = __dirname;
const HOME       = os.homedir();
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
const PLUGIN_DST = path.join(CLAUDE_DIR, 'plugins', 'non-dev-harness');
const SKILLS_DST = path.join(CLAUDE_DIR, 'skills');
const RULES_DST  = path.join(CLAUDE_DIR, 'rules', 'common');
const SETTINGS   = path.join(CLAUDE_DIR, 'settings.json');

function log(msg) { console.log('  ' + msg); }
function ok(msg)  { console.log('  ✓ ' + msg); }
function warn(msg) { console.log('  ⚠ ' + msg); }

const created = [];

function cleanup() {
  for (let i = created.length - 1; i >= 0; i--) {
    const p = created[i];
    try {
      if (fs.existsSync(p)) {
        const stat = fs.lstatSync(p);
        if (stat.isDirectory()) fs.rmSync(p, { recursive: true, force: true });
        else fs.unlinkSync(p);
      }
    } catch { /* best-effort */ }
  }
}

function die(msg) {
  cleanup();
  console.error('  ✗ ' + msg);
  process.exit(1);
}

const SKIP = new Set([
  '.git', 'node_modules', '.omc', '.DS_Store', '.claude',
  'install.js', 'install.sh', 'install.ps1', 'README.md', 'LICENSE'
]);

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src)) {
    if (SKIP.has(entry)) continue;
    const s = path.join(src, entry);
    const d = path.join(dst, entry);
    const stat = fs.lstatSync(s);
    if (stat.isSymbolicLink()) continue;
    if (stat.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

log('non-dev-harness 설치를 시작합니다...');
log('');

// 1. Plugin → ~/.claude/plugins/non-dev-harness/
log('[1/4] 플러그인 파일 복사...');
try {
  if (path.resolve(SRC) !== path.resolve(PLUGIN_DST)) {
    copyDir(SRC, PLUGIN_DST);
    created.push(PLUGIN_DST);
  }
  ok('~/.claude/plugins/non-dev-harness/');
} catch (e) {
  die('플러그인 복사 실패: ' + e.message);
}

// 2. Skills → ~/.claude/skills/hs/, ci/, co/
log('[2/4] 스킬 설치 (/hs, /ci, /co)...');
const skillNames = ['hs', 'ci', 'co'];
for (const name of skillNames) {
  const skillSrc = path.join(SRC, 'skills', name);
  const skillDst = path.join(SKILLS_DST, name);
  if (!fs.existsSync(skillSrc)) {
    warn('/' + name + ' 스킬 소스를 찾을 수 없음: ' + skillSrc);
    continue;
  }
  if (fs.existsSync(skillDst)) {
    const existing = path.join(skillDst, 'SKILL.md');
    if (fs.existsSync(existing)) {
      const content = fs.readFileSync(existing, 'utf-8');
      if (!content.includes('non-dev-harness') && !content.includes('하네스')) {
        warn('/' + name + ' 스킬이 이미 존재합니다 (다른 플러그인). 덮어쓰기를 건너뜁니다.');
        continue;
      }
    }
  }
  try {
    copyDir(skillSrc, skillDst);
    created.push(skillDst);
    ok('/' + name + ' → ~/.claude/skills/' + name + '/');
  } catch (e) {
    die('스킬 복사 실패 (' + name + '): ' + e.message);
  }
}

// 3. Rule → ~/.claude/rules/common/non-dev-core.md
log('[3/4] 규칙 파일 설치...');
const ruleSrc = path.join(SRC, 'rules', 'non-dev-core.md');
const ruleDst = path.join(RULES_DST, 'non-dev-core.md');
if (!fs.existsSync(ruleSrc)) {
  warn('규칙 소스를 찾을 수 없음: ' + ruleSrc);
} else {
  try {
    fs.mkdirSync(RULES_DST, { recursive: true });
    fs.copyFileSync(ruleSrc, ruleDst);
    created.push(ruleDst);
    ok('~/.claude/rules/common/non-dev-core.md');
  } catch (e) {
    die('규칙 설치 실패: ' + e.message);
  }
}

// 4. Hook → settings.json SessionStart
log('[4/4] SessionStart 훅 등록...');
let settings = {};
if (fs.existsSync(SETTINGS)) {
  const raw = fs.readFileSync(SETTINGS, 'utf-8');
  try {
    settings = JSON.parse(raw);
  } catch (e) {
    die('settings.json 파싱 실패 — 파일을 확인하세요: ' + e.message
      + '\n    경로: ' + SETTINGS);
  }
}
if (!settings.hooks) settings.hooks = {};

const ROOT = PLUGIN_DST.replace(/\\/g, '/');
const HOOK_CMD = 'node "' + ROOT + '/hooks/session-start-hint.mjs"';

function hasCmd(entries, cmd) {
  if (!Array.isArray(entries)) return false;
  return entries.some(function(e) {
    return Array.isArray(e.hooks) && e.hooks.some(function(h) { return h.command === cmd; });
  });
}

if (!Array.isArray(settings.hooks.SessionStart)) {
  settings.hooks.SessionStart = [];
}
if (!hasCmd(settings.hooks.SessionStart, HOOK_CMD)) {
  settings.hooks.SessionStart.push({
    hooks: [{ type: 'command', command: HOOK_CMD, timeout: 5 }]
  });
}

try {
  const tmpPath = SETTINGS + '.tmp';
  fs.writeFileSync(tmpPath, JSON.stringify(settings, null, 2) + '\n', 'utf-8');
  fs.renameSync(tmpPath, SETTINGS);
  ok('SessionStart 훅 등록 완료');
} catch (e) {
  die('settings.json 쓰기 실패: ' + e.message);
}

console.log('');
console.log('설치 완료! Claude Code를 재시작하면 바로 작동합니다.');
console.log('');
console.log('사용법:');
console.log('  /hs  — 프로젝트 하네스 세팅 (최초 1회)');
console.log('  /ci  — 세션 시작 체크인');
console.log('  /co  — 세션 종료 체크아웃');
console.log('');
console.log('제거: node ~/.claude/plugins/non-dev-harness/uninstall.js');
