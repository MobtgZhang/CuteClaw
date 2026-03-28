import { useCallback, useEffect, useRef, useState } from "react";

const PRESETS = [
  "gpt-4o",
  "gpt-4o-mini",
  "gpt-4-turbo",
  "o1",
  "o1-mini",
  "o3-mini",
] as const;

const PRESET_SET = new Set<string>(PRESETS);

type Props = {
  model: string;
  onApply: (model: string) => void | Promise<void>;
  disabled?: boolean;
  extraModels: string[];
  onRefresh?: () => void | Promise<void>;
};

export function ModelPopover({ model, onApply, disabled, extraModels, onRefresh }: Props) {
  const [open, setOpen] = useState(false);
  const [custom, setCustom] = useState("");
  const [busy, setBusy] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  const extraOnly = extraModels.filter((id) => id.trim() && !PRESET_SET.has(id));

  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      const el = rootRef.current;
      if (el && !el.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open]);

  const apply = useCallback(
    async (m: string) => {
      const v = m.trim();
      if (!v || disabled) return;
      setBusy(true);
      try {
        await onApply(v);
        setOpen(false);
      } finally {
        setBusy(false);
      }
    },
    [disabled, onApply],
  );

  const handleRefresh = async () => {
    if (!onRefresh || refreshing || busy) return;
    setRefreshing(true);
    try {
      await onRefresh();
    } finally {
      setRefreshing(false);
    }
  };

  return (
    <div className="agent-model-popover-root" ref={rootRef}>
      <button
        type="button"
        className="agent-model-trigger"
        disabled={disabled}
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        aria-haspopup="listbox"
      >
        <span className="agent-model-trigger-label">模型</span>
        <span className="agent-model-trigger-value">{model || "选择…"}</span>
        <span className="agent-model-chevron" aria-hidden>
          ▾
        </span>
      </button>
      {open && (
        <div className="agent-model-panel" role="listbox">
          {onRefresh && (
            <div className="agent-model-panel-tools">
              <button
                type="button"
                className="agent-model-refresh"
                disabled={refreshing || disabled}
                onClick={() => void handleRefresh()}
                title="从服务端读取当前模型并加入列表"
              >
                {refreshing ? "刷新中…" : "刷新"}
              </button>
            </div>
          )}
          {extraOnly.length > 0 && (
            <div className="agent-model-extras">
              {extraOnly.map((id) => (
                <button
                  key={id}
                  type="button"
                  role="option"
                  aria-selected={model === id}
                  className={model === id ? "active" : ""}
                  onClick={() => void apply(id)}
                  disabled={busy}
                >
                  {id}
                </button>
              ))}
            </div>
          )}
          <div className="agent-model-presets">
            {PRESETS.map((id) => (
              <button
                key={id}
                type="button"
                role="option"
                aria-selected={model === id}
                className={model === id ? "active" : ""}
                onClick={() => void apply(id)}
                disabled={busy}
              >
                {id}
              </button>
            ))}
          </div>
          <div className="agent-model-custom">
            <input
              value={custom}
              onChange={(e) => setCustom(e.target.value)}
              placeholder="自定义模型 id"
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  void apply(custom);
                }
              }}
            />
            <button type="button" className="agent-btn ghost" disabled={busy} onClick={() => void apply(custom)}>
              应用
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
