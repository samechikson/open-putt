import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // Mirror production: the app calls /api same-origin, and the dev server
  // proxies that to the local backend. The backend mounts its routes under
  // /api (see backend/app/main.py), so the prefix is forwarded as-is.
  server: {
    proxy: {
      "/api": "http://localhost:8000",
    },
  },
})
