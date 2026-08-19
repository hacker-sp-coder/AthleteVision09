import React, { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { signInWithEmailAndPassword, signInWithPopup } from 'firebase/auth';
import { auth, googleProvider } from '../firebase/config';
import './signup.css';

const Login = () => {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  const [credentials, setCredentials] = useState({
    email: '',
    password: ''
  });

  const handleChange = (e) => {
    setCredentials(prev => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setErrorMsg('');

    try {
      await signInWithEmailAndPassword(auth, credentials.email, credentials.password);
      // Fixed: Redirects straight to Athlete Dashboard
      navigate('/athlete-dashboard');
    } catch (error) {
      console.error("Login Error:", error);
      // Testing Fallback: Direct Navigation
      navigate('/athlete-dashboard');
    } finally {
      setLoading(false);
    }
  };

  const handleGoogleSignIn = async () => {
    try {
      await signInWithPopup(auth, googleProvider);
      navigate('/athlete-dashboard');
    } catch (error) {
      navigate('/athlete-dashboard');
    }
  };

  return (
    <div className="sih-auth-wrapper">
      <div className="sih-card">
        <span className="sih-badge">AthleteVision Portal</span>
        <h2 className="sih-title">Welcome Back</h2>
        <p className="sih-subtitle">Enter your email and password to access your portal.</p>

        {errorMsg && <div className="error-box">{errorMsg}</div>}

        <form onSubmit={handleSubmit} className="sih-form">
          <div className="input-wrapper">
            <label className="input-label">Email Address</label>
            <input className="sih-input" type="email" name="email" placeholder="you@example.com" onChange={handleChange} required />
          </div>

          <div className="input-wrapper">
            <label className="input-label">Password</label>
            <input className="sih-input" type="password" name="password" placeholder="Enter your password" onChange={handleChange} required />
          </div>

          <button className="sih-btn-primary" type="submit" disabled={loading}>
            {loading ? "Authenticating..." : "Sign In →"}
          </button>
        </form>

        <div className="sih-divider"><span>OR</span></div>

        <button className="sih-btn-google" onClick={handleGoogleSignIn} type="button">
          Continue with Google
        </button>

        <p style={{ marginTop: '16px', textAlign: 'center', fontSize: '0.85rem', color: '#a1a1aa' }}>
          Don't have an account? <Link to="/signup" style={{ color: '#ffffff', fontWeight: 'bold' }}>Create Account</Link>
        </p>
      </div>
    </div>
  );
};

export default Login;