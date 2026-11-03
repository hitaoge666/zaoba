#!/usr/bin/env node
/**
 * 早八 zaoba · 容器内置定时器
 *
 * 容器里没有 launchd / Windows 计划任务，由本文件承担定时职责：
 *   - 每 30s 读一次 /data/config.json 的 schedule（time / retryTime）
 *   - 到点（或当天已错过——容器晚启动/重启的情况）触发一次 run-daily.js
 *   - run-daily.js 自带：单实例锁、随机延迟、--skip-if-done（当天已签的平台自动跳过）
 *
 * 状态记录在 /data/.scheduler-state.json，容器重启后不会重复跑当天已跑过的槽位。
 */
import fs from 'node:fs';
import { spawn } from 'node:child_process';

const APP = '/app';
const DATA = '/data';
const CONFIG_FILE = `${DATA}/config.json`;
const STATE_FILE = `${DATA}/scheduler-state.json`;

const log = (msg) => console.log(`${new Date().toLocaleString('sv')} [scheduler] ${msg}`);

function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

/** 当天日期字符串 YYYY-MM-DD（按容器 TZ） */
function todayStr() {
  return new Date().toLocaleDateString('sv');
}

/** "08:00" -> 480；不合法返回 null */
function minutesOfDay(t) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(t || '').trim());
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

function nowMinutes() {
  const d = new Date();
  return d.getHours() * 60 + d.getMinutes();
}

let running = false;

/** Web 控制台子进程（由本进程统一管理，保证 docker stop 时一并退出） */
function startWeb() {
  const port = process.env.ZAOBA_PORT || '7788';
  const child = spawn(process.execPath, [`${APP}/src/index.js`, 'web', `--port=${port}`], {
    cwd: APP,
    env: process.env,
    stdio: 'inherit',
  });
  log(`Web 控制台已启动: 0.0.0.0:${port}（容器外访问 http://localhost:${port}）`);
  child.on('close', (code) => {
    log(`Web 控制台退出（${code ?? '?'}），5 秒后重启`);
    setTimeout(startWeb, 5000);
  });
  return child;
}

function triggerRun(slot, scheduledTime) {
  running = true;
  log(`触发「${slot}」槽位（计划 ${scheduledTime}），调用 run-daily`);
  const env = { ...process.env };
  // 补跑场景不需要再随机延迟太久，但保持默认行为（可设 CHECKIN_NO_DELAY=1 关闭）
  const child = spawn(process.execPath, [`${APP}/src/run-daily.js`], {
    cwd: APP,
    env,
    stdio: 'inherit',
  });
  child.on('error', (e) => {
    log(`启动失败: ${e.message}`);
    running = false;
  });
  child.on('close', (code) => {
    log(`「${slot}」槽位结束，退出码 ${code ?? '?'}`);
    running = false;
  });
}

function tick() {
  if (running) return;
  const cfg = readJSON(CONFIG_FILE, {});
  const state = readJSON(STATE_FILE, {});
  const today = todayStr();
  const slots = [
    ['main', cfg?.schedule?.time ?? '08:00'],
    ['retry', cfg?.schedule?.retryTime ?? '12:30'],
  ];
  for (const [slot, time] of slots) {
    const target = minutesOfDay(time);
    if (target == null) continue;
    if (state[slot] === today) continue; // 今天这个槽位已经跑过
    if (nowMinutes() >= target) {
      // 到点或已错过（容器晚启动）→ 补跑；run-daily 的 skip-if-done 保证幂等
      state[slot] = today;
      try {
        fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
      } catch (e) {
        log(`写状态失败（不影响执行）: ${e.message}`);
      }
      triggerRun(slot, time);
      return; // 一次只触发一个槽位，下个 tick 再看 retry
    }
  }
}

log('内置定时器已启动（默认主跑 08:00 / 补跑 12:30，可在 Web 控制台或 config.json 修改）');
const web = startWeb();

// 优雅退出：把 SIGTERM/SIGINT 转发给 Web 控制台
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log(`收到 ${sig}，正在关闭...`);
    try {
      web.kill(sig);
    } catch {
      /* ignore */
    }
    setTimeout(() => process.exit(0), 1500);
  });
}

tick();
setInterval(tick, 30 * 1000);
