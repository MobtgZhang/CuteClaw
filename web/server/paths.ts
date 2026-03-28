import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** CuteClaw 仓库根（含 src/、zig-out/ 的目录） */
export function cuteclawRoot(): string {
  const fromEnv = process.env.CUTECLAW_ROOT;
  if (fromEnv && fs.existsSync(fromEnv)) return path.resolve(fromEnv);
  return path.resolve(__dirname, "..", "..");
}

export function defaultStorePath(): string {
  if (process.env.CUTECLAW_STORE) return path.resolve(process.env.CUTECLAW_STORE);
  return path.join(cuteclawRoot(), ".cuteclaw", "store.json");
}

export function defaultConfigPath(): string {
  if (process.env.CUTECLAW_CONFIG) return path.resolve(process.env.CUTECLAW_CONFIG);
  return path.join(cuteclawRoot(), ".cuteclaw", "config.json");
}

export function defaultCuteclawBin(): string {
  if (process.env.CUTECLAW_BIN) return path.resolve(process.env.CUTECLAW_BIN);
  const zigOut = path.join(cuteclawRoot(), "zig-out", "bin", "cuteclaw");
  return zigOut;
}

export function childEnv(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    CUTECLAW_STORE: defaultStorePath(),
    CUTECLAW_CONFIG: defaultConfigPath(),
  };
}
