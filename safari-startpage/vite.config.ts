import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Relative base so the built app works from a file:// URL or any subpath.
export default defineConfig({
  base: './',
  plugins: [react()],
  build: { outDir: 'dist' },
})
