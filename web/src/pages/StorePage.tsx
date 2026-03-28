import { useEffect, useState } from "react";
import type { StoreDocumentV1 } from "@/types/store.v1";
import { api } from "@/api/client";

export function StorePage() {
  const [doc, setDoc] = useState<StoreDocumentV1 | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [view, setView] = useState<"json" | "skills" | "episodic">("json");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const d = await api.getStore();
        if (!cancelled) {
          setDoc(d);
          setErr(null);
        }
      } catch (e) {
        if (!cancelled) setErr(String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div>
      <div className="card">
        <h2>快照（export JSON，只读）</h2>
        {err && <p className="err">{err}</p>}
        <nav className="tabs" style={{ marginTop: 0 }}>
          <button type="button" className={view === "json" ? "active" : ""} onClick={() => setView("json")}>
            JSON
          </button>
          <button type="button" className={view === "skills" ? "active" : ""} onClick={() => setView("skills")}>
            技能表
          </button>
          <button
            type="button"
            className={view === "episodic" ? "active" : ""}
            onClick={() => setView("episodic")}
          >
            情景任务
          </button>
        </nav>
        {!doc && !err && <p className="muted">加载中…</p>}
        {doc && view === "json" && <pre className="json">{JSON.stringify(doc, null, 2)}</pre>}
        {doc && view === "skills" && (
          <div style={{ overflowX: "auto" }}>
            <table>
              <thead>
                <tr>
                  <th>name</th>
                  <th>version</th>
                  <th>body（截断）</th>
                </tr>
              </thead>
              <tbody>
                {doc.skills.map((s) => (
                  <tr key={`${s.name}@${s.version}`}>
                    <td>{s.name}</td>
                    <td>{s.version}</td>
                    <td title={s.body}>{s.body.length > 80 ? `${s.body.slice(0, 80)}…` : s.body}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {doc && view === "episodic" && (
          <div style={{ overflowX: "auto" }}>
            <table>
              <thead>
                <tr>
                  <th>task_id</th>
                  <th>outcome</th>
                  <th>ended_unix</th>
                  <th>summary</th>
                </tr>
              </thead>
              <tbody>
                {doc.episodic.map((e) => (
                  <tr key={`${e.task_id}-${e.ended_unix}`}>
                    <td>{e.task_id}</td>
                    <td>{e.outcome}</td>
                    <td>{e.ended_unix}</td>
                    <td>{e.summary}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
