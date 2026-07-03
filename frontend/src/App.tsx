import { useState } from "react";
import "./App.css";
import Dashboard from "./Dashboard";
import AnalyzeView from "./AnalyzeView";
import SessionDetail from "./SessionDetail";
import { useAuth } from "./AuthContext";

// Lightweight view switching (no router): the app opens on the dashboard, from
// which you start a new session (upload/analyze) or open a saved one.
type View =
  | { name: "dashboard" }
  | { name: "analyze" }
  | { name: "session"; id: string };

function App() {
  const { user, signOut } = useAuth();
  const [view, setView] = useState<View>({ name: "dashboard" });

  return (
    <div className="min-h-screen bg-[#0d0d0d] text-[#d0d0d0] px-4 py-8">
      <div className="max-w-6xl mx-auto">
        <div className="flex items-center justify-between gap-4 mb-8">
          <button
            type="button"
            onClick={() => setView({ name: "dashboard" })}
            className="text-left cursor-pointer"
          >
            <h1 className="text-2xl font-bold text-white">Putting Gate</h1>
          </button>
          {user && (
            <div className="flex items-center gap-3">
              <span className="text-xs text-[#888] hidden sm:inline">
                {user.email}
              </span>
              <button
                type="button"
                onClick={signOut}
                className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
              >
                Sign out
              </button>
            </div>
          )}
        </div>

        {view.name === "dashboard" && (
          <Dashboard
            onNewSession={() => setView({ name: "analyze" })}
            onOpenSession={(id) => setView({ name: "session", id })}
          />
        )}
        {view.name === "analyze" && (
          <AnalyzeView onBack={() => setView({ name: "dashboard" })} />
        )}
        {view.name === "session" && (
          <SessionDetail
            sessionId={view.id}
            onBack={() => setView({ name: "dashboard" })}
          />
        )}
      </div>
    </div>
  );
}

export default App;
