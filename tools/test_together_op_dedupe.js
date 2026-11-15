/* ========================================================================== */
/*  一起看 · 操作提示去重（OP_DEDUPE_3S / 2026-11-16）                        */
/*                                                                            */
/*  现场：聊天区连续 5 条以上「你 开始播放」。服务端这一侧的根因是           */
/*  `state` 分支只要 !quiet 就 announceOp —— 建房初始态 / 重连 resync /      */
/*  缓冲结束重播都会发非 quiet 的 state，服务端照单全收。                      */
/*                                                                            */
/*  这里把 announceOp 抽出来做纯逻辑验证：                                      */
/*    1. 非用户动作（state / progress / 空）绝不广播；                          */
/*    2. 同一个人 + 同一个动作 3 秒内只广播一条；                                */
/*    3. 换动作照常广播；                                                       */
/*    4. 换人做同一个动作照常广播（不同人的事件）；                              */
/*    5. 超过 3 秒窗口照常广播。                                                */
/*                                                                            */
/*  跑法：node tools/test_together_op_dedupe.js                                 */
/* ========================================================================== */
// 端到端：起一个最小 WS 服务端？先用纯逻辑单测验证 announceOp 的两个闸门。
const fs = require('fs');
// 服务端一起看 WS 的源码路径（可用 TOGETHER_WS_SRC 覆盖）。
const SRC = process.env.TOGETHER_WS_SRC ||
  '/root/workspace/together_ws_new.js';
const src = fs.readFileSync(SRC, 'utf8');

// 抽出 announceOp + 白名单 + 去重常量，构造最小运行环境。
const start = src.indexOf('/** 用户主动操作白名单');
const end = src.indexOf('/** 房间没人了以后保留的最长时间');
const body = src.slice(start, end);

const calls = [];
const room = { lastOp: {}, members: new Map() };
const ws = { mid: 'm1', ident: { id: 'g_1', name: '小明', avatar: '' } };
let currentActor = { id: 'g_1', name: '小明', avatar: '' };
const env = {
  str: (v, d = '') => (v == null ? d : String(v).trim()),
  actorOf: () => currentActor,
  markController: () => currentActor,
  broadcastRoom: (_r, payload) => calls.push(payload),
  console: { log: () => {} },
};
const fn = new Function(...Object.keys(env), `${body}; return { announceOp, USER_OP_ACTIONS, OP_DEDUPE_MS };`);
const api = fn(...Object.values(env));

// 1) 白名单：非用户动作不广播
api.announceOp(room, ws, 'state', '同步了进度', '', '');
api.announceOp(room, ws, 'progress', '', '', '');
if (calls.length !== 0) throw new Error('非用户动作不该广播，实际 ' + calls.length);

// 2) 用户动作：第一条广播
api.announceOp(room, ws, 'play', '开始播放', '', '');
if (calls.length !== 1) throw new Error('play 应该广播一次');

// 3) 同一人同一动作 3 秒内重复：不广播
for (let i = 0; i < 10; i++) api.announceOp(room, ws, 'play', '开始播放', '', '');
if (calls.length !== 1) throw new Error('3 秒内重复 play 不该再广播，实际 ' + calls.length);

// 4) 换动作：广播
api.announceOp(room, ws, 'pause', '暂停了', '', '');
if (calls.length !== 2) throw new Error('pause 应该广播为第 2 条');

// 5) 换人做同一个动作：广播（不同人的事件）
currentActor = { id: 'g_2', name: '小红', avatar: '' };
api.announceOp(room, { mid: 'm2' }, 'pause', '暂停了', '', '');
if (calls.length !== 3) throw new Error('换人同动作应广播');

// 6) 超过窗口：广播
const realNow = Date.now;
Date.now = () => realNow() + api.OP_DEDUPE_MS + 100;
api.announceOp(room, ws, 'play', '开始播放', '', '');
Date.now = realNow;
if (calls.length !== 4) throw new Error('超过 3 秒窗口应广播');

console.log('op dedupe checks passed:', calls.length, 'broadcasts');
console.log('broadcasts =', calls.map(c => `${c.op}:${c.by.name}`).join(', '));
