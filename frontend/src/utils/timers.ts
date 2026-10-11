export interface SafeTimeout {
  cancel(): void;
}

export function setSafeTimeout(
  callback: () => void,
  delay: number
): SafeTimeout {
  const MAX_DELAY = 86_400_000;
  let remaining = delay;
  let timer: number;
  let canceled = false;

  function scheduleNext() {
    timer = window.setTimeout(
      () => {
        // Clearing the browser timeout cannot stop a callback already queued.
        if (canceled) return;
        // NaN follows the browser's immediate timeout behavior. Infinite delays
        // stay in bounded chunks until canceled, without a busy loop.
        if (remaining > MAX_DELAY) {
          remaining -= MAX_DELAY;
          scheduleNext();
        } else {
          callback();
        }
      },
      Math.min(remaining, MAX_DELAY)
    );
  }

  scheduleNext();
  return {
    cancel() {
      canceled = true;
      window.clearTimeout(timer);
    },
  };
}
