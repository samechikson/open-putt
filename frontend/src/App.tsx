import {
  Navigate,
  Route,
  Routes,
  useLocation,
  useNavigate,
  useParams,
} from "react-router-dom";
import "./App.css";
import Dashboard from "./Dashboard";
import SessionDetail from "./SessionDetail";
import Putters from "./PuttersPage";
import Logo from "./Logo";
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
  const location = useLocation();

  // Which primary nav link reads as current. Putters is its own section;
  // everything else lives under the Sessions umbrella.
  const onPutters = location.pathname.startsWith("/putters");

  return (
    <div style={{ minHeight: "100svh", background: "var(--color-bg)" }}>
      <nav className="nav" style={{ maxWidth: 1280, margin: "0 auto" }}>
        <button
          type="button"
          className="nav-brand"
          onClick={() => navigate("/")}
        >
          <Logo size={24} />
          Putting Gate
        </button>
        {user && (
          <>
            <button
              type="button"
              className="nav-link"
              aria-current={onPutters ? undefined : "page"}
              onClick={() => navigate("/")}
            >
              Sessions
            </button>
            <button
              type="button"
              className="nav-link"
              aria-current={onPutters ? "page" : undefined}
              onClick={() => navigate("/putters")}
            >
              Putters
            </button>
            <div
              style={{
                marginLeft: "auto",
                display: "flex",
                alignItems: "center",
                gap: 14,
              }}
            >
              <span
                className="hidden sm:inline"
                style={{ fontSize: 13, color: "var(--color-neutral-600)" }}
              >
                {user.email}
              </span>
              <button
                type="button"
                onClick={signOut}
                className="btn btn-ghost btn-icon"
                aria-label="Sign out"
              >
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2.75"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                >
                  <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
                  <path d="M16 17l5-5-5-5" />
                  <path d="M21 12H9" />
                </svg>
              </button>
            </div>
          </>
        )}
      </nav>

      <div
        style={{ maxWidth: 1280, margin: "0 auto" }}
        className="px-4 sm:px-8 pt-2 pb-24"
      >
        <Routes>
          <Route
            path="/"
            element={
              <Dashboard
                onOpenSession={(id) => navigate(`/sessions/${id}`)}
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
