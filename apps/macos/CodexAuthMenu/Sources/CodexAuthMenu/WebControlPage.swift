import Foundation

enum WebControlPage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex 账号控制台</title>
  <style>
    :root {
      color-scheme: light;
      --page: #f6f7f9;
      --surface: #ffffff;
      --text: #111318;
      --muted: #5b6472;
      --line: #d8dee8;
      --accent: #0a7c5b;
      --accent-soft: #e7f6f1;
      --blue: #225fd6;
      --danger: #b42332;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--page);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 15px;
      letter-spacing: 0;
    }

    header {
      background: var(--surface);
      border-bottom: 1px solid var(--line);
    }

    .topbar {
      align-items: center;
      display: flex;
      gap: 14px;
      margin: 0 auto;
      max-width: 1120px;
      padding: 18px 20px;
    }

    .brand-image {
      background: var(--accent);
      border: 1px solid #08684d;
      border-radius: 8px;
      display: block;
      height: 34px;
      width: 34px;
    }

    h1 {
      font-size: 20px;
      line-height: 1.2;
      margin: 0;
    }

    .subtle {
      color: var(--muted);
      font-size: 13px;
      margin-top: 3px;
    }

    main {
      margin: 0 auto;
      max-width: 1120px;
      padding: 20px;
    }

    .toolbar {
      align-items: center;
      display: grid;
      gap: 10px;
      grid-template-columns: minmax(180px, 1fr) auto auto;
      margin-bottom: 16px;
    }

    input {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      color: var(--text);
      font: inherit;
      min-width: 0;
      padding: 10px 12px;
    }

    button {
      background: var(--text);
      border: 1px solid var(--text);
      border-radius: 8px;
      color: #ffffff;
      cursor: pointer;
      font: inherit;
      min-height: 40px;
      padding: 9px 12px;
      white-space: nowrap;
    }

    button.secondary {
      background: var(--surface);
      color: var(--text);
    }

    button:disabled {
      cursor: default;
      opacity: 0.55;
    }

    .status {
      color: var(--muted);
      min-height: 22px;
      overflow-wrap: anywhere;
    }

    .status.error {
      color: var(--danger);
    }

    .accounts {
      display: grid;
      gap: 10px;
    }

    .account {
      align-items: center;
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      display: grid;
      gap: 12px;
      grid-template-columns: minmax(0, 1fr) auto;
      padding: 14px;
    }

    .account.active {
      border-color: var(--accent);
      box-shadow: inset 4px 0 0 var(--accent);
    }

    .name {
      font-weight: 700;
      line-height: 1.25;
      overflow-wrap: anywhere;
    }

    .meta {
      color: var(--muted);
      line-height: 1.35;
      margin-top: 4px;
      overflow-wrap: anywhere;
    }

    .usage {
      color: var(--muted);
      font-size: 13px;
      margin-top: 6px;
    }

    .badge {
      background: var(--accent-soft);
      border-radius: 8px;
      color: var(--accent);
      display: inline-block;
      font-size: 12px;
      font-weight: 700;
      margin-left: 8px;
      padding: 3px 7px;
      vertical-align: middle;
    }

    .empty {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      color: var(--muted);
      padding: 22px;
      text-align: center;
    }

    @media (max-width: 720px) {
      .topbar {
        padding: 16px;
      }

      main {
        padding: 16px;
      }

      .toolbar {
        grid-template-columns: 1fr;
      }

      .account {
        grid-template-columns: 1fr;
      }

      button {
        width: 100%;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="topbar">
      <img class="brand-image" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=">
      <div>
        <h1>Codex 账号控制台</h1>
        <div class="subtle" id="activeLine">正在加载账号</div>
      </div>
    </div>
  </header>
  <main>
    <div class="toolbar">
      <input id="search" type="search" autocomplete="off" placeholder="搜索邮箱、别名、账号名称">
      <button class="secondary" id="reload">重新加载</button>
      <button id="refresh">刷新额度</button>
    </div>
    <div class="status" id="status"></div>
    <div class="accounts" id="accounts"></div>
  </main>
  <script>
    const token = new URLSearchParams(location.search).get("token") || "";
    const state = { accounts: [], busy: false, query: "" };
    const accountsEl = document.getElementById("accounts");
    const statusEl = document.getElementById("status");
    const activeLineEl = document.getElementById("activeLine");
    const searchEl = document.getElementById("search");
    const reloadEl = document.getElementById("reload");
    const refreshEl = document.getElementById("refresh");
    document.querySelector(".brand-image").src = `/app-icon.png?token=${encodeURIComponent(token)}`;

    function setStatus(text, isError = false) {
      statusEl.textContent = text;
      statusEl.classList.toggle("error", isError);
    }

    async function api(path, options = {}) {
      const headers = Object.assign({ "X-Codex-Auth-Token": token }, options.headers || {});
      const response = await fetch(path, Object.assign({}, options, { headers }));
      const text = await response.text();
      if (!response.ok) {
        try {
          const payload = JSON.parse(text);
          throw new Error(payload.error || response.statusText);
        } catch (error) {
          if (error instanceof SyntaxError) throw new Error(response.statusText);
          throw error;
        }
      }
      return JSON.parse(text);
    }

    function accountMatches(account) {
      const query = state.query.trim().toLowerCase();
      if (!query) return true;
      return [account.label, account.email, account.alias, account.account_name, account.plan]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(query));
    }

    function usageText(account) {
      if (!account.usage) return "未刷新额度";
      if (account.usage.status && account.usage.status !== "ok") return `额度刷新：${account.usage.status}`;
      const fiveHour = account.usage.five_hour && account.usage.five_hour.remaining_percent !== null
        ? `${account.usage.five_hour.remaining_percent}% 5小时`
        : "-- 5小时";
      const weekly = account.usage.weekly && account.usage.weekly.remaining_percent !== null
        ? `${account.usage.weekly.remaining_percent}% 每周`
        : "-- 每周";
      return `${fiveHour}, ${weekly}`;
    }

    function render(payload) {
      state.accounts = payload.accounts || [];
      const active = state.accounts.find((account) => account.active);
      activeLineEl.textContent = active ? `当前账号：${active.label}` : "未选择账号";
      accountsEl.replaceChildren();

      const filtered = state.accounts.filter(accountMatches);
      if (filtered.length === 0) {
        const empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = state.accounts.length === 0 ? "暂无账号" : "没有匹配的账号";
        accountsEl.appendChild(empty);
        return;
      }

      for (const account of filtered) {
        const row = document.createElement("div");
        row.className = `account${account.active ? " active" : ""}`;

        const details = document.createElement("div");
        const name = document.createElement("div");
        name.className = "name";
        name.textContent = account.label;
        if (account.active) {
          const badge = document.createElement("span");
          badge.className = "badge";
          badge.textContent = "当前";
          name.appendChild(badge);
        }

        const meta = document.createElement("div");
        meta.className = "meta";
        const plan = account.plan || "未知";
        meta.textContent = account.alias ? `${account.email} - ${account.alias} - ${plan}` : `${account.email} - ${plan}`;

        const usage = document.createElement("div");
        usage.className = "usage";
        usage.textContent = usageText(account);

        details.append(name, meta, usage);

        const action = document.createElement("button");
        action.className = account.active ? "secondary" : "";
        action.textContent = account.active ? "已选择" : "切换";
        action.disabled = account.active || state.busy;
        action.addEventListener("click", () => switchAccount(account.account_key));

        row.append(details, action);
        accountsEl.appendChild(row);
      }
    }

    async function load(refreshUsage = false) {
      state.busy = true;
      reloadEl.disabled = true;
      refreshEl.disabled = true;
      setStatus(refreshUsage ? "正在刷新额度" : "正在加载");
      try {
        const payload = refreshUsage ? await api("/api/refresh", { method: "POST" }) : await api("/api/state");
        render(payload);
        const summary = payload.refresh || {};
        if (refreshUsage) {
          setStatus(`额度刷新完成：${summary.updated || 0} 个已更新，${summary.failed || 0} 个失败`);
        } else {
          setStatus("已就绪");
        }
      } catch (error) {
        setStatus(error.message || "请求失败", true);
      } finally {
        state.busy = false;
        reloadEl.disabled = false;
        refreshEl.disabled = false;
        render({ accounts: state.accounts });
      }
    }

    async function switchAccount(accountKey) {
      state.busy = true;
      setStatus("正在切换账号");
      try {
        const payload = await api("/api/switch", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ account_key: accountKey })
        });
        render(payload);
        setStatus("已切换。请重启 Codex CLI 或 Codex App 让新账号生效。");
      } catch (error) {
        setStatus(error.message || "切换失败", true);
      } finally {
        state.busy = false;
        render({ accounts: state.accounts });
      }
    }

    searchEl.addEventListener("input", () => {
      state.query = searchEl.value;
      render({ accounts: state.accounts });
    });
    reloadEl.addEventListener("click", () => load(false));
    refreshEl.addEventListener("click", () => load(true));
    load(false);
  </script>
</body>
</html>
"""#
}
