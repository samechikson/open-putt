import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import Login from './Login.tsx'
import { AuthProvider, useAuth } from './AuthContext.tsx'

// Gate the whole app behind auth: render the login screen until there's a
// signed-in user, and a brief nothing-state while the initial auth check runs.
function Root() {
  const { user, loading } = useAuth()
  if (loading) return null
  return user ? <App /> : <Login />
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AuthProvider>
      <Root />
    </AuthProvider>
  </StrictMode>,
)
