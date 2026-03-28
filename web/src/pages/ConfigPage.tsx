import { useCallback, useEffect, useState } from "react";
import type { ApiConfigJson, ApiHeader } from "@/types/config.v1";
import { api } from "@/api/client";

function emptyConfig(): ApiConfigJson {
  return {
    schema_version: 1,
    provider: "openai",
    api_base: "https://api.openai.com/v1",
    api_key_file: "",
    api_key_env: "OPENAI_API_KEY",
    model: "gpt-4o-mini",
    connect_timeout_sec: 30,
    read_timeout_sec: 120,
    extra_headers: [],
  };
}

export function ConfigPage() {
  const [cfg, setCfg] = useState<ApiConfigJson | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [headersText, setHeadersText] = useState("[]");
  const [cliShow, setCliShow] = useState<string | null>(null);

  const load = useCallback(async () => {
    setErr(null);
    setMsg(null);
    try {
      const c = await api.getConfig();
      setCfg(c);
      setHeadersText(JSON.stringify(c.extra_headers ?? [], null, 2));
    } catch (e) {
      const m = String(e);
      if (m.includes("not found") || m.includes("config not found")) {
        setCfg(emptyConfig());
        setHeadersText("[]");
        setMsg("未找到现有 config，已填入默认模板；保存后将写入磁盘。");
      } else {
        setErr(m);
      }
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const save = async () => {
    if (!cfg) return;
    setErr(null);
    setMsg(null);
    let extra: ApiHeader[];
    try {
      extra = JSON.parse(headersText) as ApiHeader[];
      if (!Array.isArray(extra)) throw new Error("extra_headers 须为数组");
    } catch (e) {
      setErr(`extra_headers JSON 无效: ${String(e)}`);
      return;
    }
    const next: ApiConfigJson = { ...cfg, extra_headers: extra };
    try {
      await api.putConfig(next);
      setCfg(next);
      setMsg("已保存。");
    } catch (e) {
      setErr(String(e));
    }
  };

  if (!cfg && !err) {
    return (
      <div className="card">
        <p className="muted">加载中…</p>
      </div>
    );
  }

  if (err && !cfg) {
    return (
      <div className="card">
        <p className="err">{err}</p>
        <button type="button" className="secondary" onClick={() => void load()}>
          重试
        </button>
      </div>
    );
  }

  if (!cfg) return null;

  return (
    <div className="card">
      <h2>config.json</h2>
      <p className="muted">
        密钥请使用本机文件（api_key_file）或进程环境变量（api_key_env）；勿在公开环境明文写入密钥。
      </p>
      {msg && <p className="ok">{msg}</p>}
      {err && <p className="err">{err}</p>}

      <label>schema_version</label>
      <input
        type="number"
        value={cfg.schema_version}
        onChange={(e) => setCfg({ ...cfg, schema_version: Number(e.target.value) })}
      />

      <label>provider</label>
      <input type="text" value={cfg.provider} onChange={(e) => setCfg({ ...cfg, provider: e.target.value })} />

      <label>api_base</label>
      <input type="text" value={cfg.api_base} onChange={(e) => setCfg({ ...cfg, api_base: e.target.value })} />

      <label>api_key_file（本机路径）</label>
      <input
        type="text"
        value={cfg.api_key_file}
        onChange={(e) => setCfg({ ...cfg, api_key_file: e.target.value })}
      />

      <label>api_key_env</label>
      <input type="text" value={cfg.api_key_env} onChange={(e) => setCfg({ ...cfg, api_key_env: e.target.value })} />

      <label>model</label>
      <input type="text" value={cfg.model} onChange={(e) => setCfg({ ...cfg, model: e.target.value })} />

      <div className="row">
        <div>
          <label>connect_timeout_sec</label>
          <input
            type="number"
            value={cfg.connect_timeout_sec}
            onChange={(e) => setCfg({ ...cfg, connect_timeout_sec: Number(e.target.value) })}
          />
        </div>
        <div>
          <label>read_timeout_sec</label>
          <input
            type="number"
            value={cfg.read_timeout_sec}
            onChange={(e) => setCfg({ ...cfg, read_timeout_sec: Number(e.target.value) })}
          />
        </div>
      </div>

      <label>extra_headers（JSON 数组）</label>
      <textarea value={headersText} onChange={(e) => setHeadersText(e.target.value)} spellCheck={false} />

      <p style={{ marginTop: "1rem" }}>
        <button type="button" className="primary" onClick={() => void save()}>
          保存到磁盘
        </button>
        <button type="button" className="secondary" style={{ marginLeft: "0.5rem" }} onClick={() => void load()}>
          重新加载
        </button>
        <button
          type="button"
          className="secondary"
          style={{ marginLeft: "0.5rem" }}
          onClick={() => {
            setErr(null);
            void (async () => {
              try {
                const r = await api.configShow();
                setCliShow(r.stdout);
              } catch (e) {
                setErr(String(e));
                setCliShow(null);
              }
            })();
          }}
        >
          cuteclaw config show
        </button>
      </p>
      {cliShow != null && (
        <>
          <label>CLI 输出（不含密钥明文）</label>
          <pre className="json">{cliShow}</pre>
        </>
      )}
    </div>
  );
}
