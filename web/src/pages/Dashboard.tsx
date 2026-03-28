import { useEffect, useState } from "react";
import { api, type HealthResponse } from "@/api/client";

export function Dashboard() {
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [status, setStatus] = useState<{ parsed: Record<string, unknown>; stdout: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [h, s] = await Promise.all([api.health(), api.status()]);
        if (!cancelled) {
          setHealth(h);
          setStatus(s);
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

  const p = status?.parsed;

  return (
    <div>
      <div className="card">
        <h2>环境</h2>
        {err && <p className="err">{err}</p>}
        {health && (
          <ul className="muted" style={{ margin: 0, paddingLeft: "1.2rem", fontSize: "0.88rem" }}>
            <li>
              <strong>根目录</strong> {health.cuteclawRoot}
            </li>
            <li>
              <strong>二进制</strong> {health.bin}
            </li>
            <li>
              <strong>store</strong> {health.store}
            </li>
            <li>
              <strong>config</strong> {health.config}
            </li>
          </ul>
        )}
      </div>

      <div className="card">
        <h2>状态（cuteclaw status）</h2>
        {!status && !err && <p className="muted">加载中…</p>}
        {p && (
          <table>
            <tbody>
              {Object.entries(p)
                .filter(([k]) => k !== "raw")
                .map(([k, v]) => (
                  <tr key={k}>
                    <th>{k}</th>
                    <td>{String(v)}</td>
                  </tr>
                ))}
            </tbody>
          </table>
        )}
        {p?.raw != null && (
          <>
            <label>原始输出</label>
            <pre className="json">{String(p.raw)}</pre>
          </>
        )}
      </div>
    </div>
  );
}
