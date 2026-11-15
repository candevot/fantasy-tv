/* ================= 一起看 WebSocket ================= */
/* TOGETHER_OPEN_CONTROL（2026-11-15 用户要求）：
 *   1. 去掉房主权限。play / pause / seek / next / prev / rate / switchLine /
 *      switchSource / switchTitle 谁发都接受，服务端只做「最后一条生效 + 全员
 *      广播」，不再有 host_only 拒绝；每条操作都带「是谁操作的」给 UI 显示。
 *   2. 房间绑定「源 + 片 + 该源线路列表」，新成员进房一起下发。
 *   3. switchLine 只换线路，不动进度（换线路不能让人从头开始）。
 *   4. 房间在还有人时永不解散；人不在了留 10 分钟重连窗口。
 *
 * 谁是「主导者」（leader）：最后一条控制指令的发送者。他的进度心跳才是权威，
 * 其他人只在本地跟；有人操作 → 他成为主导者，原来的人自动变成跟随者。
 * 纯进度心跳（quiet:true）不算操作，不会把人抢成主导者。
 */
const rooms = new Map(); // code -> room

/** 房间线路列表上限：一个源最多几十条，超出没有展示意义。 */
const MAX_ROOM_LINES = 60;

function makeRoomCode() {
  let code;
  do { code = String(100000 + Math.floor(Math.random() * 900000)); } while (rooms.has(code));
  return code;
}
function wsOrigin(req) {
  const proto = str(req.headers['x-forwarded-proto'], 'http').split(',')[0].replace('http', 'ws');
  return `${proto}://${str(req.headers.host, `localhost:${PORT}`)}`;
}
function resolveIdentity(req, token) {
  const t = token || pickToken(req, new URL(str(req.url, '/ws/together'), 'http://x').searchParams);
  const u = userByToken(t);
  if (u) return { id: u.id, name: u.nickname, avatar: u.avatar, auth: true };
  const n = String(1000 + Math.floor(Math.random() * 9000));
  return { id: 'g_' + randHex(4), name: '观众' + n, avatar: svgAvatar('观', '#8E6BFF', '#5B8CFF'), auth: false };
}
function sendTo(ws, payload) {
  if (ws.readyState === 1) ws.send(JSON.stringify(payload));
}
/** 倍速写入前统一收敛，避免异常值把成员带崩。 */
function clampRoomRate(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return 1;
  return Math.min(4, Math.max(0.25, n));
}
/** 按播放倍速把权威进度推进到 now（暂停时不动）；只改 position，不改 at。 */
function advanceRoomPosition(room, now = Date.now()) {
  if (room.state !== 'play') return room.position;
  const elapsed = (now - room.at) / 1000;
  if (elapsed > 0) room.position = Math.max(0, room.position + elapsed * (room.rate || 1));
  return room.position;
}

/** 线路列表归一化：`[{name,episodes,quality}]` 或 `["金牌极速", …]` → 统一结构。 */
function normalizeRoomLines(raw) {
  const out = [];
  if (!Array.isArray(raw)) return out;
  for (const item of raw) {
    if (out.length >= MAX_ROOM_LINES) break;
    if (typeof item === 'string') {
      const name = item.trim();
      if (name) out.push({ name, id: name, episodes: 0, quality: '' });
      continue;
    }
    if (!item || typeof item !== 'object') continue;
    const name = str(item.name) || str(item.label) || str(item.lineName) || str(item.id);
    if (!name) continue;
    const episodes = Math.max(0, Math.floor(Number(item.episodes ?? item.count ?? item.ep ?? 0))) || 0;
    out.push({
      name,
      id: str(item.id) || name,
      episodes,
      quality: str(item.quality) || str(item.resolution) || '',
      status: str(item.status) || ''
    });
  }
  return out;
}
function roomLinesOf(room) {
  return Array.isArray(room.lines) ? room.lines : [];
}
/** 按线路名 / 线路 id 找房间绑定的线路（大小写不敏感）。 */
function findRoomLine(room, key) {
  const k = str(key);
  if (!k) return null;
  const lines = roomLinesOf(room);
  const lower = k.toLowerCase();
  return lines.find(l => l.name === k) || lines.find(l => l.id === k) ||
    lines.find(l => l.name.toLowerCase() === lower) || lines.find(l => l.id.toLowerCase() === lower) || null;
}
function lineNameOf(room, key) {
  const hit = findRoomLine(room, key);
  if (hit) return hit.name;
  return str(key) || room.lineName || '';
}
function actorOf(ws) {
  const ident = ws.ident || {};
  return { id: ident.id || ws.mid, name: ident.name || '观众', avatar: ident.avatar || '' };
}
/** 记「谁操作的」并把发送者设成当前主导者。 */
function markController(room, ws, action, label) {
  const actor = actorOf(ws);
  // leaderId 给客户端比对（ident.id），leaderMid 只在服务端内部用。
  room.leaderId = actor.id;
  room.leaderMid = ws.mid;
  room.lastOp = { ...actor, action: str(action), label: str(label), at: Date.now() };
  return actor;
}
/**
 * 权威状态：flat 结构对齐 API.md §4（members + 当前播放 + 服务端时间戳 serverTime + seq）。
 * position 一律换算到本次 serverTime：新进房 / 回前台拉状态时不会拿到几分钟前的旧进度。
 */
function roomStatePayload(room) {
  const serverTime = Date.now();
  const position = room.state === 'play'
    ? Math.max(0, room.position + Math.max(0, serverTime - room.at) / 1000 * (room.rate || 1))
    : room.position;
  const leader = room.members.get(room.leaderMid);
  return {
    action: 'room_state',
    code: room.code,
    title: room.title,
    kind: room.kind || '',
    /* 创建者只用于展示（谁开的房），不再有任何权限含义。 */
    hostId: room.creatorMid,
    creatorId: room.creatorMid,
    /* 当前主导者：最后一条控制指令的发送者。 */
    leaderId: room.leaderId || room.leaderMid,
    leader: leader ? leader.name : '',
    /* 最近一次操作：{id,name,avatar,action,label} */
    by: room.lastOp || null,
    members: Array.from(room.members.values()).map(m => {
      const isCreator = m.mid === room.creatorMid;
      const isLeader = m.mid === room.leaderMid || m.id === room.leaderId;
      return {
        id: m.id, name: m.name, avatar: m.avatar,
        ...(isCreator ? { host: true, creator: true } : {}),
        ...(isLeader ? { leader: true } : {})
      };
    }),
    videoId: room.videoId, ep: room.ep,
    line: room.line, lineId: room.line, lineName: room.lineName,
    /* 房间绑定的「源 + 片 + 线路列表」 */
    sourceKey: room.sourceKey, sourceName: room.sourceName,
    sourceKind: room.sourceKind, sourceApi: room.sourceApi,
    vodId: room.vodId, vodName: room.vodName, vodYear: room.vodYear,
    lines: roomLinesOf(room),
    state: room.state,
    playing: room.state === 'play',
    ended: room.state === 'ended',
    position,
    rate: room.rate || 1,
    at: serverTime,        // 兼容旧客户端：服务端时间戳
    serverTime,            // 权威时间戳（客户端据此 clockOffset + 外推）
    rev: room.rev,         // 兼容旧客户端
    seq: room.rev          // 权威版本号，单调递增，客户端丢弃旧 seq
  };
}
/** 任何权威变更都递增 rev 并刷新服务端时间戳；advance=true 用于没有新 position 的成员变更。 */
function bumpRev(room, advance = false) {
  const now = Date.now();
  if (advance) advanceRoomPosition(room, now);
  room.rev += 1; room.at = now;
  return room;
}
function broadcastRoom(room, payload, except) {
  const data = JSON.stringify(payload);
  for (const m of room.members.values()) {
    if (m.ws !== except && m.ws.readyState === 1) m.ws.send(data);
  }
}
function systemTo(room, text) {
  broadcastRoom(room, { action: 'system', text, at: Date.now() });
}
/** 用户主动操作白名单：只有这些 action 才生成操作提示。
 *
 * OP_DEDUPE_3S（2026-11-16）：现场「你 开始播放」连刷 5 条以上。根因是
 * `state` 分支只要 `!quiet` 就 announceOp —— 客户端建房初始态 / 重连 resync /
 * 缓冲结束重播都会发非 quiet 的 state，服务端照单全收。白名单 + 去重窗口
 * 是服务端这一侧的闸门：客户端没升级、或者以后又冒出一条新的内部上报，
 * 也不会再变成聊天区的一句话。
 */
const USER_OP_ACTIONS = new Set([
  'play', 'pause', 'seek', 'rate',
  'episode', 'switchLine', 'switchTitle', 'switchSource'
]);
/** 同一个人 + 同一个动作的去重窗口（与客户端 togetherOpDedupeWindow 同口径）。 */
const OP_DEDUPE_MS = 3000;

/** 广播「谁做了什么」：UI 用它显示「小明 换了线路 → 幻想4K」。 */
function announceOp(room, ws, action, label, from, to) {
  const act = str(action);
  // 非用户动作一律不播：心跳 / 进度 / 未知动作不进聊天区。
  if (!USER_OP_ACTIONS.has(act)) {
    console.log(`[together] skip op=${act}（不在用户操作白名单）`);
    return actorOf(ws);
  }
  // 同一个人 + 同一个动作 3 秒内只播一条（重复广播不是新事件）。
  //
  // 注意：这样判断只跳过**广播**，不跳过 markController —— 主导者该换还是要换，
  // 只是聊天区不再多一句重复提示。
  const who = actorOf(ws);
  const now = Date.now();
  const last = room.lastAnnounce;
  const duplicate = !!(last && last.id === who.id && last.action === act &&
      now - last.at <= OP_DEDUPE_MS);
  room.lastAnnounce = { id: who.id, action: act, at: now };
  const actor = markController(room, ws, action, label);
  if (duplicate) {
    console.log(`[together] dedupe op=${act} by=${who.name}（${OP_DEDUPE_MS}ms 内重复，不广播）`);
    return actor;
  }
  room.lastOp.from = str(from);
  room.lastOp.to = str(to);
  console.log(`[together] action=${act} by=${actor.name} from=${str(from)} to=${str(to)}`);
  broadcastRoom(room, {
    action: 'op',
    by: actor,
    op: act,
    label: str(label),
    from: str(from),
    to: str(to),
    text: `${actor.name} ${str(label)}`.trim(),
    at: Date.now()
  });
  return actor;
}

/** 房间没人了以后保留的最长时间；超时才删除，避免掉线房间永久占号。 */
const ROOM_GRACE_MS = 10 * 60 * 1000;
function clearRoomGrace(room) {
  if (room && room.graceTimer) { clearTimeout(room.graceTimer); room.graceTimer = null; }
}
function scheduleRoomGrace(room) {
  clearRoomGrace(room);
  room.graceTimer = setTimeout(() => {
    room.graceTimer = null;
    const r = rooms.get(room.code);
    if (!r) return;
    if (r.members.size === 0) {
      rooms.delete(r.code);
      console.log(`[ws] 房间 ${r.code} 空置超时，已回收`);
    }
  }, ROOM_GRACE_MS);
  if (typeof room.graceTimer.unref === 'function') room.graceTimer.unref();
}
/** 房间被解散（只剩超时回收一种情况）：广播 closed 后关闭所有连接。 */
function dissolveRoom(room, reason) {
  clearRoomGrace(room);
  const payload = JSON.stringify({ action: 'closed', code: room.code, title: room.title, reason, at: Date.now() });
  for (const m of room.members.values()) {
    m.ws.room = null;
    if (m.ws.readyState === 1) { m.ws.send(payload); m.ws.close(1000, 'closed'); }
  }
  rooms.delete(room.code);
}
/** 主导者离开 / 掉线：把主导权交给还在房间里的最早进来的那位，进度不中断。 */
function reassignLeader(room) {
  if (!room.members.size) { room.leaderMid = ''; room.leaderId = ''; return; }
  if (room.leaderMid && room.members.has(room.leaderMid)) return;
  let pick = '';
  let joinedAt = Infinity;
  for (const m of room.members.values()) {
    const at = Number(m.joinedAt) || 0;
    if (at < joinedAt) { joinedAt = at; pick = m.mid; }
  }
  room.leaderMid = pick;
  room.leaderId = (room.members.get(pick) || {}).id || '';
  room.lastOp = null;
}

/**
 * 离开房间。
 * 没有房主的时代：谁走都不解散房间，只在「没人了」时留一段重连窗口。
 */
function leaveRoom(ws, opts = {}) {
  const announce = opts.announce !== false;
  const code = ws.room;
  if (!code) return;
  const room = rooms.get(code);
  ws.room = null;
  if (!room) return;
  const me = room.members.get(ws.mid);
  if (!me) return;
  room.members.delete(ws.mid);
  if (room.members.size === 0) {
    bumpRev(room, true);
    scheduleRoomGrace(room);
    return;
  }
  const wasLeader = room.leaderMid === ws.mid;
  reassignLeader(room);
  bumpRev(room, true);
  if (announce) systemTo(room, `${me.name} 离开了房间`);
  if (wasLeader) {
    const next = room.members.get(room.leaderMid);
    if (next) systemTo(room, `${next.name} 接着控制播放`);
  }
  broadcastRoom(room, roomStatePayload(room));
}

function handleWsMessage(ws, raw) {
  let msg;
  try { msg = JSON.parse(String(raw)); }
  catch { return sendTo(ws, { action: 'error', code: 'bad_request', msg: '消息不是合法 JSON' }); }
  if (!msg || typeof msg !== 'object') return;

  // 每条消息可携带 token，用于识别登录用户
  if (msg.token && verifyToken(msg.token)) ws.ident = resolveIdentity(ws.req, msg.token);

  const ident = ws.ident;
  const room = ws.room ? rooms.get(ws.room) : null;
  const member = room ? room.members.get(ws.mid) : null;

  const needRoom = () => {
    if (!room || !member) { sendTo(ws, { action: 'error', code: 'not_in_room', msg: '你不在任何房间里' }); return false; }
    return true;
  };
  /* 没有任何权限校验：谁都能操作。原来的 needHost() / host_only 已删除。 */

  switch (msg.action) {
    /* RTT / 时间偏移测量：回 {t, serverAt} */
    case 'ping': {
      const now = Date.now();
      return sendTo(ws, {
        action: 'pong', t: msg.t, id: msg.id,
        serverAt: now, serverTime: now
      });
    }

    case 'list':
      return sendTo(ws, {
        action: 'rooms',
        rooms: Array.from(rooms.values()).map(r => ({
          code: r.code, title: r.title, videoId: r.videoId, ep: r.ep,
          state: r.state, member: r.members.get(r.leaderMid)?.name || '',
          sourceKey: r.sourceKey, sourceName: r.sourceName,
          vodName: r.vodName, line: r.line, lineName: r.lineName,
          lines: roomLinesOf(r).length,
          members: r.members.size, at: r.at
        })),
        at: Date.now()
      });

    case 'create': {
      // 已存在房间的 create 只回错误 + 现有房间快照，绝不解散重建
      const wantCode = str(msg.code) || str(msg.roomCode);
      // 目标房已存在，或本连接已在某房间内：只回现有房间，绝不解散重建
      const existingCode = wantCode && rooms.has(wantCode) ? wantCode
        : (!wantCode && ws.room && rooms.has(ws.room) ? ws.room : '');
      if (existingCode) {
        const cur = rooms.get(existingCode);
        return sendTo(ws, {
          action: 'error', code: 'room_exists',
          msg: wantCode ? '房间已存在，请加入现有房间' : '你已在房间中，先退出再创建新房间',
          room: { code: cur.code, title: cur.title, videoId: cur.videoId, ep: cur.ep, line: cur.line, members: cur.members.size },
          at: Date.now()
        });
      }
      if (ws.room) leaveRoom(ws);
      const videoId = str(msg.videoId);
      const sourceKey = str(msg.sourceKey) || str(msg.source);
      const kindRaw = str(msg.kind);
      const isLive = kindRaw === 'live';
      // jar / 外部源的 id 带 `@src:` 前缀（或不带 videoId 只给 sourceKey），
      // 这两种都不是我们自己库里的作品，绝不能拿 store 去查。
      const external = !!sourceKey || videoId.startsWith('@') || isLive;
      let v = null;
      if (videoId && !external) {
        v = store.getVideo(videoId);
        if (!v) return sendTo(ws, { action: 'error', code: 'not_found', msg: '作品不存在' });
      }
      const vodName = str(msg.vodName) || (v ? v.title : '') || str(msg.title);
      const lines = normalizeRoomLines(msg.lines);
      const lineKey = str(msg.line) || str(msg.lineId) || (lines[0] ? lines[0].name : '');
      const code = /^\d{6}$/.test(wantCode) ? wantCode : makeRoomCode();
      const room = {
        code,
        title: str(msg.title, vodName ? `${vodName} · 一起看` : '一起看'),
        kind: isLive ? 'live' : 'video',
        videoId: videoId || (external ? '' : (store.get('SELECT id FROM videos ORDER BY rowid LIMIT 1') || {}).id || ''),
        ep: clampNum(msg.ep, 1, 9999, 1),
        line: lineKey,
        lineName: lineKey ? (lines.find(l => l.name === lineKey || l.id === lineKey) || {}).name || lineKey : '',
        /* 房间绑定的「源」：key 是稳定标识（hx / 咕噜 / 剧圈 …）。 */
        sourceKey: sourceKey,
        sourceName: str(msg.sourceName) || sourceKey,
        sourceKind: str(msg.sourceKind) || (sourceKey ? 'ext' : 'hx'),
        sourceApi: str(msg.sourceApi) || str(msg.api),
        vodId: str(msg.vodId) || videoId,
        vodName: vodName,
        vodYear: Math.max(0, Math.floor(Number(msg.vodYear ?? (v ? v.year : 0))) || 0),
        lines,
        state: 'pause', position: 0, rate: 1, at: Date.now(), rev: 0,
        creatorMid: ws.mid,
        creatorUid: ident.auth ? ident.id : '',
        leaderMid: ws.mid,
        leaderId: ident.id,
        lastOp: null,
        lastAnnounce: null,
        graceTimer: null,
        members: new Map()
      };
      room.members.set(ws.mid, { ...ident, mid: ws.mid, ws, joinedAt: Date.now() });
      rooms.set(code, room);
      ws.room = code;
      bumpRev(room);
      sendTo(ws, {
        action: 'room',
        room: {
          code, url: `${wsOrigin(ws.req)}?code=${code}`,
          title: room.title, videoId: room.videoId, ep: room.ep,
          line: room.line, lineName: room.lineName,
          kind: room.kind,
          sourceKey: room.sourceKey, sourceName: room.sourceName,
          sourceKind: room.sourceKind, sourceApi: room.sourceApi,
          vodId: room.vodId, vodName: room.vodName, vodYear: room.vodYear,
          lines: roomLinesOf(room),
          host: ws.mid, creator: ws.mid, leader: ws.mid,
          leaderId: ident.id,
          members: [{ id: ident.id, name: ident.name, avatar: ident.avatar, host: true, creator: true, leader: true }]
        },
        at: Date.now()
      });
      sendTo(ws, roomStatePayload(room));
      return;
    }

    case 'join': {
      const code = str(msg.code);
      const target = rooms.get(code);
      if (!target) return sendTo(ws, { action: 'error', code: 'not_found', msg: '房间不存在或已解散' });
      if (ws.room === code) {
        // Refresh snapshots must advance seq so clients do not discard them.
        bumpRev(target, true);
        return sendTo(ws, roomStatePayload(target));
      }
      if (target.members.size >= MAX_MEMBERS) {
        return sendTo(ws, { action: 'error', code: 'room_full', msg: '房间已满（最多 ' + MAX_MEMBERS + ' 人）' });
      }
      if (ws.room) leaveRoom(ws);
      target.members.set(ws.mid, { ...ident, mid: ws.mid, ws, joinedAt: Date.now() });
      ws.room = code;
      clearRoomGrace(target);
      if (!target.leaderMid) { target.leaderMid = ws.mid; target.leaderId = ident.id; }
      bumpRev(target, true);
      // 新成员先拿到「源 + 片 + 线路列表 + 当前线路 + 当前进度」，再对齐播放。
      broadcastRoom(target, roomStatePayload(target));
      systemTo(target, `${ident.name} 进入了房间`);
      return;
    }

    case 'state': {
      if (!needRoom()) return;
      // 纯进度心跳（quiet）不改主导者；非主导者的心跳也不允许覆盖权威状态。
      const quiet = msg.quiet === true;
      const prevPosition = room.position;
      const prevState = room.state;
      if (quiet && room.leaderMid && room.leaderMid !== ws.mid) return;
      const st = ['play', 'pause', 'ended'].includes(msg.state)
        ? msg.state
        : (typeof msg.playing === 'boolean' ? (msg.playing ? 'play' : 'pause') : 'pause');
      if (msg.videoId) {
        const nextId = str(msg.videoId);
        const external = nextId.startsWith('@') || !!room.sourceKey;
        if (!external && !store.hasId(nextId) && !store.getVideo(nextId)) {
          return sendTo(ws, { action: 'error', code: 'not_found', msg: '作品不存在' });
        }
        room.videoId = nextId;
        room.vodId = nextId;
      }
      if (msg.vodName) room.vodName = str(msg.vodName);
      if (msg.sourceKey) {
        room.sourceKey = str(msg.sourceKey);
        room.sourceName = str(msg.sourceName) || room.sourceKey;
        room.sourceKind = str(msg.sourceKind) || room.sourceKind;
        room.sourceApi = str(msg.sourceApi) || room.sourceApi;
      }
      if (msg.lines !== undefined) {
        const nextLines = normalizeRoomLines(msg.lines);
        if (nextLines.length) room.lines = nextLines;
      }
      room.state = st;
      if (msg.position !== undefined && msg.position !== null) {
        room.position = Math.max(0, Number(msg.position) || 0);
      }
      if (msg.ep) room.ep = clampNum(msg.ep, 1, 9999, room.ep);
      const line = str(msg.lineId) || str(msg.line);
      if (line) { room.line = line; room.lineName = lineNameOf(room, line); }
      if (msg.rate !== undefined) room.rate = clampRoomRate(msg.rate);
      if (!quiet) {
        const op = str(msg.op) || (st === 'play' ? 'play' : st === 'pause' ? 'pause' : 'state');
        let from = '';
        let to = '';
        if (op === 'seek') {
          from = fmtClock(prevPosition);
          to = fmtClock(room.position);
        } else if (op === 'play' || op === 'pause') {
          from = prevState === 'play' ? '播放中' : '暂停';
          to = room.state === 'play' ? '播放中' : '暂停';
        }
        announceOp(room, ws, op, opLabel(op, msg, room), from, to);
      }
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));   // 写入权威状态并广播（含 serverTime 与 seq）
      return;
    }

    case 'rate': {
      if (!needRoom()) return;
      // Preserve elapsed playback at the old rate before changing it.
      advanceRoomPosition(room);
      const prevRate = room.rate;
      room.rate = clampRoomRate(msg.rate);
      announceOp(room, ws, 'rate', `把倍速调成 ${room.rate}x`,
        `${prevRate}x`, `${room.rate}x`);
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));
      return;
    }

    case 'seek': {
      if (!needRoom()) return;
      const prevPosition = room.position;
      if (msg.position !== undefined && msg.position !== null) {
        room.position = Math.max(0, Number(msg.position) || 0);
      }
      if (typeof msg.playing === 'boolean') room.state = msg.playing ? 'play' : 'pause';
      announceOp(room, ws, 'seek', `跳到 ${fmtClock(room.position)}`,
        fmtClock(prevPosition), fmtClock(room.position));
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));
      return;
    }

    /* 切集：进度按发送方给的 position（默认 0），播放态沿用发送方的意图。 */
    case 'episode':
    case 'next':
    case 'prev': {
      if (!needRoom()) return;
      const prevEp = room.ep;
      let ep = clampNum(msg.ep, 1, 9999, room.ep);
      if (msg.action === 'next') ep = clampNum(room.ep + 1, 1, 9999, room.ep);
      if (msg.action === 'prev') ep = clampNum(room.ep - 1, 1, 9999, room.ep);
      room.ep = ep;
      const nextLine = str(msg.lineId) || str(msg.line);
      if (nextLine) { room.line = nextLine; room.lineName = lineNameOf(room, nextLine); }
      room.position = msg.position !== undefined && msg.position !== null
        ? Math.max(0, Number(msg.position) || 0)
        : 0;
      room.state = typeof msg.playing === 'boolean' ? (msg.playing ? 'play' : 'pause') : 'play';
      announceOp(room, ws, 'episode', `切到第 ${ep} 集`, `第 ${prevEp} 集`, `第 ${ep} 集`);
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));
      return;
    }

    /* 换片（房间内换到完全另一部剧，可同时换源）：三步选择器选完就发这个。 */
    case 'switchTitle': {
      if (!needRoom()) return;
      const prevName = room.vodName || room.videoId;
      const prevSource = room.sourceName || room.sourceKey;
      const videoId = str(msg.videoId) || str(msg.vodId);
      const sourceKey = str(msg.sourceKey) || room.sourceKey;
      const nextLines = normalizeRoomLines(msg.lines);
      if (videoId) { room.videoId = videoId; room.vodId = videoId; }
      room.vodName = str(msg.vodName) || room.vodName;
      if (msg.vodYear !== undefined) room.vodYear = Math.max(0, Math.floor(Number(msg.vodYear) || 0));
      if (sourceKey) {
        room.sourceKey = sourceKey;
        room.sourceName = str(msg.sourceName) || sourceKey;
        room.sourceKind = str(msg.sourceKind) || room.sourceKind;
        room.sourceApi = str(msg.sourceApi) || '';
      }
      if (nextLines.length) room.lines = nextLines;
      // 集号：发送方给的优先（对方有这集就跳，没有就第 1 集，由客户端决定）。
      room.ep = clampNum(msg.ep, 1, 9999, 1);
      // 换的是另一部片：进度只能从头，除非发送方明确给了位置。
      room.position = msg.position !== undefined && msg.position !== null
        ? Math.max(0, Number(msg.position) || 0)
        : 0;
      const wantLine = str(msg.line) || str(msg.lineId) || (roomLinesOf(room)[0] || {}).name || '';
      const hitLine = findRoomLine(room, wantLine);
      room.line = hitLine ? hitLine.id : wantLine;
      room.lineName = hitLine ? hitLine.name : wantLine;
      room.state = typeof msg.playing === 'boolean' ? (msg.playing ? 'play' : 'pause') : 'play';
      announceOp(room, ws, 'switchTitle',
        `换片 → ${room.vodName || videoId}${room.sourceName ? '（' + room.sourceName + '）' : ''}`,
        prevName, room.vodName || videoId);
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));
      return;
    }

    /* 换线路（房间内，限建房时那个源的线路）：只换路，不动进度。 */
    case 'switchLine': {
      if (!needRoom()) return;
      const key = str(msg.name) || str(msg.lineName) || str(msg.lineId) || str(msg.line);
      if (!key) return sendTo(ws, { action: 'error', code: 'bad_request', msg: '缺少线路名' });
      const hit = findRoomLine(room, key);
      const prevLineName = room.lineName || room.line;
      // 进度原样保留：换线路不能让人从头开始。
      if (msg.position !== undefined && msg.position !== null) {
        room.position = Math.max(0, Number(msg.position) || 0);
      } else {
        advanceRoomPosition(room);
      }
      room.line = hit ? hit.id : key;
      room.lineName = hit ? hit.name : key;
      if (typeof msg.playing === 'boolean') room.state = msg.playing ? 'play' : 'pause';
      if (msg.ep) room.ep = clampNum(msg.ep, 1, 9999, room.ep);
      announceOp(room, ws, 'switchLine', `换了线路 → ${room.lineName}`, prevLineName, room.lineName);
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));
      return;
    }

    /* 换源：房间还能整源切换（同一部片在另一个源上的线路列表）。 */
    case 'switchSource': {
      if (!needRoom()) return;
      const key = str(msg.sourceKey) || str(msg.sourceName);
      if (!key) return sendTo(ws, { action: 'error', code: 'bad_request', msg: '缺少源' });
      const nextLines = normalizeRoomLines(msg.lines);
      const prevSource = room.sourceName || room.sourceKey;
      advanceRoomPosition(room);
      room.sourceKey = key;
      room.sourceName = str(msg.sourceName) || key;
      room.sourceKind = str(msg.sourceKind) || room.sourceKind;
      room.sourceApi = str(msg.sourceApi) || '';
      if (nextLines.length) room.lines = nextLines;
      const want = str(msg.line) || str(msg.lineId) || (nextLines[0] ? nextLines[0].name : '');
      const hit = findRoomLine(room, want);
      room.line = hit ? hit.id : want;
      room.lineName = hit ? hit.name : want;
      if (msg.videoId) { room.videoId = str(msg.videoId); room.vodId = str(msg.videoId); }
      if (msg.ep) room.ep = clampNum(msg.ep, 1, 9999, room.ep);
      if (msg.vodName) room.vodName = str(msg.vodName);
      announceOp(room, ws, 'switchSource', `换成了源「${room.sourceName}」`, prevSource, room.sourceName);
      bumpRev(room);
      broadcastRoom(room, roomStatePayload(room));
      return;
    }

    case 'chat': {
      if (!needRoom()) return;
      const text = str(msg.text);
      if (!text) return sendTo(ws, { action: 'error', code: 'bad_request', msg: '消息不能为空' });
      broadcastRoom(room, {
        action: 'chat',
        user: { id: ident.id, name: ident.name, avatar: ident.avatar },
        text: text.slice(0, 300), at: Date.now()
      });
      return;
    }

    case 'leave':
      if (!room) return sendTo(ws, { action: 'error', code: 'not_in_room', msg: '你不在任何房间里' });
      leaveRoom(ws);
      return;

    default:
      return sendTo(ws, { action: 'error', code: 'unknown_action', msg: `未知 action: ${msg.action}` });
  }
}

/** 秒 → `mm:ss` / `h:mm:ss`（操作提示里用）。 */
function fmtClock(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const mm = String(m).padStart(2, '0');
  const ss = String(sec).padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}

/** 操作文案：给「谁操作的」提示用。 */
function opLabel(op, msg, room) {
  switch (op) {
    case 'play': return '开始播放';
    case 'pause': return '暂停了';
    case 'seek': return `跳到 ${fmtClock(room.position)}`;
    case 'rate': return `把倍速调成 ${room.rate}x`;
    case 'episode': return `切到第 ${room.ep} 集`;
    case 'switchLine': return `换了线路 → ${room.lineName || room.line}`;
    case 'switchSource': return `换成了源「${room.sourceName || room.sourceKey}」`;
    default:
      if (msg.state === 'play') return '开始播放';
      if (msg.state === 'pause') return '暂停了';
      return '同步了进度';
  }
}

