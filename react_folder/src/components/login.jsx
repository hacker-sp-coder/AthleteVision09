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
    setErrorMsg('');
    setCredentials(prev => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setErrorMsg('');

    try {
      await signInWithEmailAndPassword(auth, credentials.email, credentials.password);
      navigate('/athlete-dashboard');
    } catch (error) {
      console.error("Login Error:", error);
      // Firebase error format clean up
      if (error.code === 'auth/invalid-credential' || error.code === 'auth/user-not-found' || error.code === 'auth/wrong-password') {
        setErrorMsg('Invalid email or password. Please try again.');
      } else {
        setErrorMsg(error.message.replace('Firebase: ', ''));
      }
    } finally {
      setLoading(false);
    }
  };

  const handleGoogleSignIn = async () => {
    setLoading(true);
    setErrorMsg('');
    try {
      await signInWithPopup(auth, googleProvider);
      navigate('/athlete-dashboard');
    } catch (error) {
      console.error("Google Login Error:", error);
      setErrorMsg(error.message.replace('Firebase: ', ''));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="sih-auth-wrapper">
      <div className="sih-card">
        <span className="sih-badge">AthleteVision Portal</span>
        <h2 className="sih-title">Welcome Back</h2>
        <p className="sih-subtitle">Enter your email and password to access your portal.</p>

        {errorMsg && (
          <div className="error-box" style={{ color: '#ef4444', backgroundColor: '#fee2e2', padding: '10px', borderRadius: '8px', marginBottom: '16px', fontSize: '0.85rem' }}>
            {errorMsg}
          </div>
        )}

        <form onSubmit={handleSubmit} className="sih-form">
          <div className="input-wrapper">
            <label className="input-label">Email Address</label>
            <input 
              className="sih-input" 
              type="email" 
              name="email" 
              value={credentials.email} 
              placeholder="you@example.com" 
              onChange={handleChange} 
              required 
            />
          </div>

          <div className="input-wrapper">
            <label className="input-label">Password</label>
            <input 
              className="sih-input" 
              type="password" 
              name="password" 
              value={credentials.password} 
              placeholder="Enter your password" 
              onChange={handleChange} 
              required 
            />
          </div>

          <button className="sih-btn-primary" type="submit" disabled={loading}>
            {loading ? "Authenticating..." : "Sign In →"}
          </button>
        </form>

        <div className="sih-divider"><span>OR</span></div>

        <button className="sih-btn-google" onClick={handleGoogleSignIn} type="button" disabled={loading}>
          {loading ? "Signing in..." : "Continue with Google"}
        </button>
<p className="sih-auth-footer">
  Don't have an account?{' '}
  <Link to="/signup" className="sih-auth-link">
    Create Account
  </Link>
</p>
      </div>
    </div>
  );
};

export default Login;