import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { signInWithEmailAndPassword } from 'firebase/auth';
import { doc, getDoc } from 'firebase/firestore';
import { auth, db } from '../firebase/config';
import './signup.css';

const AdminLogin = () => {
  const navigate = useNavigate();
  const [credentials, setCredentials] = useState({ email: '', password: '' });
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  const handleSubmit = async (event) => {
    event.preventDefault();
    setLoading(true);
    setErrorMsg('');

    try {
      const result = await signInWithEmailAndPassword(auth, credentials.email, credentials.password);
      const profile = await getDoc(doc(db, 'users', result.user.uid));

      if (!profile.exists() || !['admin', 'authority'].includes(profile.data().role)) {
        await auth.signOut();
        throw new Error('This account is not registered as an admin or authority account.');
      }

      navigate('/scout-dashboard');
    } catch (error) {
      setErrorMsg(error.message.replace('Firebase: ', ''));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="sih-auth-wrapper">
      <div className="sih-card">
        <span className="sih-badge">AthleteVision Authority</span>
        <h2 className="sih-title">Admin Login</h2>
        <p className="sih-subtitle">Sign in to publish tests and review athlete assessments.</p>

        {errorMsg && <div className="error-box">{errorMsg}</div>}

        <form onSubmit={handleSubmit} className="sih-form">
          <div className="input-wrapper">
            <label className="input-label" htmlFor="admin-login-email">Authority Email</label>
            <input id="admin-login-email" className="sih-input" type="email" value={credentials.email} placeholder="authority@example.com" onChange={(event) => setCredentials({ ...credentials, email: event.target.value })} required />
          </div>

          <div className="input-wrapper">
            <label className="input-label" htmlFor="admin-login-password">Password</label>
            <input id="admin-login-password" className="sih-input" type="password" value={credentials.password} placeholder="Enter your password" onChange={(event) => setCredentials({ ...credentials, password: event.target.value })} required />
          </div>

          <button className="sih-btn-primary" type="submit" disabled={loading}>
            {loading ? 'Authenticating...' : 'Sign In to Admin Dashboard →'}
          </button>
        </form>

        <p className="sih-auth-footer">
          Need an admin account?{' '}
          <Link to="/admin-signup" className="sih-auth-link">Create Admin Account</Link>
        </p>
      </div>
    </div>
  );
};

export default AdminLogin;
