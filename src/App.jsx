import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import Signup from './components/Signup';
import Login from './components/Login';
import ScoutDashboard from './components/ScoutDashboard';
import AthleteDashboard from './components/AthleteDashboard';

function App() {
  return (
    <BrowserRouter>
      <Routes>
        {/* Default route -> Login page */}
        <Route path="/" element={<Navigate to="/login" replace />} />
        
        {/* Auth Routes */}
        <Route path="/signup" element={<Signup />} />
        <Route path="/login" element={<Login />} />
        
        {/* Dashboards */}
        <Route path="/athlete-dashboard" element={<AthleteDashboard />} />
        <Route path="/scout-dashboard" element={<ScoutDashboard />} />

        {/* Any unknown URL redirects back to Login */}
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;