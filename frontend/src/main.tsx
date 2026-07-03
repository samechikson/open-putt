import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import Login from './Login.tsx'
import { AuthProvider, useAuth } from './AuthContext.tsx'

// Gate the whole app behind auth: render the login screen until there's a
// session, and a brief nothing-state while the initial session check runs.
function Root() {
  const { session, loading } = useAuth()
  if (loading) return null
  return session ? <App /> : <Login />
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AuthProvider>
      <Root />
    </AuthProvider>
  </StrictMode>,
)
