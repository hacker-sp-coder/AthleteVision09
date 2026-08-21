import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { createUserWithEmailAndPassword } from 'firebase/auth';
import { auth } from '../firebase/config';
import './signup.css';

const AdminSignup = () => {
  const navigate = useNavigate();
  const [formData, setFormData] = useState({ name: '', email: '', password: '' });
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  const handleChange = (event) => {
    setErrorMsg('');
    setFormData((current) => ({ ...current, [event.target.name]: event.target.value }));
  };

  const handleSubmit = async (event) => {
    event.preventDefault();
    setLoading(true);
    setErrorMsg('');

    try {
      await createUserWithEmailAndPassword(auth, formData.email, formData.password);
      navigate('/admin-login');
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
        <h2 className="sih-title">Create Admin Account</h2>
        <p className="sih-subtitle">Register an authority account to manage assessments and athlete recommendations.</p>

        {errorMsg && <div className="error-box">{errorMsg}</div>}

        <form onSubmit={handleSubmit} className="sih-form">
          <div className="input-wrapper">
            <label className="input-label" htmlFor="admin-name">Full Name</label>
            <input id="admin-name" className="sih-input" type="text" name="name" value={formData.name} placeholder="Enter your name" onChange={handleChange} required />
          </div>

          <div className="input-wrapper">
            <label className="input-label" htmlFor="admin-email">Authority Email</label>
            <input id="admin-email" className="sih-input" type="email" name="email" value={formData.email} placeholder="authority@example.com" onChange={handleChange} required />
          </div>

          <div className="input-wrapper">
            <label className="input-label" htmlFor="admin-password">Password</label>
            <input id="admin-password" className="sih-input" type="password" name="password" value={formData.password} placeholder="Create a secure password" onChange={handleChange} minLength="6" required />
          </div>

          <button className="sih-btn-primary" type="submit" disabled={loading}>
            {loading ? 'Creating account...' : 'Create Admin Account →'}
          </button>
        </form>

        <p className="sih-auth-footer">
          Already have an admin account?{' '}
          <Link to="/admin-login" className="sih-auth-link">Admin Login</Link>
        </p>
      </div>
    </div>
  );
};

export default AdminSignup;
