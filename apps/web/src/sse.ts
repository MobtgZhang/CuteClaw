import type { JsonValue, SseEvent } from "./types";

/** POST + fetch 流：EventSource 不支持 POST，这里手工解析 SSE 帧。 */
export async function streamChat(
  session: string,
  message: string,
  onEvent: (event: SseEvent) => void,
  signal?: AbortSignal,
): Promise<void> {
  const response = await fetch(`/api/chat/stream`, {
    method: "POST",
    headers: { accept: "text/event-stream", "content-type": "application/json" },
    body: JSON.stringify({ session, message }),
    signal,
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`HTTP ${response.status}: ${text || response.statusText}`);
  }

  const reader = response.body?.getReader();
  if (!reader) throw new Error("response body is not readable");

  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  for (;;) {
    const chunk = await reader.read();
    if (chunk.done) break;
    buffer += decoder.decode(chunk.value, { stream: true });

    for (;;) {
      const boundary = buffer.indexOf("\n\n");
      if (boundary < 0) break;
      const block = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const event = parseBlock(block);
      if (event) onEvent(event);
    }
  }
}

function parseBlock(block: string): SseEvent | null {
  let kind = "message";
  const dataLines: string[] = [];

  for (const line of block.split("\n")) {
    if (line.startsWith(":")) continue;
    if (line.startsWith("event:")) {
      kind = line.slice(6).trim();
    } else if (line.startsWith("data:")) {
      dataLines.push(line.slice(5).trim());
    }
  }

  if (dataLines.length === 0) return null;
  const raw = dataLines.join("\n");
  let data: JsonValue;
  try {
    data = JSON.parse(raw) as JsonValue;
  } catch {
    data = raw;
  }
  return { kind, data };
}
