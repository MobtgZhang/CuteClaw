/** 原「控制台」多 Tab，经设置中的「旧版控制台」打开 */
import { useState } from "react";
import { Dashboard } from "@/pages/Dashboard";
import { StorePage } from "@/pages/StorePage";
import { ConfigPage } from "@/pages/ConfigPage";
import { ActionsPage } from "@/pages/ActionsPage";

type Tab = "dash" | "store" | "config" | "actions";

export function LegacyConsole() {
  const [tab, setTab] = useState<Tab>("dash");
  return (
    <div className="legacy-wrap">
      <h2>CuteClaw 控制台（旧版）</h2>
      <p className="muted">Zig /api：快照、config、evolve 等</p>
      <nav className="tabs">
        <button type="button" className={tab === "dash" ? "active" : ""} onClick={() => setTab("dash")}>
          仪表盘
        </button>
        <button type="button" className={tab === "store" ? "active" : ""} onClick={() => setTab("store")}>
          快照 store
        </button>
        <button type="button" className={tab === "config" ? "active" : ""} onClick={() => setTab("config")}>
          API 配置
        </button>
        <button type="button" className={tab === "actions" ? "active" : ""} onClick={() => setTab("actions")}>
          操作
        </button>
      </nav>
      {tab === "dash" && <Dashboard />}
      {tab === "store" && <StorePage />}
      {tab === "config" && <ConfigPage />}
      {tab === "actions" && <ActionsPage />}
    </div>
  );
}
