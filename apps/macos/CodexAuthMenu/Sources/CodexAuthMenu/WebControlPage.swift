import Foundation

enum WebControlPage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex 账号</title>
  <link rel="icon" href="/favicon.ico">
  <style>
    :root {
      color-scheme: light;
      --page: #f6f1e8;
      --surface: #fbfaf6;
      --surface-soft: #f1ece2;
      --line: #d9d1c4;
      --line-strong: #c7bcad;
      --ink: #2f2a24;
      --ink-soft: #4d463d;
      --muted: #746d63;
      --muted-soft: #9a9287;
      --clay: #8b5438;
      --clay-soft: rgba(139, 84, 56, 0.1);
      --olive: #536a56;
      --olive-soft: rgba(83, 106, 86, 0.12);
      --steel: #536576;
      --steel-soft: rgba(83, 101, 118, 0.12);
      --danger: #9c3f36;
      --danger-soft: rgba(156, 63, 54, 0.1);
      --focus: rgba(139, 84, 56, 0.18);
    }

    * {
      box-sizing: border-box;
      letter-spacing: 0;
    }

    html,
    body {
      min-height: 100%;
    }

    body {
      background:
        radial-gradient(rgba(47, 42, 36, 0.045) 0.6px, transparent 0.7px),
        linear-gradient(180deg, #f8f4ec 0%, var(--page) 52%, #f1eadf 100%);
      background-size: 18px 18px, auto;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
      font-size: 15px;
      line-height: 1.6;
      margin: 0;
      overflow-x: hidden;
    }

    img {
      display: block;
      max-width: 100%;
    }

    button,
    input {
      font: inherit;
    }

    button {
      color: inherit;
    }

    .page {
      margin: 0 auto;
      max-width: 1320px;
      padding: 34px 28px 44px;
    }

    .masthead {
      align-items: end;
      border-bottom: 1px solid var(--line);
      display: grid;
      gap: 28px;
      grid-template-columns: minmax(0, 1fr) minmax(280px, 420px);
      padding-bottom: 28px;
    }

    .identity {
      align-items: flex-start;
      display: flex;
      gap: 18px;
      min-width: 0;
    }

    .brand-icon {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 7px;
      flex: 0 0 auto;
      height: 54px;
      padding: 5px;
      width: 54px;
    }

    .title-stack {
      min-width: 0;
    }

    .kicker-row {
      align-items: center;
      color: var(--muted);
      display: flex;
      flex-wrap: wrap;
      font-size: 13px;
      gap: 10px;
      margin-bottom: 6px;
    }

    .source-chip,
    .status-chip,
    .pill {
      align-items: center;
      border: 1px solid var(--line);
      border-radius: 6px;
      display: inline-flex;
      font-size: 12px;
      font-weight: 650;
      line-height: 1;
      min-height: 28px;
      padding: 0 9px;
      white-space: nowrap;
    }

    .source-chip {
      background: var(--surface);
      color: var(--clay);
    }

    h1,
    h2,
    h3,
    p {
      margin: 0;
    }

    h1 {
      color: var(--ink);
      font-family: "Iowan Old Style", "Source Serif 4", "Palatino Linotype", Georgia, serif;
      font-size: 46px;
      font-weight: 600;
      line-height: 1.02;
      overflow-wrap: anywhere;
    }

    .active-line {
      color: var(--ink-soft);
      font-size: 18px;
      margin-top: 10px;
      overflow-wrap: anywhere;
    }

    .masthead-note {
      color: var(--muted);
      font-size: 15px;
      line-height: 1.7;
      overflow-wrap: anywhere;
    }

    .layout {
      align-items: start;
      display: grid;
      gap: 34px;
      grid-template-columns: minmax(0, 1fr) minmax(300px, 360px);
      padding-top: 30px;
    }

    .accounts-pane {
      min-width: 0;
    }

    .pane-head {
      align-items: end;
      display: grid;
      gap: 20px;
      grid-template-columns: minmax(0, 1fr) minmax(260px, 340px);
      margin-bottom: 22px;
    }

    .section-kicker {
      color: var(--clay);
      font-size: 13px;
      font-weight: 650;
      margin-bottom: 6px;
    }

    .pane-title {
      font-family: "Iowan Old Style", "Source Serif 4", "Palatino Linotype", Georgia, serif;
      font-size: 31px;
      font-weight: 600;
      line-height: 1.12;
    }

    .section-note {
      color: var(--muted);
      line-height: 1.7;
    }

    .search-wrap {
      position: relative;
    }

    .search-wrap::before {
      color: var(--muted-soft);
      content: "⌕";
      font-size: 17px;
      left: 14px;
      position: absolute;
      top: 50%;
      transform: translateY(-50%);
    }

    .search-input {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 7px;
      color: var(--ink);
      min-height: 46px;
      outline: none;
      padding: 0 14px 0 42px;
      width: 100%;
    }

    .search-input::placeholder {
      color: var(--muted-soft);
    }

    .search-input:focus,
    .button:focus-visible,
    .toggle:focus-within .toggle-track {
      border-color: var(--clay);
      box-shadow: 0 0 0 4px var(--focus);
    }

    .accounts {
      border-top: 1px solid var(--line);
      display: grid;
    }

    .account-card {
      align-items: start;
      border-bottom: 1px solid var(--line);
      display: grid;
      gap: 22px;
      grid-template-columns: minmax(0, 1.1fr) minmax(230px, 320px) minmax(170px, 190px);
      min-height: 154px;
      padding: 22px 0;
    }

    .account-card.active {
      background: rgba(83, 106, 86, 0.055);
      border: 1px solid rgba(83, 106, 86, 0.24);
      border-radius: 8px;
      margin: 12px 0;
      padding: 22px 16px;
    }

    .account-header {
      display: grid;
      gap: 12px;
      min-width: 0;
    }

    .account-title {
      color: var(--ink);
      font-size: 22px;
      font-weight: 700;
      line-height: 1.18;
      overflow-wrap: anywhere;
    }

    .account-subtitle {
      color: var(--muted);
      line-height: 1.45;
      overflow-wrap: anywhere;
    }

    .pill-row {
      display: flex;
      flex-wrap: wrap;
      gap: 7px;
    }

    .pill.active {
      background: var(--olive-soft);
      border-color: rgba(83, 106, 86, 0.24);
      color: var(--olive);
    }

    .pill.plan {
      background: var(--clay-soft);
      border-color: rgba(139, 84, 56, 0.2);
      color: var(--clay);
    }

    .pill.mode {
      background: var(--surface-soft);
      color: var(--muted);
    }

    .usage-grid {
      display: grid;
      gap: 14px;
    }

    .usage-block {
      display: grid;
      gap: 8px;
    }

    .usage-top {
      align-items: baseline;
      display: flex;
      font-size: 13px;
      font-weight: 650;
      justify-content: space-between;
      line-height: 1.25;
    }

    .usage-value {
      color: var(--muted);
      margin-left: 12px;
      text-align: right;
      white-space: nowrap;
    }

    .meter {
      background: rgba(47, 42, 36, 0.09);
      border-radius: 3px;
      height: 7px;
      overflow: hidden;
    }

    .meter-fill {
      border-radius: 3px;
      height: 100%;
      min-width: 8px;
    }

    .meter-fill.green {
      background: var(--olive);
    }

    .meter-fill.blue {
      background: var(--steel);
    }

    .account-foot {
      align-items: end;
      display: grid;
      gap: 14px;
      min-width: 0;
    }

    .account-meta {
      color: var(--muted);
      display: grid;
      font-size: 12px;
      gap: 5px;
      line-height: 1.45;
      overflow-wrap: anywhere;
    }

    .account-action {
      justify-self: stretch;
      min-width: 0;
    }

    .renewal-row {
      border-top: 1px solid var(--line);
      display: grid;
      gap: 12px;
      grid-column: 1 / -1;
      margin-top: 2px;
      padding-top: 14px;
    }

    .renewal-summary {
      color: var(--muted);
      display: grid;
      font-size: 12px;
      gap: 4px;
      line-height: 1.55;
    }

    .renewal-summary.warning {
      color: var(--clay);
    }

    .renewal-summary.error {
      color: var(--danger);
    }

    .renewal-tools {
      display: grid;
      gap: 8px;
      grid-template-columns: minmax(0, 1fr) repeat(2, auto);
    }

    .renewal-input {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 6px;
      color: var(--ink);
      min-height: 40px;
      outline: none;
      padding: 0 12px;
      width: 100%;
    }

    .renewal-input:focus {
      border-color: var(--clay);
      box-shadow: 0 0 0 4px var(--focus);
    }

    .side-rail {
      display: grid;
      gap: 14px;
      position: sticky;
      top: 22px;
    }

    .panel {
      background: rgba(251, 250, 246, 0.82);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
    }

    .panel-title {
      color: var(--ink);
      font-size: 17px;
      font-weight: 700;
      margin-bottom: 8px;
    }

    .panel-copy,
    .preference-note,
    .health-line {
      color: var(--muted);
      font-size: 13px;
      line-height: 1.65;
      overflow-wrap: anywhere;
    }

    .panel-copy + .panel-copy {
      margin-top: 10px;
    }

    .status-panel {
      display: grid;
      gap: 14px;
    }

    .status-head {
      align-items: center;
      display: flex;
      gap: 10px;
      justify-content: space-between;
    }

    .status-chip {
      background: var(--surface-soft);
      color: var(--muted);
    }

    .status-chip.success {
      background: var(--olive-soft);
      border-color: rgba(83, 106, 86, 0.24);
      color: var(--olive);
    }

    .status-chip.error {
      background: var(--danger-soft);
      border-color: rgba(156, 63, 54, 0.24);
      color: var(--danger);
    }

    .status-chip.warning {
      background: rgba(139, 84, 56, 0.1);
      border-color: rgba(139, 84, 56, 0.22);
      color: var(--clay);
    }

    .status-copy {
      color: var(--ink-soft);
      min-height: 48px;
      overflow-wrap: anywhere;
    }

    .status-metrics {
      border-top: 1px solid var(--line);
      display: grid;
      gap: 0;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      padding-top: 12px;
    }

    .metric {
      min-height: 64px;
    }

    .metric + .metric {
      border-left: 1px solid var(--line);
      padding-left: 14px;
    }

    .metric-value {
      color: var(--ink);
      display: block;
      font-family: "Iowan Old Style", "Source Serif 4", "Palatino Linotype", Georgia, serif;
      font-size: 28px;
      font-weight: 600;
      line-height: 1;
      margin-bottom: 7px;
    }

    .metric-label {
      color: var(--muted);
      display: block;
      font-size: 12px;
    }

    .health-line {
      border-top: 1px solid var(--line);
      padding-top: 12px;
    }

    .button-row {
      display: grid;
      gap: 9px;
    }

    .panel .button-row {
      margin-top: 12px;
    }

    .button {
      align-items: center;
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 6px;
      color: var(--ink);
      cursor: pointer;
      display: inline-flex;
      font-weight: 650;
      justify-content: center;
      min-height: 40px;
      min-width: 112px;
      outline: none;
      padding: 0 14px;
      text-align: center;
      text-decoration: none;
      transition: background-color 140ms ease, border-color 140ms ease, color 140ms ease;
      white-space: nowrap;
    }

    .button:hover:not(:disabled) {
      background: #f5efe5;
      border-color: var(--line-strong);
    }

    .button:disabled {
      cursor: default;
      opacity: 0.52;
    }

    .button.primary {
      background: var(--ink);
      border-color: var(--ink);
      color: #fffaf1;
    }

    .button.primary:hover:not(:disabled) {
      background: #1f1b17;
      border-color: #1f1b17;
    }

    .toggle {
      align-items: center;
      cursor: pointer;
      display: flex;
      gap: 12px;
      justify-content: space-between;
      margin-top: 12px;
      user-select: none;
    }

    .toggle input {
      opacity: 0;
      pointer-events: none;
      position: absolute;
    }

    .toggle-track {
      background: var(--surface-soft);
      border: 1px solid var(--line);
      border-radius: 8px;
      flex: 0 0 auto;
      height: 28px;
      position: relative;
      transition: background-color 140ms ease, border-color 140ms ease;
      width: 50px;
    }

    .toggle-thumb {
      background: var(--surface);
      border: 1px solid var(--line-strong);
      border-radius: 6px;
      height: 22px;
      left: 2px;
      position: absolute;
      top: 2px;
      transition: transform 140ms ease;
      width: 22px;
    }

    .toggle input:checked + .toggle-track {
      background: var(--olive-soft);
      border-color: rgba(83, 106, 86, 0.38);
    }

    .toggle input:checked + .toggle-track .toggle-thumb {
      transform: translateX(22px);
    }

    .toggle input:disabled + .toggle-track {
      opacity: 0.56;
    }

    .toggle-copy {
      color: var(--ink-soft);
      font-weight: 650;
    }

    .empty-state {
      align-items: center;
      border-bottom: 1px solid var(--line);
      color: var(--muted);
      display: grid;
      min-height: 220px;
      padding: 36px 18px;
      place-items: center;
      text-align: center;
    }

    @media (max-width: 1040px) {
      .masthead,
      .layout,
      .pane-head {
        grid-template-columns: 1fr;
      }

      .side-rail {
        position: static;
      }

      .account-card {
        grid-template-columns: minmax(0, 1fr) minmax(220px, 300px);
      }

      .account-foot {
        grid-column: 1 / -1;
        grid-template-columns: minmax(0, 1fr) minmax(140px, 180px);
      }
    }

    @media (max-width: 720px) {
      .page {
        padding: 24px 16px 32px;
      }

      .identity {
        display: grid;
        gap: 14px;
      }

      h1 {
        font-size: 37px;
      }

      .pane-title {
        font-size: 27px;
      }

      .account-card,
      .account-card.active {
        grid-template-columns: 1fr;
        margin-left: 0;
        margin-right: 0;
      }

      .account-foot {
        grid-column: auto;
        grid-template-columns: 1fr;
      }

      .renewal-tools {
        grid-template-columns: 1fr 1fr;
      }
    }

    @media (max-width: 480px) {
      h1 {
        font-size: 32px;
      }

      .active-line {
        font-size: 16px;
      }

      .status-metrics {
        grid-template-columns: 1fr;
      }

      .metric + .metric {
        border-left: 0;
        border-top: 1px solid var(--line);
        padding-left: 0;
        padding-top: 12px;
      }

      .renewal-tools {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <div class="page">
    <header class="masthead">
      <section class="identity" aria-label="控制台状态">
        <img class="brand-icon" id="brandIcon" alt="Codex 账号" src="">
        <div class="title-stack">
          <div class="kicker-row">
            <span>本地控制台</span>
            <span class="source-chip" id="sourceChip">本地额度</span>
          </div>
          <h1>Codex 账号</h1>
          <p class="active-line" id="activeLine">正在同步账号状态</p>
        </div>
      </section>
      <p class="masthead-note" id="metaLine">本地模式下，额度来自最近使用记录，可能会延迟。</p>
    </header>

    <main class="layout">
      <section class="accounts-pane" aria-label="账号列表">
        <div class="pane-head">
          <div>
            <p class="section-kicker">账号</p>
            <h2 class="pane-title">切换账号这件小事，应该像翻到下一页一样顺手。</h2>
          </div>
          <div class="search-wrap">
            <input
              class="search-input"
              id="search"
              type="search"
              autocomplete="off"
              placeholder="搜索邮箱、别名、账号名称或套餐"
            >
          </div>
        </div>

        <section class="accounts" id="accounts" aria-live="polite"></section>
      </section>

      <aside class="side-rail" aria-label="操作">
        <section class="panel status-panel">
          <div class="status-head">
            <h2 class="panel-title">近期操作</h2>
            <span class="status-chip" id="statusChip">本地模式</span>
          </div>
          <div class="status-copy" id="status" aria-live="polite">正在加载</div>
          <div class="status-metrics">
            <div class="metric">
              <span class="metric-value" id="accountCount">0</span>
              <span class="metric-label">已保存账号</span>
            </div>
            <div class="metric">
              <span class="metric-value" id="modeValue">本地</span>
              <span class="metric-label">额度来源</span>
            </div>
          </div>
          <div class="health-line" id="healthLine">正在读取 Codex CLI 信息</div>
        </section>

        <section class="panel">
          <h2 class="panel-title">首次使用</h2>
          <p class="panel-copy">这个 App 已经内置 codex-auth。已有 auth.json、账号快照或 CPA 文件时，可以直接导入开始使用。</p>
          <p class="panel-copy">如果是第一次登录新账号，机器上仍需要官方 Codex CLI；这里的登录动作会在终端里调用 <code>codex login</code>。</p>
        </section>

        <section class="panel">
          <h2 class="panel-title">常用</h2>
          <p class="panel-copy">只处理你明确点下去的动作。</p>
          <div class="button-row">
            <button class="button primary" id="refreshCurrent">同步当前额度</button>
            <button class="button secondary" id="refreshAll">刷新全部额度</button>
            <button class="button secondary" id="reload">重新加载</button>
            <button class="button secondary" id="addAccount">账号登录</button>
            <button class="button secondary" id="deviceAuth">设备码登录</button>
          </div>
        </section>

        <section class="panel">
          <h2 class="panel-title">风险开关</h2>
          <p class="panel-copy" id="apiConfigNote">默认全部关闭；只有你主动开启时，才会对更多账号调用相关接口。</p>
          <label class="toggle">
            <span class="toggle-copy" id="usageApiLabel">额度 / 账号 API：读取中</span>
            <input id="usageApiToggle" type="checkbox">
            <span class="toggle-track">
              <span class="toggle-thumb"></span>
            </span>
          </label>
        </section>

        <section class="panel">
          <h2 class="panel-title">导入已有账号</h2>
          <p class="panel-copy">适合 auth.json 快照、CPA 文件，或者直接扫描默认 CPA 目录。</p>
          <div class="button-row">
            <button class="button secondary" id="importAuth">导入 auth.json / 文件夹</button>
            <button class="button secondary" id="importCPA">导入 CPA 文件 / 目录</button>
            <button class="button secondary" id="scanCPA">扫描默认 CPA 目录</button>
          </div>
        </section>

        <section class="panel">
          <h2 class="panel-title">切换之后</h2>
          <p class="preference-note" id="preferenceNote">官方 Codex App 会尽快跟上新账号；终端里的 Codex CLI 会话仍需重新进入。</p>
          <label class="toggle">
            <span class="toggle-copy" id="toggleLabel">正在读取</span>
            <input id="restartToggle" type="checkbox">
            <span class="toggle-track">
              <span class="toggle-thumb"></span>
            </span>
          </label>
        </section>
      </aside>
    </main>
  </div>

  <script>
    const token = new URLSearchParams(location.search).get("token") || "";
    const state = {
      accounts: [],
      api: null,
      query: "",
      busy: false,
      preferenceBusy: false,
      apiBusy: false,
      restartCodexAfterSwitch: true
    };

    const brandIconEl = document.getElementById("brandIcon");
    const activeLineEl = document.getElementById("activeLine");
    const metaLineEl = document.getElementById("metaLine");
    const healthLineEl = document.getElementById("healthLine");
    const statusChipEl = document.getElementById("statusChip");
    const statusEl = document.getElementById("status");
    const accountsEl = document.getElementById("accounts");
    const searchEl = document.getElementById("search");
    const addAccountEl = document.getElementById("addAccount");
    const deviceAuthEl = document.getElementById("deviceAuth");
    const importAuthEl = document.getElementById("importAuth");
    const importCPAEl = document.getElementById("importCPA");
    const scanCPAEl = document.getElementById("scanCPA");
    const reloadEl = document.getElementById("reload");
    const refreshCurrentEl = document.getElementById("refreshCurrent");
    const refreshAllEl = document.getElementById("refreshAll");
    const restartToggleEl = document.getElementById("restartToggle");
    const toggleLabelEl = document.getElementById("toggleLabel");
    const preferenceNoteEl = document.getElementById("preferenceNote");
    const accountCountEl = document.getElementById("accountCount");
    const modeValueEl = document.getElementById("modeValue");
    const sourceChipEl = document.getElementById("sourceChip");
    const usageApiToggleEl = document.getElementById("usageApiToggle");
    const usageApiLabelEl = document.getElementById("usageApiLabel");
    const apiConfigNoteEl = document.getElementById("apiConfigNote");

    brandIconEl.src = `/app-icon.png?token=${encodeURIComponent(token)}`;

    function setStatus(text, tone = "neutral") {
      statusEl.textContent = text;
      statusChipEl.textContent =
        tone === "success" ? "同步完成" :
        tone === "error" ? "需要处理" :
        tone === "warning" ? "请留意" :
        "本地模式";
      statusChipEl.className = `status-chip${tone === "neutral" ? "" : ` ${tone}`}`;
    }

    function syncControls() {
      const disabled = state.busy;
      addAccountEl.disabled = disabled;
      deviceAuthEl.disabled = disabled;
      importAuthEl.disabled = disabled;
      importCPAEl.disabled = disabled;
      scanCPAEl.disabled = disabled;
      reloadEl.disabled = disabled;
      refreshCurrentEl.disabled = disabled;
      refreshAllEl.disabled = disabled || !state.api || state.api.usage !== true;
      restartToggleEl.disabled = disabled || state.preferenceBusy;
      usageApiToggleEl.disabled = disabled || state.apiBusy;
    }

    async function api(path, options = {}) {
      const headers = Object.assign({ "X-Codex-Auth-Token": token }, options.headers || {});
      const response = await fetch(path, Object.assign({}, options, { headers }));
      const text = await response.text();
      let payload = null;

      if (text) {
        try {
          payload = JSON.parse(text);
        } catch {
          payload = null;
        }
      }

      if (!response.ok) {
        throw new Error(payload && payload.error ? payload.error : response.statusText);
      }

      return { payload, response };
    }

    function accountMatches(account) {
      const query = state.query.trim().toLowerCase();
      if (!query) return true;
      return [account.label, account.email, account.alias, account.account_name, account.plan, account.auth_mode]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(query));
    }

    function compareAccounts(left, right) {
      if (!!left.active !== !!right.active) {
        return left.active ? -1 : 1;
      }
      const leftLastUsed = left.last_used_at || 0;
      const rightLastUsed = right.last_used_at || 0;
      if (leftLastUsed !== rightLastUsed) {
        return rightLastUsed - leftLastUsed;
      }
      return String(left.label || "").localeCompare(String(right.label || ""), "zh-CN");
    }

    function formatDate(timestamp) {
      if (!timestamp) return "时间未知";
      try {
        return new Intl.DateTimeFormat("zh-CN", {
          month: "numeric",
          day: "numeric",
          hour: "2-digit",
          minute: "2-digit"
        }).format(new Date(timestamp * 1000));
      } catch {
        return "时间未知";
      }
    }

    function usageStatusPresentation(status) {
      if (status === "NodeJsRequired") {
        return {
          shortLabel: "需要 Node",
          summary: "需要本机 Node.js 18+",
          detail: "额度刷新依赖本机 Node.js 18+ 运行环境。重新打开 App 后会自动重试。"
        };
      }
      if (status === "MissingAuth") {
        return {
          shortLabel: "不支持",
          summary: "当前登录态不支持额度接口",
          detail: "这个账号当前没有可用的 ChatGPT 额度接口凭证。"
        };
      }
      if (status === "TimedOut") {
        return {
          shortLabel: "超时",
          summary: "额度接口请求超时",
          detail: "这次刷新超时了，稍后重试通常就够了。"
        };
      }
      if (/^\d+$/.test(String(status || ""))) {
        return {
          shortLabel: String(status),
          summary: `额度接口返回 ${status}`,
          detail: `接口返回了 ${status} 状态，暂时没拿到新的额度结果。`
        };
      }
      return {
        shortLabel: "失败",
        summary: "额度刷新失败",
        detail: `接口返回了 ${status}，这次没有拿到新的额度结果。`
      };
    }

    function usageSummary(account) {
      if (!account.usage) {
        return {
          fiveHourLabel: "等待同步",
          weeklyLabel: "等待同步",
          fiveHourPercent: 4,
          weeklyPercent: 4,
          detail: "还没有额度同步记录。"
        };
      }
      if (account.usage.status && account.usage.status !== "ok") {
        const presentation = usageStatusPresentation(account.usage.status);
        return {
          fiveHourLabel: presentation.shortLabel,
          weeklyLabel: presentation.shortLabel,
          fiveHourPercent: 8,
          weeklyPercent: 8,
          detail: presentation.detail
        };
      }
      const fiveHourRemaining = account.usage.five_hour && account.usage.five_hour.remaining_percent !== null
        ? account.usage.five_hour.remaining_percent
        : null;
      const weeklyRemaining = account.usage.weekly && account.usage.weekly.remaining_percent !== null
        ? account.usage.weekly.remaining_percent
        : null;
      return {
        fiveHourLabel: fiveHourRemaining === null ? "--" : `${fiveHourRemaining}%`,
        weeklyLabel: weeklyRemaining === null ? "--" : `${weeklyRemaining}%`,
        fiveHourPercent: fiveHourRemaining === null ? 4 : Math.max(4, Math.min(100, fiveHourRemaining)),
        weeklyPercent: weeklyRemaining === null ? 4 : Math.max(4, Math.min(100, weeklyRemaining)),
        detail: null
      };
    }

    function syncLine(account) {
      if (account && account.usage && account.usage.status && account.usage.status !== "ok") {
        return usageStatusPresentation(account.usage.status).summary;
      }
      if (!account || !account.last_usage_at) {
        return "本地额度还没同步到这张卡片。";
      }
      return `本地额度同步于：${formatDate(account.last_usage_at)}`;
    }

    function switchMessage(result) {
      switch (result) {
        case "restarted":
          return "已切换，并已自动重启 Codex App。终端里的 Codex CLI 会话仍需手动重新进入。";
        case "not_running":
          return "已切换。Codex App 当前未打开，下次启动时会使用新账号；终端里的 Codex CLI 会话仍需手动重新进入。";
        case "not_installed":
          return "已切换，但未找到 Codex App；终端里的 Codex CLI 会话仍需手动重新进入。";
        case "failed":
          return "已切换，但自动重启 Codex App 失败；终端里的 Codex CLI 会话仍需手动重新进入。";
        default:
          return "已切换。当前未开启自动重启 Codex App；终端里的 Codex CLI 会话仍需手动重新进入。";
      }
    }

    function renderMetaLine(active) {
      const usageMode = state.api && state.api.usage ? "API" : "本地";
      if (!active) {
        metaLineEl.textContent = `${usageMode} 模式 · 续费日使用手动记录和提醒。先添加一个账号，我们就能开始切换。`;
        return;
      }
      const plan = active.plan || "未知套餐";
      const alias = active.alias ? ` · ${active.alias}` : "";
      metaLineEl.textContent = `${active.email}${alias} · ${plan} · 当前额度来源：${usageMode} · 手动续费提醒`;
    }

    function renderPreferences() {
      restartToggleEl.checked = state.restartCodexAfterSwitch;
      toggleLabelEl.textContent = state.restartCodexAfterSwitch ? "已开启" : "已关闭";
      preferenceNoteEl.textContent = state.restartCodexAfterSwitch
        ? "官方 Codex App 会尽快跟上新账号；终端里的 Codex CLI 会话仍需重新进入。"
        : "切换后只更新登录态，你可以自己决定什么时候重新打开 Codex。";
    }

    function renderAPIConfig() {
      const api = state.api || { usage: false };
      usageApiToggleEl.checked = !!api.usage;
      usageApiLabelEl.textContent = `额度 / 账号 API：${api.usage ? "已开启" : "已关闭"}`;
      apiConfigNoteEl.textContent = api.usage
        ? "已允许刷新全部账号额度和账号名接口。关闭后，全部额度刷新会被禁用。"
        : "默认只保留本地同步；续费日只做手动记录和到期提醒。";
    }

    function renderStatusMetrics() {
      accountCountEl.textContent = String(state.accounts.length);
      const localMode = !state.api || state.api.usage === false;
      modeValueEl.textContent = localMode ? "本地" : "API";
      sourceChipEl.textContent = localMode ? "本地额度" : "API 额度";
    }

    function daysUntil(dateString) {
      if (!dateString) return null;
      const target = new Date(`${dateString}T00:00:00`);
      if (Number.isNaN(target.getTime())) return null;
      const today = new Date();
      const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate());
      return Math.round((target.getTime() - startOfToday.getTime()) / 86400000);
    }

    function renewalSummary(account) {
      const renewal = account.renewal || { status: "missing" };
      const date = renewal.next_renewal_at;
      const days = daysUntil(date);
      const updated = renewal.updated_at ? `更新于：${formatDate(renewal.updated_at)}` : "还没有续费记录。";

      if (date) {
        let detail = updated;
        let tone = "neutral";
        if (days !== null && days < 0) {
          detail = `已过期 ${Math.abs(days)} 天，请确认是否已经续费。`;
          tone = "error";
        } else if (days !== null && days <= 7) {
          detail = `还有 ${days} 天到期，记得提前处理。`;
          tone = "warning";
        }
        return {
          title: `下次续费：${date}`,
          detail,
          tone,
          inputValue: date
        };
      }
      return {
        title: "下次续费：未设置",
        detail: "手动记录一个日期后，我们会在 7 天内高亮提醒。",
        tone: "neutral",
        inputValue: ""
      };
    }

    function renderAccounts() {
      accountsEl.replaceChildren();
      const filtered = state.accounts.slice().sort(compareAccounts).filter(accountMatches);
      if (filtered.length === 0) {
        const empty = document.createElement("div");
        empty.className = "empty-state";
        empty.textContent = state.accounts.length === 0
          ? "先添加一个账号，我们就可以在这里管理它。"
          : "没有找到匹配的账号。";
        accountsEl.appendChild(empty);
        return;
      }

      for (const account of filtered) {
        const tile = document.createElement("article");
        tile.className = `account-card${account.active ? " active" : ""}`;

        const header = document.createElement("div");
        header.className = "account-header";

        const titleWrap = document.createElement("div");
        const title = document.createElement("h2");
        title.className = "account-title";
        title.textContent = account.label;
        const subtitle = document.createElement("div");
        subtitle.className = "account-subtitle";
        const plan = account.plan || "未知套餐";
        subtitle.textContent = account.alias
          ? `${account.email} · ${account.alias} · ${plan}`
          : `${account.email} · ${plan}`;
        titleWrap.append(title, subtitle);

        const pills = document.createElement("div");
        pills.className = "pill-row";
        if (account.active) {
          const activePill = document.createElement("span");
          activePill.className = "pill active";
          activePill.textContent = "当前";
          pills.appendChild(activePill);
        }
        if (account.plan) {
          const planPill = document.createElement("span");
          planPill.className = "pill plan";
          planPill.textContent = account.plan;
          pills.appendChild(planPill);
        }
        if (account.auth_mode) {
          const modePill = document.createElement("span");
          modePill.className = "pill mode";
          modePill.textContent = account.auth_mode;
          pills.appendChild(modePill);
        }

        header.append(titleWrap, pills);

        const usage = usageSummary(account);
        const usageGrid = document.createElement("div");
        usageGrid.className = "usage-grid";
        usageGrid.append(
          createUsageBlock("5 小时剩余", usage.fiveHourLabel, usage.fiveHourPercent, "green"),
          createUsageBlock("每周剩余", usage.weeklyLabel, usage.weeklyPercent, "blue")
        );

        const foot = document.createElement("div");
        foot.className = "account-foot";

        const meta = document.createElement("div");
        meta.className = "account-meta";

        const sync = document.createElement("div");
        sync.className = "account-sync";
        sync.textContent = syncLine(account);

        const time = document.createElement("div");
        time.className = "account-time";
        time.textContent = `最近使用：${formatDate(account.last_used_at)}`;

        const renewal = renewalSummary(account);
        const renewalMeta = document.createElement("div");
        renewalMeta.textContent = renewal.title;

        const renewalDetail = document.createElement("div");
        renewalDetail.textContent = renewal.detail;

        meta.append(sync, time, renewalMeta, renewalDetail);

        const action = document.createElement("button");
        action.className = `button ${account.active ? "secondary" : "primary"} account-action`;
        action.textContent = account.active ? "已选中" : "切换";
        action.disabled = account.active || state.busy;
        action.addEventListener("click", () => switchAccount(account.account_key));
        foot.append(meta, action);

        const renewalRow = document.createElement("div");
        renewalRow.className = "renewal-row";

        const renewalSummaryEl = document.createElement("div");
        renewalSummaryEl.className = `renewal-summary${renewal.tone === "neutral" ? "" : ` ${renewal.tone}`}`;
        const renewalTitle = document.createElement("div");
        renewalTitle.textContent = renewal.title;
        const renewalCopy = document.createElement("div");
        renewalCopy.textContent = renewal.detail;
        renewalSummaryEl.append(renewalTitle, renewalCopy);

        const renewalTools = document.createElement("div");
        renewalTools.className = "renewal-tools";
        const renewalInput = document.createElement("input");
        renewalInput.className = "renewal-input";
        renewalInput.type = "date";
        renewalInput.value = renewal.inputValue;
        renewalInput.disabled = state.busy;

        const saveButton = document.createElement("button");
        saveButton.className = "button secondary";
        saveButton.textContent = "保存";
        saveButton.disabled = state.busy;
        saveButton.addEventListener("click", () => setRenewal(account.account_key, renewalInput.value));

        const clearButton = document.createElement("button");
        clearButton.className = "button secondary";
        clearButton.textContent = "清除";
        clearButton.disabled = state.busy;
        clearButton.addEventListener("click", () => clearRenewal(account.account_key));

        renewalTools.append(renewalInput, saveButton, clearButton);
        renewalRow.append(renewalSummaryEl, renewalTools);

        tile.append(header, usageGrid, foot, renewalRow);
        accountsEl.appendChild(tile);
      }
    }

    function createUsageBlock(label, value, percent, tone) {
      const block = document.createElement("div");
      block.className = "usage-block";

      const top = document.createElement("div");
      top.className = "usage-top";
      const name = document.createElement("span");
      name.textContent = label;
      const amount = document.createElement("span");
      amount.className = "usage-value";
      amount.textContent = value;
      top.append(name, amount);

      const meter = document.createElement("div");
      meter.className = "meter";
      const fill = document.createElement("div");
      fill.className = `meter-fill ${tone}`;
      fill.style.width = `${percent}%`;
      meter.appendChild(fill);

      block.append(top, meter);
      return block;
    }

    function render(payload = null) {
      if (payload && Array.isArray(payload.accounts)) {
        state.accounts = payload.accounts;
      }
      if (payload && payload.api) {
        state.api = payload.api;
      }

      const active = state.accounts.find((account) => account.active);
      activeLineEl.textContent = active ? `当前账号：${active.label}` : "同步本地状态，然后切换到下一个账号。";
      renderMetaLine(active);
      renderPreferences();
      renderAPIConfig();
      renderStatusMetrics();
      renderAccounts();
      syncControls();
    }

    async function loadHealth() {
      try {
        const { payload } = await api("/api/health");
        if (!payload) return;
        healthLineEl.textContent = `${payload.version || "Codex CLI"} · ${payload.cli_path || "未找到 codex-auth"}`;
      } catch (error) {
        healthLineEl.textContent = error.message || "无法读取 Codex CLI 信息";
      }
    }

    async function loadPreferences() {
      state.preferenceBusy = true;
      syncControls();
      try {
        const { payload } = await api("/api/preferences");
        state.restartCodexAfterSwitch = !!(payload && payload.restart_codex_after_switch);
        renderPreferences();
      } catch (error) {
        setStatus(error.message || "读取偏好失败", "error");
      } finally {
        state.preferenceBusy = false;
        syncControls();
      }
    }

    async function savePreferences(enabled) {
      state.preferenceBusy = true;
      state.restartCodexAfterSwitch = enabled;
      renderPreferences();
      syncControls();
      try {
        const { payload } = await api("/api/preferences", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ restart_codex_after_switch: enabled })
        });
        state.restartCodexAfterSwitch = !!(payload && payload.restart_codex_after_switch);
        renderPreferences();
        setStatus(
          state.restartCodexAfterSwitch
            ? "已开启自动重启 Codex App。"
            : "已关闭自动重启 Codex App。",
          "success"
        );
      } catch (error) {
        state.restartCodexAfterSwitch = !enabled;
        renderPreferences();
        setStatus(error.message || "保存偏好失败", "error");
      } finally {
        state.preferenceBusy = false;
        syncControls();
      }
    }

    async function saveAPIConfig(changes) {
      state.apiBusy = true;
      syncControls();
      setStatus("正在保存风险开关", "neutral");
      try {
        const { payload } = await api("/api/api-config", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(changes)
        });
        state.api = payload;
        render();
        setStatus("风险开关已更新。", "success");
      } catch (error) {
        setStatus(error.message || "保存风险开关失败", "error");
      } finally {
        state.apiBusy = false;
        render();
      }
    }

    async function setRenewal(accountKey, date) {
      if (!date) {
        setStatus("请先选择一个续费日期。", "warning");
        return;
      }
      state.busy = true;
      syncControls();
      setStatus("正在保存续费日期", "neutral");
      try {
        const { payload } = await api("/api/renewal/set", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ account_key: accountKey, date })
        });
        render(payload);
        setStatus("续费日期已保存。", "success");
      } catch (error) {
        setStatus(error.message || "保存续费日期失败", "error");
      } finally {
        state.busy = false;
        render();
      }
    }

    async function clearRenewal(accountKey) {
      state.busy = true;
      syncControls();
      setStatus("正在清除续费日期", "neutral");
      try {
        const { payload } = await api("/api/renewal/clear", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ account_key: accountKey })
        });
        render(payload);
        setStatus("续费日期已清除。", "success");
      } catch (error) {
        setStatus(error.message || "清除续费日期失败", "error");
      } finally {
        state.busy = false;
        render();
      }
    }

    async function load(mode = "state") {
      state.busy = true;
      syncControls();
      const syncingLocalUsage = mode === "refreshCurrent";
      const syncingAllUsage = mode === "refreshAll";
      setStatus(
        syncingAllUsage ? "正在刷新全部额度" :
        syncingLocalUsage ? "正在同步本地额度" :
        "正在同步账号状态",
        "neutral"
      );
      try {
        const { payload } = syncingAllUsage
          ? await api("/api/refresh-all", { method: "POST" })
          : syncingLocalUsage
            ? await api("/api/refresh-active", { method: "POST" })
            : await api("/api/state");
        render(payload);
        if (syncingAllUsage) {
          if (!payload || !payload.api || payload.api.usage === false || (payload.refresh && payload.refresh.local_only_mode)) {
            setStatus("全部额度刷新需要先开启额度 API。", "warning");
          } else if (payload.refresh && payload.refresh.failed === payload.refresh.attempted && payload.refresh.attempted > 0) {
            setStatus("全部额度刷新失败，请检查 Node.js 或账号登录态。", "warning");
          } else {
            setStatus(
              `全部额度刷新完成：${payload.refresh.updated} 个已更新，${payload.refresh.failed} 个失败。`,
              payload.refresh.failed > 0 ? "warning" : "success"
            );
          }
        } else if (syncingLocalUsage) {
          if (payload && payload.refresh && (payload.refresh.local_only_mode || (payload.api && payload.api.usage === false))) {
            const active = payload && payload.accounts
              ? payload.accounts.find((account) => account.active)
              : null;
            setStatus(
              active ? `本地额度已同步：${active.label}` : "当前没有可同步的本地额度。",
              active ? "success" : "warning"
            );
          } else if (payload && payload.refresh && payload.refresh.attempted === 0) {
            setStatus("当前没有可同步的本地额度。", "warning");
          } else {
            const active = payload && payload.accounts
              ? payload.accounts.find((account) => account.active)
              : null;
            const failedUsage = active && active.usage && active.usage.status && active.usage.status !== "ok"
              ? usageStatusPresentation(active.usage.status)
              : null;
            setStatus(
              failedUsage
                ? `当前账号额度刷新失败：${failedUsage.summary}`
                : (active ? `本地额度已同步：${active.label}` : "本地额度已同步。"),
              failedUsage ? "warning" : "success"
            );
          }
        } else {
          setStatus("账号状态已同步。", "success");
        }
      } catch (error) {
        setStatus(error.message || "同步失败", "error");
      } finally {
        state.busy = false;
        render();
      }
    }

    async function startLogin(deviceAuth) {
      state.busy = true;
      syncControls();
      setStatus(deviceAuth ? "正在打开设备码登录" : "正在打开账号登录", "neutral");
      try {
        const { payload } = await api("/api/login", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ device_auth: deviceAuth })
        });
        setStatus((payload && payload.message) || "登录窗口已打开。", "success");
      } catch (error) {
        setStatus(error.message || "打开登录失败", "error");
      } finally {
        state.busy = false;
        render();
      }
    }

    async function startImport(source, loadingMessage) {
      state.busy = true;
      syncControls();
      setStatus(loadingMessage, "neutral");
      try {
        const { payload } = await api("/api/import", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ source })
        });
        const tone = payload && payload.ok ? "success" : "warning";
        setStatus((payload && payload.message) || "导入流程已处理。", tone);
      } catch (error) {
        setStatus(error.message || "打开导入失败", "error");
      } finally {
        state.busy = false;
        render();
      }
    }

    async function switchAccount(accountKey) {
      state.busy = true;
      syncControls();
      setStatus("正在切换账号", "neutral");
      try {
        const { payload, response } = await api("/api/switch", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ account_key: accountKey })
        });
        render(payload);
        const restartResult = response.headers.get("X-Codex-Restart-Result");
        const tone = restartResult === "restarted" || restartResult === "disabled"
          ? "success"
          : "warning";
        setStatus(switchMessage(restartResult), tone);
      } catch (error) {
        setStatus(error.message || "切换失败", "error");
      } finally {
        state.busy = false;
        render();
      }
    }

    searchEl.addEventListener("input", () => {
      state.query = searchEl.value;
      render();
    });
    addAccountEl.addEventListener("click", () => startLogin(false));
    deviceAuthEl.addEventListener("click", () => startLogin(true));
    importAuthEl.addEventListener("click", () => startImport("standard", "正在准备导入 auth"));
    importCPAEl.addEventListener("click", () => startImport("cpa", "正在准备导入 CPA"));
    scanCPAEl.addEventListener("click", () => startImport("cpa_default", "正在扫描默认 CPA 目录"));
    reloadEl.addEventListener("click", () => load("state"));
    refreshCurrentEl.addEventListener("click", () => load("refreshCurrent"));
    refreshAllEl.addEventListener("click", () => load("refreshAll"));
    restartToggleEl.addEventListener("change", () => savePreferences(restartToggleEl.checked));
    usageApiToggleEl.addEventListener("change", () => saveAPIConfig({
      usage_account_enabled: usageApiToggleEl.checked
    }));
    render();
    Promise.all([loadPreferences(), loadHealth()]).finally(() => load("state"));
  </script>
</body>
</html>
"""#
}
