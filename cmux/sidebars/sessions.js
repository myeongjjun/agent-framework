// sessions: "자리 비웠다 돌아왔을 때" 뷰. cmux 가 추적하는 모든 에이전트 세션을
// 워크스페이스 구분 없이 한 줄로 세우고, 내가 봐야 할 순서대로 정렬한다.
//   Needs input(입력 대기·안 읽음) → Running → Today → 정리 후보 → This week → Older
// 정리 후보: 6시간 넘게 idle 인 세션(입력 대기·안 읽음·TODO 아님). 끝났는데 열려 있는 세션을
// 눈에 띄게 모아, 데스크에서 `/done <이름>` 으로 정리하도록 유도한다.
// 행을 누르면 그 워크스페이스로 가서 해당 터미널에 포커스한다.
// 맨 위 "TODO" 는 아침 브리핑 에이전트가 `brief plan` 으로 올린 목록이다.
//
// 이 파일은 템플릿이다. 실제 패널 파일(~/.config/cmux/sidebars/sessions.js)은
// `brief render` 가 아래 PLAN 줄을 채워서 만든다. 고친 뒤 `brief render` 실행.
//   cmux right-sidebar set custom sessions

const PLAN = { at: 0, items: [] }; // @plan
const TEAMS = []; // @teams
// 세션별 최신 요약(panel id 소문자 → 한두 문장). brief render 가 채운다.
const RECAPS = {}; // @recaps
// collab: sib 가 띄운 세션 중 Claude 와 Codex 가 함께 묶인 그룹. `brief render` 가 채운다.
const teamOf = {};
TEAMS.forEach((g, gi) => g.members.forEach((m, mi) => { teamOf[m.panel.toLowerCase()] = { gi, mi, name: g.name, agent: m.agent, last: g.last }; }));
// 묶음의 마지막 메시지를 이 구성원 입장에서 한 줄로: 받은 쪽은 "← new/read", 보낸 쪽은 "→ sent".
function msgLine(t, panel) {
  const m = t.last;
  if (!m) return "";
  const me = String(panel ?? "").toLowerCase();
  if (String(m.to).toLowerCase() === me) return (m.state === "read" ? "← read: " : "← new: ") + m.body;
  if (String(m.from).toLowerCase() === me) return "→ sent" + (m.state === "read" ? " (read): " : " (waiting): ") + m.body;
  return "";
}
const COLLAB_GROUP = 1.5; // Running 다음, Today 앞
const STALE_GROUP = 2.5; // Today 다음, This week 앞
const STALE_AFTER = 6 * 3600; // orch.md 의 정리 후보 기준과 같은 값
const PLAN_TTL = 20 * 3600; // 브리핑 후 20시간이 지나면 목록을 숨긴다
const planIndex = {};
PLAN.items.forEach((it, i) => { planIndex[it.panel.toLowerCase()] = i; });
const NUM = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"];

const [query, setQuery] = signal("");

const GROUPS = ["Needs input", "Running", "Today", "This week", "Older"];
const PLAN_GROUP = -1;
const BRIEF_GROUP = -2; // 데스크(오케스트레이터) 세션: 항상 맨 위, 헤더 없이 한 줄
const isBriefWs = (w) => String(w.title ?? "").startsWith("☀"); // morning-brief.sh 가 만든 워크스페이스
const COLOR = {
  needs_input: "#FF9F0A",
  working: "#0A84FF",
  idle: "#34C759",
  ended: "#7f7f7f66",
};
const DAY = 86400;

function fmtAgo(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

const dirTail = (d) => {
  const parts = String(d ?? "").split("/").filter((p) => p.length > 0);
  return parts.length ? parts[parts.length - 1] : "";
};

const oneLine = (s) => String(s ?? "").replace(/\s+/g, " ").trim();

function groupOf(a, unread, epoch) {
  if (a.status === "needs_input" || unread) return 0;
  if (a.status === "working") return 1;
  const age = epoch - (a.lastActivityAt ?? 0);
  if (a.status === "idle" && age >= STALE_AFTER) return STALE_GROUP;
  if (age < DAY) return 2;
  if (age < 7 * DAY) return 3;
  return 4;
}

// 그룹 헤더 + 세션 행을 하나의 평평한 목록으로 만든다.
const entries = computed(() => {
  const epoch = data.clock()?.epoch ?? 0;
  const q = query().trim().toLowerCase();
  const planLive = PLAN.items.length > 0 && epoch - PLAN.at < PLAN_TTL;
  // 한 터미널에 세션 기록이 여러 개면(재시작·하위 세션) 가장 급한/최근 것 하나만 남긴다.
  const byPanel = {};
  for (const w of data.workspaces() ?? []) {
    for (const a of w.agents ?? []) {
      // 탭이 없는 에이전트는 pane 이 아니다(pane 에서 띄운 데스크톱 앱이 pane 환경을 물려받아 잡힌 프로세스 등).
      // 이동할 곳이 없으므로 목록에 넣지 않는다.
      const tab = (w.tabs ?? []).find((t) => t.id === a.panelId);
      if (!tab) continue;
      const title = oneLine(tab.title || a.title || a.name);
      const rawPrompt = oneLine(tab.latestPrompt);
      const prompt = rawPrompt.startsWith("<") ? "" : rawPrompt; // 에이전트 간 전달 메시지는 숨김
      const dir = dirTail(a.directory || tab.directory || w.directory);
      const recap = RECAPS[String(a.panelId ?? "").toLowerCase()] ?? "";
      if (q && !(title + " " + prompt + " " + dir + " " + w.title + " " + recap).toLowerCase().includes(q)) continue;
      const pk = w.id + ":" + (a.panelId ?? a.id);
      const pi = planLive ? planIndex[String(a.panelId ?? "").toLowerCase()] : undefined;
      const planned = pi !== undefined && !PLAN.items[pi].done;
      const row = {
        key: "a:" + pk,
        kind: "agent",
        group: planned ? PLAN_GROUP : groupOf(a, !!tab.hasUnread, epoch),
        num: planned ? (NUM[pi] ?? String(pi + 1)) : "",
        todo: planned ? PLAN.items[pi].do : "",
        order: planned ? pi : 0,
        wsId: w.id,
        wsSelected: !!w.selected,
        panel: a.panelId ?? tab.id,
        brief: isBriefWs(w),
        // agents[].surfaceId 는 탭의 surfaceId 와 다른 값이라 surface.focus 가 엉뚱한 pane 으로 간다.
        // 탭(패널) id 를 쓴다.
        surfaceId: tab.surfaceId ?? a.panelId,
        here: !!(w.selected && tab.focused),
        status: a.status,
        unread: !!tab.hasUnread,
        title,
        recap,
        // 요약이 있으면 마지막 프롬프트 대신 요약을 보여 준다.
        sub: [a.kind === "claude" ? dir : dir + " (" + a.kind + ")", recap || (prompt && prompt !== title ? prompt : "")]
          .filter((x) => x).join(" › "),
        at: a.lastActivityAt ?? 0,
      };
      const prev = byPanel[pk];
      if (!prev || row.group < prev.group || (row.group === prev.group && row.at > prev.at)) byPanel[pk] = row;
    }
  }
  const rows = Object.values(byPanel);
  // 브리핑 세션이 여러 개(어제 것 등)면 가장 최근 것만 맨 위에 고정한다.
  const briefs = rows.filter((r) => r.brief).sort((x, y) => y.at - x.at);
  if (briefs.length > 0) {
    const b = briefs[0];
    b.group = BRIEF_GROUP;
    b.num = "";
    b.title = "☀ Desk";
    b.todo = b.status === "working" ? "working…" : "/go N · /done N · /today";
  }
  // collab 구성원은 원래 자리에도 그대로 두고, Collab 묶음에 한 번 더 보여 준다.
  for (const r of rows.slice()) {
    const t = teamOf[String(r.panel ?? "").toLowerCase()];
    if (!t || r.group === BRIEF_GROUP) continue;
    const line = msgLine(t, r.panel);
    rows.push({ ...r, key: "c:" + r.key, group: COLLAB_GROUP, order: t.gi * 100 + t.mi, num: "",
      todo: line ? "⇄ " + t.name + " · " + line : "", title: "[" + t.agent + "] " + r.title,
      sub: "⇄ " + t.name + (r.sub ? " · " + r.sub : "") });
  }
  rows.sort((x, y) => (x.group - y.group) || (x.order - y.order) || (y.at - x.at));
  const out = [];
  let last = null;
  for (const r of rows) {
    if (r.group !== last) {
      last = r.group;
      if (r.group === BRIEF_GROUP) { out.push(r); continue; }
      const n = rows.filter((x) => x.group === r.group).length;
      out.push({ key: "h:" + r.group, kind: "header", label: r.group === PLAN_GROUP ? "TODO" : r.group === COLLAB_GROUP ? "Collab" : r.group === STALE_GROUP ? "정리 후보 · /done" : GROUPS[r.group], count: n, group: r.group });
    }
    out.push(r);
  }
  return out;
});

function jump(row) {
  // 이미 그 워크스페이스에 있으면 select 를 생략한다(불필요한 포커스 이벤트를 만들지 않게).
  if (!row.wsSelected) cmux("workspace.select", { workspace_id: row.wsId });
  if (row.surfaceId) cmux("surface.focus", { surface_id: row.surfaceId, workspace_id: row.wsId });
}

function headerRow(e) {
  return HStack({ spacing: 6 }, [
    Text(() => e().label)
      .font(11).weight("semibold")
      .color(() => (e().group === 0 ? "#FF9F0A" : e().group === PLAN_GROUP ? "accent" : "secondary")),
    Text(() => String(e().count)).font(10).monospaced().color("tertiary"),
    Spacer(),
  ]).paddingHorizontal(10).paddingTop(8).paddingBottom(2);
}

function agentRow(e) {
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Circle({ size: 6 }).fill(() => (e().unread ? COLOR.needs_input : COLOR[e().status] ?? "#7f7f7f66")),
      Text(() => (e().num ? e().num + " " : "") + e().title)
        .font(12).weight("medium").lineLimit(1).truncation("tail")
        .color(() => (e().status === "ended" || e().group === 4 || e().group === STALE_GROUP ? "secondary" : "primary")),
      Spacer(),
      Text(() => (e().status === "working" ? "" : fmtAgo((data.clock()?.epoch ?? 0) - e().at)))
        .font(10).monospaced().color("tertiary").layoutPriority(2),
    ]),
    Text(() => e().todo || e().sub)
      .font(10).color(() => (e().todo ? "secondary" : "tertiary"))
      .lineLimit(() => (e().todo ? 3 : e().recap ? 3 : 1)).truncation("tail")
      .paddingLeading(12),
  ])
    .paddingHorizontal(10).paddingVertical(5)
    .cornerRadius(8)
    .background(() => (e().here ? "#7f7f7f2e" : null))
    .hoverBackground("#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .cursor("pointer")
    .contextMenu([
      Button("Go", () => jump(e())),
      Button("Ping (flash only)", () => cmux("surface.trigger_flash", { surface_id: e().surfaceId, workspace_id: e().wsId })),
    ])
    .onTap(() => jump(e()));
}

sidebar(() =>
  VStack({ spacing: 4 }, [
    HStack({ spacing: 6 }, [
      Text("Sessions").font(14).weight("semibold"),
      Spacer(),
      Text(() => {
        const rows = entries().filter((x) => x.kind === "agent");
        const mine = rows.filter((x) => x.group === 0).length;
        const run = rows.filter((x) => x.group === 1).length;
        const stale = rows.filter((x) => x.group === STALE_GROUP).length;
        return (mine ? mine + " waiting · " : "") + (run ? run + " running · " : "") + (stale ? stale + " to close · " : "") + rows.length + " sessions";
      }).font(10).monospaced().color("tertiary"),
    ]).paddingHorizontal(10),

    TextField("", {
      placeholder: "Search title, prompt, dir",
      autofocus: false,
      onEdit: (t) => setQuery(t ?? ""),
      onSubmit: (t) => setQuery(t ?? ""),
    }).paddingHorizontal(10),

    ForEach(
      { items: entries, key: (e) => e.key },
      (e) => (e().kind === "header" ? headerRow(e) : agentRow(e))
    ),

    Text(() => (entries().length === 0 ? (query().trim() ? "No matches" : "No agent sessions") : ""))
      .font(11).color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
