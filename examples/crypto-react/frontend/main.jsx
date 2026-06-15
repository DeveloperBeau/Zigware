import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App.jsx";
// Styles live inline in index.html so the production build emits a single
// external app.js with no separate stylesheet (the framework asset table serves
// /index.html and /app.js only).

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
