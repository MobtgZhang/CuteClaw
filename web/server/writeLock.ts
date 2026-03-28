/**
 * 序列化所有可能修改 store 的操作，避免与 CLI 并发写同一文件时交错
 *（仍无法阻止外部进程直接写文件，见文档说明）。
 */
export class WriteLock {
  private tail = Promise.resolve();

  run<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.tail.then(fn, fn);
    this.tail = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }
}
