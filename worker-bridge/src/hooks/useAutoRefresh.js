import { useEffect, useRef, useState } from "react";

export function useAutoRefresh({ enabled, seconds, onRefresh }) {
  const [remaining, setRemaining] = useState(seconds);
  const busy = useRef(false);
  const refreshRef = useRef(onRefresh);
  refreshRef.current = onRefresh;

  useEffect(() => setRemaining(seconds), [seconds]);

  useEffect(() => {
    if (!enabled) return undefined;
    const tick = async () => {
      if (document.visibilityState !== "visible" || !navigator.onLine) return;
      setRemaining((value) => {
        if (value > 1) return value - 1;
        if (!busy.current) {
          busy.current = true;
          Promise.resolve(refreshRef.current({ background: true }))
            .finally(() => { busy.current = false; });
        }
        return seconds;
      });
    };
    const timer = window.setInterval(tick, 1000);
    const reset = () => setRemaining(seconds);
    document.addEventListener("visibilitychange", reset);
    window.addEventListener("online", reset);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", reset);
      window.removeEventListener("online", reset);
    };
  }, [enabled, seconds]);

  return remaining;
}
