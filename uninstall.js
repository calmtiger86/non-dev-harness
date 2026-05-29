#!/usr/bin/env node
'use strict';

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const HOME       = os.homedir();
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
const SETTINGS   = path.join(CLAUDE_DIR, 'settings.json');

function log(msg) { console.log('  ' + msg); }
function ok(msg)  { console.log('  ✓ ' + msg); }
function warn(msg) { console.log('  ⚠ ' + msg); }

function rmDir(p) {
  if (fs.existsSync(p)) {
    fs.rmSync(p, { recursive: true, force: true });
    return true;
  }
  return false;
}

log('non-dev-harness 제거를 시작합니다...');
log('');

const targets = [
  { path: path.join(CLAUDE_DIR, 'plugins', 'non-dev-harness'), label: '플러그인' },
  { path: path.join(CLAUDE_DIR, 'skills', 'hs'), label: '/hs 스킬' },
  { path: path.join(CLAUDE_DIR, 'skills', 'ci'), label: '/ci 스킬' },
  { path: path.join(CLAUDE_DIR, 'skills', 'co'), label: '/co 스킬' },
];

for (const t of targets) {
  if (rmDir(t.path)) ok(t.label + ' 제거됨');
  else warn(t.label + ' 이미 없음');
}

const rulePath = path.join(CLAUDE_DIR, 'rules', 'common', 'non-dev-core.md');
if (fs.existsSync(rulePath)) {
  fs.unlinkSync(rulePath);
  ok('규칙 파일 제거됨');
} else {
  warn('규칙 파일 이미 없음');
}

if (fs.existsSync(SETTINGS)) {
  try {
    const settings = JSON.parse(fs.readFileSync(SETTINGS, 'utf-8'));
    if (settings.hooks && Array.isArray(settings.hooks.SessionStart)) {
      const before = settings.hooks.SessionStart.length;
      settings.hooks.SessionStart = settings.hooks.SessionStart.filter(function(e) {
        return !(Array.isArray(e.hooks) && e.hooks.some(function(h) {
          return typeof h.command === 'string' && h.command.includes('non-dev-harness');
        }));
      });
      if (settings.hooks.SessionStart.length < before) {
        const tmpPath = SETTINGS + '.tmp';
        fs.writeFileSync(tmpPath, JSON.stringify(settings, null, 2) + '\n', 'utf-8');
        fs.renameSync(tmpPath, SETTINGS);
        ok('SessionStart 훅 제거됨');
      } else {
        warn('훅이 이미 없음');
      }
    }
  } catch (e) {
    warn('settings.json 처리 실패: ' + e.message);
  }
}

console.log('');
console.log('제거 완료! 프로젝트 폴더의 CLAUDE.md 등 5개 파일은 유지됩니다.');
console.log('Claude Code를 재시작하세요.');
