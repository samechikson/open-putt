import { useEffect, useRef, useState } from "react";
import { measureVideoFps } from "./analysis";
import { uploadSession } from "./sessions";

interface SessionUploaderProps {
  file: File;
  onCreated: (sessionId: string) => void;
  onCancel: () => void;
}

// Prepares and queues a Full Session upload: measures the clip's frame rate
// (for accurate speed), POSTs it for background analysis, then hands the new
// session id up so the app can navigate to it. Analysis itself runs on the
// server — this component's job ends once the session is queued.
export default function SessionUploader({
  file,
  onCreated,
  onCancel,
}: SessionUploaderProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [phase, setPhase] = useState<"preparing" | "uploading" | "error">(
    "preparing",
  );
  const [error, setError] = useState<string | null>(null);
  const started = useRef(false);

  useEffect(() => {
    const url = URL.createObjectURL(file);
    setVideoUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);

  const handleLoaded = async () => {
    if (started.current || !videoRef.current) return;
    started.current = true;
    const fps = await measureVideoFps(videoRef.current);
    setPhase("uploading");
    try {
      const sessionId = await uploadSession(file, fps);
      onCreated(sessionId);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Upload failed");
      setPhase("error");
    }
  };

  return (
    <div className="bg-[#1a1a1a] border border-[#333] rounded-xl p-5">
      {videoUrl && (
        <video
          ref={videoRef}
          src={videoUrl}
          muted
          playsInline
          onLoadedData={handleLoaded}
          className="w-full max-h-64 rounded-lg bg-black mb-4"
        />
      )}

      {phase !== "error" ? (
        <div className="flex items-center gap-2 text-sm text-[#aaa]">
          <span className="w-3.5 h-3.5 border-2 border-[#22c55e] border-t-transparent rounded-full animate-spin" />
          {phase === "preparing" ? "Preparing upload…" : "Uploading…"}
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          <p className="text-sm text-[#f87171]">{error}</p>
          <button
            type="button"
            onClick={onCancel}
            className="self-start px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
          >
            Try again
          </button>
        </div>
      )}
    </div>
  );
}
