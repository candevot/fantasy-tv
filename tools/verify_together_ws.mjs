#!/usr/bin/env node
/**
 * 一起看（`/ws/together`）协议全流程验证：**两个客户端**跑一遍
 * 建房 → 加入 → 成员同步 → 播放 / 暂停 / 切集 / 倍速 → 聊天 → 离开。
 *
 * 为什么要这个脚本：App 里「连不上」的原因有一半在协议/地址层，
 * 用 curl 只能测 HTTP，测不到 WebSocket 的 authority（服务器权威状态）。
 * 这个脚本不需要 App，直接对着服务器跑，CI / 本地都能用。
 *
 * 用法：
 *   node tools/verify_together_ws.mjs
 *   TOGETHER_WS=ws://host:port/ws/together API_ROOT=http://host:port/api \
 *   VIDEO_ID=tw_99674 node tools/verify_together_ws.mjs
 *
 * 退出码：0 = 全通过；1 = 有断言失败（打印每一步的原始消息）。
 * 依赖：Node >= 22（内置全局 WebSocket / fetch）。
 */

const API_ROOT = (process.env.API_ROOT || 'http://125.94.244.87:8787/api').replace(/\/+$/, '');
const WS_URL = process.env.TOGETHER_WS || API_ROOT.replace(/^http/, 'ws').replace(/\/api$/, '') + '/ws/together';
const TIMEOUT = Number(process.env.STEP_TIMEOUT_MS || 8000);

let passed = 0;
const failures = [];

function check(cond, name, detail) {
  if (cond) {
    passed++;
    console.log('  ✓ ' + name);
  } else {
    failures.push(name + (detail ? ' → ' + detail : ''));
    console.log('  ✗ ' + name + (detail ? ' → ' + detail : ''));
  }
}

function client(label) {
  const ws = new WebSocket(WS_URL);
  const log = [];
  const waiters = [];
  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }
    msg.__raw = event.data;
    log.push(msg);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].pred(msg)) {
        waiters[i].resolve(msg);
        waiters.splice(i, 1);
      }
    }
  };
  const wait = (pred, ms = TIMEOUT) =>
    new Promise((resolve, reject) => {
      const hit = log.find(pred);
      if (hit) return resolve(hit);
      const waiter = { pred, resolve };
      waiters.push(waiter);
      setTimeout(() => {
        const at = waiters.indexOf(waiter);
        if (at >= 0) {
          waiters.splice(at, 1);
          reject(new Error(`${label}: 等待超时（${ms}ms）`));
        }
      }, ms);
    });
  const open = () =>
    new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error(`${label}: WebSocket 打不开 ${WS_URL}`));
    });
  return {
    label,
    log,
    wait,
    open,
    send: (obj) => ws.send(JSON.stringify(obj)),
    close: () => {
      try {
        ws.close();
      } catch {}
    },
  };
}

async function pickVideoId() {
  if (process.env.VIDEO_ID) return process.env.VIDEO_ID;
  const home = await fetch(`${API_ROOT}/home?channel=recommend`).then((r) => r.json());
  const ids = [];
  const walk = (value) => {
    if (Array.isArray(value)) return value.forEach(walk);
    if (value && typeof value === 'object') {
      if (typeof value.id === 'string' || typeof value.id === 'number') ids.push(String(value.id));
      Object.values(value).forEach(walk);
    }
  };
  walk(home);
  for (const id of ids.slice(0, 12)) {
    try {
      const detail = await fetch(`${API_ROOT}/detail?id=${encodeURIComponent(id)}`).then((r) => r.json());
      if (detail && detail.code === 0) return id;
    } catch {
      // 换下一个
    }
  }
  throw new Error('拿不到有效的 videoId（用 VIDEO_ID=… 指定一个）');
}

const roomState = (msg) => msg && msg.action === 'room_state';

async function main() {
  console.log('一起看协议验证');
  console.log('  ws  :', WS_URL);
  console.log('  api :', API_ROOT);

  const version = await fetch(`${API_ROOT}/version`)
    .then((r) => ({ status: r.status, body: r.text() }))
    .catch((e) => ({ status: 0, body: Promise.resolve(String(e)) }));
  const versionBody = await version.body;
  check(version.status === 200, '服务器 HTTP 可达（/api/version）', `status=${version.status}`);
  check(versionBody.trim().startsWith('{'), '返回是 JSON', versionBody.slice(0, 80));

  const videoId = await pickVideoId();
  console.log('  video:', videoId);

  const A = client('A(房主)');
  const B = client('B(成员)');
  try {
    await Promise.all([A.open(), B.open()]);
    const helloA = await A.wait((m) => m.action === 'hello');
    const helloB = await B.wait((m) => m.action === 'hello');
    check(!!helloA.user?.id && !!helloB.user?.id, '两端都收到 hello（含用户身份）');
    check(helloA.user.id !== helloB.user.id, '两个客户端身份不同', `${helloA.user.id} vs ${helloB.user.id}`);

    // 建房间
    A.send({ action: 'create', videoId, ep: 2, line: 'l1', title: 'e2e' });
    const room = await A.wait((m) => m.action === 'room' || m.action === 'error');
    check(room.action === 'room', '建房成功', room.action === 'error' ? `${room.code}: ${room.msg}` : '');
    if (room.action !== 'room') throw new Error('建房失败，后续步骤无法继续');
    const code = String(room.room.code);
    const hostToken = room.room.hostToken || room.hostToken || '';
    check(/^\d{6}$/.test(code), '房号是 6 位数字', code);
    check(!!hostToken, '返回 hostToken（房主重连凭证）');
    check(String(room.room.videoId) === String(videoId), '房间绑定了正确的作品', String(room.room.videoId));

    // 加入
    B.send({ action: 'join', code });
    const joined = await B.wait((m) => m.action === 'room_state' || m.action === 'error');
    check(roomState(joined), '成员加入后收到权威状态', JSON.stringify(joined).slice(0, 120));
    const memberIds = (joined.members || []).map((m) => m.id);
    check(memberIds.includes(helloA.user.id) && memberIds.includes(helloB.user.id), '成员列表包含房主和成员', JSON.stringify(memberIds));

    // 房主播放 → 成员收到
    A.send({ action: 'state', state: 'play', playing: true, position: 42.5, rate: 1 });
    const playing = await B.wait((m) => roomState(m) && Number(m.position) >= 42 && m.playing === true);
    check(Number(playing.position) >= 42, '播放进度同步到成员', `position=${playing.position}`);
    check(playing.serverTime > 0 && playing.seq > 0, '权威状态带 serverTime / seq');

    // 暂停 + 拖动
    A.send({ action: 'state', state: 'pause', playing: false, position: 88 });
    const paused = await B.wait((m) => roomState(m) && Number(m.position) >= 88 && m.playing === false);
    check(Number(paused.position) >= 88, '暂停 + 拖动进度同步', `position=${paused.position}`);

    // 切集
    A.send({ action: 'episode', ep: 3, line: 'l1' });
    const ep = await B.wait((m) => roomState(m) && Number(m.ep) === 3);
    check(Number(ep.ep) === 3, '换集同步', `ep=${ep.ep}`);

    // 倍速
    A.send({ action: 'rate', rate: 1.5 });
    const rate = await B.wait((m) => roomState(m) && Math.abs(Number(m.rate) - 1.5) < 1e-6);
    check(Math.abs(Number(rate.rate) - 1.5) < 1e-6, '倍速同步', `rate=${rate.rate}`);

    // 成员越权：成员发 state 应被拒绝
    B.send({ action: 'state', state: 'play', position: 999 });
    const denied = await B.wait((m) => m.action === 'error' && m.code === 'host_only', 5000).catch(() => null);
    check(!!denied, '成员越权改进度被服务器拒绝（host_only）');

    // 聊天
    B.send({ action: 'chat', text: 'e2e hello' });
    const chat = await A.wait((m) => m.action === 'chat');
    check(String(chat.text) === 'e2e hello', '聊天互通', String(chat.text));

    // 时钟校准
    const sentAt = Date.now();
    A.send({ action: 'ping', t: sentAt, id: 1 });
    const pong = await A.wait((m) => m.action === 'pong');
    check(Number(pong.t) === sentAt, 'pong 回显 t', String(pong.t));
    check(Number(pong.serverTime || pong.serverAt) > 0, 'pong 带服务器时间');

    // 房主断线 → 同 hostToken 恢复房主
    A.close();
    await new Promise((r) => setTimeout(r, 300));
    const A2 = client('A(重连)');
    await A2.open();
    await A2.wait((m) => m.action === 'hello');
    A2.send({ action: 'join', code, hostToken });
    const restored = await A2.wait((m) => roomState(m) || m.action === 'error', 6000);
    check(roomState(restored), '房主用 hostToken 重连回到原房间');
    check(String(restored.hostId || '').length > 0, '重连后仍有房主标记', String(restored.hostId));

    // 成员离开 → 房主收到 system
    B.send({ action: 'leave' });
    const left = await A2.wait((m) => m.action === 'system' || roomState(m), 6000);
    check(!!left, '成员离开有通知');
    A2.close();
  } finally {
    A.close();
    B.close();
  }
}

main()
  .then(() => {
    if (failures.length > 0) {
      console.log(`\n结果：失败 ${failures.length} 项，通过 ${passed} 项`);
      failures.forEach((f) => console.log('  - ' + f));
      process.exit(1);
    }
    console.log(`\n结果：全部通过（${passed} 项断言）`);
    process.exit(0);
  })
  .catch((e) => {
    console.log('\n结果：异常中断：' + e.message);
    process.exit(1);
  });
