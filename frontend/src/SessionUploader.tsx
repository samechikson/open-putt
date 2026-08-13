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
    <div className="card elev-sm">
      {videoUrl && (
        <video
          ref={videoRef}
          src={videoUrl}
          muted
          playsInline
          onLoadedData={handleLoaded}
          className="w-full max-h-64 mb-4"
          style={{
            borderRadius: "var(--radius-md)",
            background: "#000",
            display: "block",
          }}
        />
      )}

      {phase !== "error" ? (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            fontSize: 14,
            color: "var(--color-neutral-700)",
          }}
        >
          <span className="spinner" />
          {phase === "preparing" ? "Preparing upload…" : "Uploading…"}
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          <p style={{ margin: 0, fontSize: 14, color: "var(--color-accent-800)" }}>
            {error}
          </p>
          <button
            type="button"
            onClick={onCancel}
            className="btn btn-secondary"
            style={{ alignSelf: "flex-start" }}
          >
            Try again
          </button>
        </div>
      )}
    </div>
  );
}
