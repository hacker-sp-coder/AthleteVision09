import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { signOut, onAuthStateChanged } from 'firebase/auth';
import { doc, getDoc } from 'firebase/firestore';
import { ArrowLeft, Bell, ChevronRight, Compass, FileText, HelpCircle, LogOut, Mail, MapPin, MessageSquare, Radio, Shield, Sun, UserRound, UsersRound } from 'lucide-react';
import { auth, db } from '../firebase/config';
import './profile.css';

const Profile = () => {
  const navigate = useNavigate();
  const [profile, setProfile] = useState({ name: 'Athlete', sport: 'Athletics', state: 'Maharashtra', district: 'Mumbai' });
  const [loading, setLoading] = useState(true);
  const [notifications, setNotifications] = useState({ push: true, email: false, invites: true });
  const [darkMode, setDarkMode] = useState(false);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, async (user) => {
      if (!user) {
        navigate('/login');
        return;
      }

      try {
        const snapshot = await getDoc(doc(db, 'users', user.uid));
        const data = snapshot.data() || {};
        setProfile({
          name: data.name || user.displayName || user.email?.split('@')[0] || 'Athlete',
          sport: data.primarySport || 'Athletics',
          state: data.state || 'Maharashtra',
          district: data.district || 'Mumbai'
        });
      } catch (error) {
        console.error('Profile error:', error);
      } finally {
        setLoading(false);
      }
    });

    return () => unsubscribe();
  }, [navigate]);

  const handleLogout = async () => {
    await signOut(auth);
    navigate('/login');
  };

  if (loading) return <div className="profile-loading">Loading profile...</div>;

  return (
    <main className="profile-page">
      <header className="profile-header">
        <button type="button" className="profile-back" onClick={() => navigate('/athlete-dashboard')} aria-label="Back to dashboard"><ArrowLeft size={30} /></button>
        <h1>Settings</h1>
        <span className="profile-header__spacer" />
      </header>

      <button type="button" className="profile-identity" onClick={() => navigate('/athlete-dashboard')}>
        <span className="profile-avatar">{profile.name.charAt(0).toUpperCase()}</span>
        <span><strong>{profile.name}</strong><small>View and edit profile</small></span>
        <ChevronRight className="profile-chevron" size={28} />
      </button>

      <ProfileSection title="Account">
        <SettingsRow icon={FileText} label="Sports CV" onClick={() => navigate('/sport-cv')} />
        <SettingsRow icon={UserRound} label="Personal Information" />
        <SettingsRow icon={MapPin} label="Location" detail={`${profile.district}, ${profile.state}`} />
      </ProfileSection>

      <ProfileSection title="Appearance">
        <SettingsToggle icon={Sun} label="Dark Mode" detail="Toggle the app theme" checked={darkMode} onChange={() => setDarkMode(!darkMode)} />
      </ProfileSection>

      <ProfileSection title="Notifications">
        <SettingsToggle icon={Bell} label="Push Notifications" checked={notifications.push} onChange={() => setNotifications({ ...notifications, push: !notifications.push })} />
        <SettingsToggle icon={Mail} label="Email Notifications" checked={notifications.email} onChange={() => setNotifications({ ...notifications, email: !notifications.email })} />
        <SettingsToggle icon={UsersRound} label="Team Invites" checked={notifications.invites} onChange={() => setNotifications({ ...notifications, invites: !notifications.invites })} />
      </ProfileSection>

      <ProfileSection title="Privacy & Support">
        <SettingsRow icon={Shield} label="Privacy & Security" />
        <SettingsRow icon={HelpCircle} label="Help & Support" />
      </ProfileSection>

      <button type="button" className="profile-logout" onClick={handleLogout}><LogOut size={25} />Log Out</button>
    

      <nav className="profile-nav" aria-label="Athlete navigation">
        <button type="button" onClick={() => navigate('/athlete-dashboard')}><Compass size={24} /><small>Discover</small></button>
        <button type="button"><MessageSquare size={24} /><small>Messages</small></button>
        <button type="button" onClick={() => navigate('/assessment')}><Radio size={24} /><small>Assessments</small></button>
        <button type="button" className="is-active"><UserRound size={24} /><small>Profile</small></button>
      </nav>
    </main>
  );
};

const ProfileSection = ({ title, children }) => <section className="profile-section"><h2>{title}</h2><div className="profile-section__rows">{children}</div></section>;

const SettingsRow = ({ icon: Icon, label, detail, onClick }) => <button type="button" className="settings-row" onClick={onClick}><Icon size={27} /><span><strong>{label}</strong>{detail && <small>{detail}</small>}</span><ChevronRight size={27} /></button>;

const SettingsToggle = ({ icon: Icon, label, detail, checked, onChange }) => <div className="settings-row settings-toggle-row"><Icon size={27} /><span><strong>{label}</strong>{detail && <small>{detail}</small>}</span><button type="button" className={`toggle ${checked ? 'is-on' : ''}`} onClick={onChange} aria-label={`Toggle ${label}`}><span /></button></div>;

export default Profile;
