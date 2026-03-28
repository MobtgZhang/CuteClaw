import { useState } from "react";
import type { ProposalJson } from "@/types/proposal";
import { api } from "@/api/client";

const proposalTemplate: ProposalJson = {
  skill_name: "example_skill",
  version_hint: "1.0.0",
  patch_summary: "说明本次变更",
  new_body: "技能正文 Markdown",
  preconditions: "",
  prohibitions: "",
};

export function ActionsPage() {
  const [policy, setPolicy] = useState("default");
  const [semver, setSemver] = useState("patch");
  const [proposalText, setProposalText] = useState(JSON.stringify(proposalTemplate, null, 2));
  const [evolveOut, setEvolveOut] = useState<string | null>(null);
  const [valOut, setValOut] = useState<string | null>(null);
  const [taskMsg, setTaskMsg] = useState<string | null>(null);
  const [invokeMsg, setInvokeMsg] = useState<string | null>(null);

  const [taskId, setTaskId] = useState("");
  const [outcome, setOutcome] = useState("success");
  const [summary, setSummary] = useState("");

  const [skill, setSkill] = useState("");
  const [invokeOk, setInvokeOk] = useState(true);

  const [importText, setImportText] = useState("");
  const [importOut, setImportOut] = useState<string | null>(null);

  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const parseProposal = (): ProposalJson => {
    const o = JSON.parse(proposalText) as unknown;
    if (!o || typeof o !== "object") throw new Error("proposal 须为 JSON 对象");
    return o as ProposalJson;
  };

  const runEvolve = async () => {
    setErr(null);
    setEvolveOut(null);
    setValOut(null);
    setTaskMsg(null);
    setInvokeMsg(null);
    setBusy("evolve");
    try {
      const p = parseProposal();
      const r = await api.evolve(p, policy, semver);
      setEvolveOut(JSON.stringify(r, null, 2));
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(null);
    }
  };

  const runValidate = async () => {
    setErr(null);
    setValOut(null);
    setEvolveOut(null);
    setTaskMsg(null);
    setInvokeMsg(null);
    setBusy("validate");
    try {
      const p = parseProposal();
      const r = await api.validate(p);
      setValOut(JSON.stringify(r, null, 2));
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(null);
    }
  };

  const runTask = async () => {
    setErr(null);
    setTaskMsg(null);
    setBusy("task");
    try {
      await api.task(taskId, outcome, summary);
      setTaskMsg("task 已成功执行。");
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(null);
    }
  };

  const runInvoke = async () => {
    setErr(null);
    setInvokeMsg(null);
    setBusy("invoke");
    try {
      await api.invoke(skill, invokeOk);
      setInvokeMsg("invoke 已成功执行。");
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(null);
    }
  };

  const runImport = async () => {
    setErr(null);
    setImportOut(null);
    setBusy("import");
    try {
      const doc = JSON.parse(importText) as unknown;
      const r = await fetch("/api/import-store", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(doc),
      });
      const data = (await r.json()) as Record<string, unknown>;
      if (!r.ok) throw new Error(String(data.error ?? r.statusText));
      setImportOut(JSON.stringify(data, null, 2));
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <div>
      {err && (
        <div className="card">
          <p className="err">{err}</p>
        </div>
      )}

      <div className="card">
        <h2>evolve / validate（子进程）</h2>
        <div className="row">
          <div>
            <label>policy</label>
            <input type="text" value={policy} onChange={(e) => setPolicy(e.target.value)} />
          </div>
          <div>
            <label>semver</label>
            <select value={semver} onChange={(e) => setSemver(e.target.value)}>
              <option value="patch">patch</option>
              <option value="minor">minor</option>
              <option value="major">major</option>
            </select>
          </div>
        </div>
        <label>proposal JSON</label>
        <textarea value={proposalText} onChange={(e) => setProposalText(e.target.value)} spellCheck={false} />
        <p>
          <button type="button" className="primary" disabled={busy !== null} onClick={() => void runValidate()}>
            validate
          </button>
          <button
            type="button"
            className="primary"
            style={{ marginLeft: "0.5rem" }}
            disabled={busy !== null}
            onClick={() => void runEvolve()}
          >
            evolve
          </button>
        </p>
        {valOut && (
          <>
            <label>validate 结果</label>
            <pre className="json">{valOut}</pre>
          </>
        )}
        {evolveOut && (
          <>
            <label>evolve 输出</label>
            <pre className="json">{evolveOut}</pre>
          </>
        )}
      </div>

      <div className="card">
        <h2>task（子进程）</h2>
        <label>task_id</label>
        <input type="text" value={taskId} onChange={(e) => setTaskId(e.target.value)} />
        <label>outcome</label>
        <select value={outcome} onChange={(e) => setOutcome(e.target.value)}>
          <option value="success">success</option>
          <option value="failed">failed</option>
          <option value="aborted">aborted</option>
          <option value="needs_human">needs_human</option>
        </select>
        <label>summary</label>
        <textarea value={summary} onChange={(e) => setSummary(e.target.value)} />
        <p>
          <button type="button" className="primary" disabled={busy !== null} onClick={() => void runTask()}>
            执行 task
          </button>
        </p>
        {taskMsg && <p className="ok">{taskMsg}</p>}
      </div>

      <div className="card">
        <h2>invoke（子进程）</h2>
        <label>skill 名称</label>
        <input type="text" value={skill} onChange={(e) => setSkill(e.target.value)} />
        <label>
          <input type="checkbox" checked={invokeOk} onChange={(e) => setInvokeOk(e.target.checked)} /> ok（否则
          fail）
        </label>
        <p>
          <button type="button" className="primary" disabled={busy !== null} onClick={() => void runInvoke()}>
            invoke
          </button>
        </p>
        {invokeMsg && <p className="ok">{invokeMsg}</p>}
      </div>

      <div className="card">
        <h2>import 全量快照（子进程 stdin）</h2>
        <p className="muted">粘贴完整 store 文档 JSON；会覆盖当前 store，请谨慎。</p>
        <textarea
          value={importText}
          onChange={(e) => setImportText(e.target.value)}
          spellCheck={false}
          style={{ minHeight: 200 }}
        />
        <p>
          <button type="button" className="primary" disabled={busy !== null} onClick={() => void runImport()}>
            import
          </button>
        </p>
        {importOut && (
          <>
            <label>结果</label>
            <pre className="json">{importOut}</pre>
          </>
        )}
      </div>

      {busy && <p className="muted">执行中: {busy}…</p>}
    </div>
  );
}
