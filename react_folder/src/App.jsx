import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import LandingPage from './components/landingpage';
import Signup from './components/signup';
import Login from './components/login';
import AdminSignup from './components/adminsignup';
import AdminLogin from './components/adminlogin';
import AthleteDashboard from './components/athletedashboard';
import ScoutDashboard from './components/scoutdashboard';
import Assessment from './components/assessment';
import Profile from './components/profile';
import SportCv from './components/sportcv';

function App() {
  return (
    <Router>
      <div className="min-h-screen bg-slate-50 font-sans antialiased text-slate-900">
        <Routes>
          <Route path="/" element={<LandingPage />} />
          <Route path="/signup" element={<Signup />} />
          <Route path="/login" element={<Login />} />
          <Route path="/admin-signup" element={<AdminSignup />} />
          <Route path="/admin-login" element={<AdminLogin />} />
          <Route path="/athlete-dashboard" element={<AthleteDashboard />} />
          <Route path="/assessment" element={<Assessment />} />
          <Route path="/profile" element={<Profile />} />
          <Route path="/sport-cv" element={<SportCv />} />
          <Route path="/scout-dashboard" element={<ScoutDashboard />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </div>
    </Router>
  );
}

export default App;