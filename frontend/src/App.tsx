import { Navigate, Route, Routes, useNavigate, useParams } from "react-router-dom";
import "./App.css";
import Dashboard from "./Dashboard";
import AnalyzeView from "./AnalyzeView";
import SessionDetail from "./SessionDetail";
import Putters from "./PuttersPage";
import { useAuth } from "./AuthContext";

// Each screen has its own route (see the paths below). Navigation goes through
// the URL/browser history via `useNavigate`; the page components keep their
// existing callback props, which we wire to `navigate(...)` here so they stay
// decoupled from the router.

// Reads the :id route param and renders the session page.
function SessionDetailRoute() {
  const navigate = useNavigate();
  const { id } = useParams();
  return <SessionDetail sessionId={id!} onBack={() => navigate("/")} />;
}

function App() {
  const { user, signOut } = useAuth();
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-[#0d0d0d] text-[#d0d0d0] px-4 py-8">
      <div className="max-w-6xl mx-auto">
        <div className="flex items-center justify-between gap-4 mb-8">
          <button
            type="button"
            onClick={() => navigate("/")}
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
                onClick={() => navigate("/putters")}
                className="px-4 py-2 bg-[#222] border border-[#333] hover:bg-[#2c2c2c] hover:border-[#444] rounded-lg text-sm text-white font-medium transition-all cursor-pointer"
              >
                Putters
              </button>
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

        <Routes>
          <Route
            path="/"
            element={
              <Dashboard
                onNewSession={() => navigate("/analyze")}
                onOpenSession={(id) => navigate(`/sessions/${id}`)}
              />
            }
          />
          <Route
            path="/analyze"
            element={
              <AnalyzeView
                onBack={() => navigate("/")}
                onSessionCreated={(id) => navigate(`/sessions/${id}`)}
              />
            }
          />
          <Route path="/sessions/:id" element={<SessionDetailRoute />} />
          <Route
            path="/putters"
            element={<Putters onBack={() => navigate("/")} />}
          />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </div>
    </div>
  );
}

export default App;
