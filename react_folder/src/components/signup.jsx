import React, { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { createUserWithEmailAndPassword, signInWithPopup } from 'firebase/auth';
import { doc, setDoc } from 'firebase/firestore';
import { auth, db, googleProvider } from '../firebase/config';
import './signup.css';

const Signup = () => {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  const [formData, setFormData] = useState({
    email: '',
    password: '',
    name: '',
    dob: '',
    age: 0,
    ageGroup: '',
    gender: 'Male',
    primarySport: 'Football',
    district: '',
    state: '',
    heightCm: '',
    weightKg: ''
  });

  const calculateAgeGroup = (dobString) => {
    if (!dobString) return { age: 0, ageGroup: '' };
    const birthDate = new Date(dobString);
    const today = new Date();
    let age = today.getFullYear() - birthDate.getFullYear();
    const monthDiff = today.getMonth() - birthDate.getMonth();
    if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birthDate.getDate())) age--;

    let ageGroup = 'Senior / Open';
    if (age <= 12) ageGroup = 'U-12 (Sub-Junior)';
    else if (age <= 14) ageGroup = 'U-14 (Junior)';
    else if (age <= 17) ageGroup = 'U-17 (Youth)';
    else if (age <= 21) ageGroup = 'U-19 / U-21 (Development)';

    return { age, ageGroup };
  };

  const handleChange = (e) => {
    const { name, value } = e.target;
    setErrorMsg('');
    if (name === 'dob') {
      const { age, ageGroup } = calculateAgeGroup(value);
      setFormData(prev => ({ ...prev, dob: value, age, ageGroup }));
    } else {
      setFormData(prev => ({ ...prev, [name]: value }));
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setErrorMsg('');

    try {
      const userCredential = await createUserWithEmailAndPassword(auth, formData.email, formData.password);
      const uid = userCredential.user.uid;

      await setDoc(doc(db, "users", uid), {
        userId: uid,
        name: formData.name,
        email: formData.email,
        dob: formData.dob,
        age: formData.age,
        ageGroup: formData.ageGroup,
        gender: formData.gender,
        primarySport: formData.primarySport,
        district: formData.district,
        state: formData.state,
        heightCm: Number(formData.heightCm),
        weightKg: Number(formData.weightKg),
        role: 'athlete',
        createdAt: new Date().toISOString()
      });

      navigate('/athlete-dashboard');
    } catch (error) {
      console.error("Signup Error:", error);
      setErrorMsg(error.message.replace('Firebase: ', ''));
    } finally {
      setLoading(false);
    }
  };

  const handleGoogleSignIn = async () => {
    setLoading(true);
    setErrorMsg('');
    try {
      const result = await signInWithPopup(auth, googleProvider);
      const user = result.user;

      await setDoc(doc(db, "users", user.uid), {
        userId: user.uid,
        name: user.displayName || formData.name,
        email: user.email,
        dob: formData.dob || '',
        age: formData.age || 0,
        ageGroup: formData.ageGroup || 'General',
        gender: formData.gender || 'Male',
        primarySport: formData.primarySport || 'Football',
        district: formData.district || '',
        state: formData.state || '',
        heightCm: Number(formData.heightCm) || 0,
        weightKg: Number(formData.weightKg) || 0,
        role: 'athlete',
        createdAt: new Date().toISOString()
      }, { merge: true });

      navigate('/athlete-dashboard');
    } catch (error) {
      console.error("Google Signup Error:", error);
      setErrorMsg(error.message.replace('Firebase: ', ''));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="sih-auth-wrapper">
      <div className="sih-card">
        <span className="sih-badge">AthleteVision Portal</span>
        <h2 className="sih-title">Create Account</h2>
        <p className="sih-subtitle">Enter your athletic profile details to register.</p>

        {errorMsg && <div className="error-box" style={{ color: '#ef4444', backgroundColor: '#fee2e2', padding: '10px', borderRadius: '8px', marginBottom: '16px', fontSize: '0.85rem' }}>{errorMsg}</div>}

        <form onSubmit={handleSubmit} className="sih-form">
          <div className="input-wrapper">
            <label className="input-label">Full Name</label>
            <input className="sih-input" type="text" name="name" value={formData.name} placeholder="Enter your full name" onChange={handleChange} required />
          </div>

          <div className="form-grid-2">
            <div className="input-wrapper">
              <label className="input-label">Email Address</label>
              <input className="sih-input" type="email" name="email" value={formData.email} placeholder="you@example.com" onChange={handleChange} required />
            </div>
            <div className="input-wrapper">
              <label className="input-label">Password</label>
              <input className="sih-input" type="password" name="password" value={formData.password} placeholder="Create a password" onChange={handleChange} required />
            </div>
          </div>

          <div className="form-grid-2">
            <div className="input-wrapper">
              <label className="input-label">Date of Birth</label>
              <input className="sih-input" type="date" name="dob" value={formData.dob} onChange={handleChange} required />
            </div>
            <div className="input-wrapper">
              <label className="input-label">Age Category</label>
              <input className="sih-input" type="text" value={formData.ageGroup || 'Auto-Calculated'} disabled />
            </div>
          </div>

          <div className="form-grid-2">
            <div className="input-wrapper">
              <label className="input-label">Gender</label>
              <select className="sih-input" name="gender" value={formData.gender} onChange={handleChange}>
                <option value="Male">Male</option>
                <option value="Female">Female</option>
                <option value="Other">Other</option>
              </select>
            </div>
            <div className="input-wrapper">
              <label className="input-label">Primary Target Sport</label>
              <select className="sih-input" name="primarySport" value={formData.primarySport} onChange={handleChange}>
                <option value="Football">Football / Soccer</option>
                <option value="High Jump">High Jump</option>
                <option value="Long Jump">Long Jump</option>
                <option value="Basketball">Basketball</option>
                <option value="Volleyball">Volleyball</option>
              </select>
            </div>
          </div>

          <div className="form-grid-2">
            <div className="input-wrapper">
              <label className="input-label">District</label>
              <input className="sih-input" type="text" name="district" value={formData.district} placeholder="District" onChange={handleChange} required />
            </div>
            <div className="input-wrapper">
              <label className="input-label">State</label>
              <input className="sih-input" type="text" name="state" value={formData.state} placeholder="State" onChange={handleChange} required />
            </div>
          </div>

          <div className="form-grid-2">
            <div className="input-wrapper">
              <label className="input-label">Height (cm)</label>
              <input className="sih-input" type="number" name="heightCm" value={formData.heightCm} placeholder="178" onChange={handleChange} required />
            </div>
            <div className="input-wrapper">
              <label className="input-label">Weight (kg)</label>
              <input className="sih-input" type="number" name="weightKg" value={formData.weightKg} placeholder="68" onChange={handleChange} required />
            </div>
          </div>

          <button className="sih-btn-primary" type="submit" disabled={loading}>
            {loading ? "Registering..." : "Create Account →"}
          </button>
        </form>

        <div className="sih-divider"><span>OR</span></div>

        <button className="sih-btn-google" onClick={handleGoogleSignIn} type="button" disabled={loading}>
          Continue with Google
        </button>

    <p className="sih-auth-footer">
  Already have an account? <Link to="/login" className="sih-auth-link">Login here</Link>
</p>
      </div>
    </div>
  );
};

export default Signup;