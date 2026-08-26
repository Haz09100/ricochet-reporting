import { Headphones, LoaderCircle, Pause, Play, TriangleAlert } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { bridgeRequest } from "../lib/reportApi.js";

export default function AudioPlayer({ callUuid, compact = false }) {
  const [urls, setUrls] = useState([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [playing, setPlaying] = useState(false);
  const audioRef = useRef(null);

  useEffect(() => () => urls.forEach((url) => URL.revokeObjectURL(url)), [urls]);

  const load = async () => {
    if (urls.length) {
      const audio = audioRef.current;
      if (!audio) return;
      if (audio.paused) { await audio.play(); setPlaying(true); } else { audio.pause(); setPlaying(false); }
      return;
    }
    setLoading(true); setError("");
    try {
      const partsResponse = await bridgeRequest(`/recordings/${encodeURIComponent(callUuid)}/parts`);
      const parts = Math.max(1, Number((await partsResponse.json()).parts || 1));
      const loaded = [];
      for (let part = 1; part <= parts; part += 1) {
        const response = await bridgeRequest(`/recordings/${encodeURIComponent(callUuid)}/audio?part=${part}`, { accept: "audio/*" });
        loaded.push(URL.createObjectURL(await response.blob()));
      }
      setUrls(loaded);
    } catch (cause) { setError(cause.message); }
    finally { setLoading(false); }
  };

  if (!callUuid) return <span className="muted"><TriangleAlert size={13} /> No recording ID</span>;
  return <div className={compact ? "audio-player compact" : "audio-player"}>
    <button className="button recording-button" onClick={load} disabled={loading}>
      {loading ? <LoaderCircle className="spin" size={15} /> : playing ? <Pause size={15} /> : urls.length ? <Play size={15} /> : <Headphones size={15} />}
      {loading ? "Loading…" : urls.length ? playing ? "Pause" : "Play" : "Load recording"}
    </button>
    {error && <span className="recording-error" title={error}>Recording unavailable</span>}
    {urls.map((url, index) => <audio key={url} ref={index === 0 ? audioRef : null} controls={!compact || urls.length > 1} preload="metadata" src={url} onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)} />)}
  </div>;
}
