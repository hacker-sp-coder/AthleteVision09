import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { onAuthStateChanged } from 'firebase/auth';
import { doc, getDoc, updateDoc } from 'firebase/firestore';
import { ArrowLeft, CalendarDays, Camera, ChevronRight, Compass, Edit3, FileText, History, MessageSquare, Plus, Radio, ShieldCheck, Trophy, UserRound } from 'lucide-react';
import { auth, db } from '../firebase/config';
import './sportcv.css';

const DEFAULT_CV = {
  name: 'Athlete',
  position: 'Athlete',
  sport: 'Basketball',
  age: 18,
  location: 'Mumbai, Maharashtra',
  about: 'Passionate athlete with competitive experience, looking to grow and join a dedicated team.',
  height: '175 cm',
  weight: '68 kg',
  dominantHand: 'Right',
  jerseyNumber: '23',
  stats: { points: '18.5', assists: '7.2', fieldGoal: '45%', threePoint: '38%' },
  achievements: [
    { title: 'High School Varsity Captain', description: 'Led team to regional championships', year: '2019' },
    { title: 'City League All-Star', description: 'Selected for all-star game, scored 24 points', year: '2022' },
    { title: 'Tournament MVP', description: 'Phoenix Summer League Championship MVP', year: '2023' }
  ]
};

const SportCv = () => {
  const navigate = useNavigate();
  const [cv, setCv] = useState(DEFAULT_CV);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState(null);
  const [activeTab, setActiveTab] = useState('Awards');
  const [showAdd, setShowAdd] = useState(false);
  const [editingAchievement, setEditingAchievement] = useState(null);
  const [newAchievement, setNewAchievement] = useState({ title: '', description: '', year: '' });

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, async (user) => {
      if (!user) {
        navigate('/login');
        return;
      }
      try {
        const snapshot = await getDoc(doc(db, 'users', user.uid));
        const data = snapshot.data() || {};
        setCv((current) => ({
          ...current,
          name: data.name || user.displayName || current.name,
          sport: data.primarySport || current.sport,
          age: data.age || current.age,
          location: [data.district, data.state].filter(Boolean).join(', ') || current.location,
          height: data.heightCm ? `${data.heightCm} cm` : current.height,
          weight: data.weightKg ? `${data.weightKg} kg` : current.weight,
          about: data.sportCv?.about || current.about,
          position: data.sportCv?.position || current.position,
          dominantHand: data.sportCv?.dominantHand || current.dominantHand,
          jerseyNumber: data.sportCv?.jerseyNumber || current.jerseyNumber,
          stats: { ...current.stats, ...(data.sportCv?.stats || {}) },
          achievements: data.sportCv?.achievements || current.achievements
        }));
      } catch (error) {
        console.error('Sport CV error:', error);
      } finally {
        setLoading(false);
      }
    });
    return () => unsubscribe();
  }, [navigate]);

  const saveCv = async (section, value) => {
    const user = auth.currentUser;
    if (!user) return;
    const nextCv = { ...cv, [section]: value };
    setCv(nextCv);
    setEditing(null);
    await updateDoc(doc(db, 'users', user.uid), { sportCv: { about: nextCv.about, position: nextCv.position, dominantHand: nextCv.dominantHand, jerseyNumber: nextCv.jerseyNumber, stats: nextCv.stats, achievements: nextCv.achievements } });
  };

  const addAchievement = async (event) => {
    event.preventDefault();
    if (!newAchievement.title.trim()) return;
    const achievements = [...cv.achievements, newAchievement];
    setCv({ ...cv, achievements });
    setNewAchievement({ title: '', description: '', year: '' });
    setShowAdd(false);
    const user = auth.currentUser;
    if (user) await updateDoc(doc(db, 'users', user.uid), { 'sportCv.achievements': achievements });
  };

  const saveAchievement = async (index, achievement) => {
    const achievements = cv.achievements.map((item, itemIndex) => itemIndex === index ? achievement : item);
    setCv({ ...cv, achievements });
    setEditingAchievement(null);
    const user = auth.currentUser;
    if (user) await updateDoc(doc(db, 'users', user.uid), { 'sportCv.achievements': achievements });
  };

  if (loading) return <div className="sportcv-loading">Loading Sport CV...</div>;

  return (
    <main className="sportcv-page">
      <header className="sportcv-header"><h1>Sport CV</h1></header>

      <section className="sportcv-hero">
        <div className="sportcv-hero__cover"><span className="sportcv-avatar"><Camera size={27} /></span><button type="button" className="sportcv-avatar-edit" aria-label="Change photo"><Camera size={14} /></button></div>
        <div className="sportcv-hero__content"><h2>{cv.name}</h2><p>{cv.position} • {cv.sport}</p><span>Age {cv.age} <i /> {cv.location}</span><button type="button" className="sportcv-edit-profile" onClick={() => setEditing('hero')}><Edit3 size={14} /> Edit Profile</button></div>
        <div className="sportcv-stat-strip"><Stat value={cv.stats.points} label="Points Per Game" /><Stat value={cv.stats.assists} label="Assists" /><Stat value={cv.stats.fieldGoal} label="Field Goal %" /><Stat value={cv.stats.threePoint} label="3-Point %" /></div>
      </section>

      <EditableSection title="About Me" value={cv.about} editing={editing === 'about'} onEdit={() => setEditing('about')} onSave={saveCv} />

      <section className="sportcv-section"><div className="sportcv-section__title"><h3>Physical Stats</h3><button type="button" onClick={() => setEditing('physical')} aria-label="Edit physical stats"><Edit3 size={17} /></button></div><div className="sportcv-physical-grid">{[['height', 'Height'], ['weight', 'Weight'], ['dominantHand', 'Dominant Hand'], ['jerseyNumber', 'Jersey Number']].map(([key, label]) => <div key={key}><small>{label}</small>{editing === 'physical' ? <input value={cv[key]} onChange={(event) => setCv({ ...cv, [key]: event.target.value })} onBlur={() => saveCv(key, cv[key])} /> : <strong>{cv[key]}</strong>}</div>)}</div></section>

      <div className="sportcv-tabs">{['Awards', 'Videos', 'History', 'Certs'].map((tab) => <button type="button" key={tab} className={activeTab === tab ? 'is-active' : ''} onClick={() => setActiveTab(tab)}>{tab}</button>)}</div>
      {activeTab === 'Awards' ? <section className="sportcv-achievements"><div className="sportcv-achievements__head"><span>{cv.achievements.length} Achievements</span><button type="button" onClick={() => setShowAdd(true)}><Plus size={16} /> Add</button></div>{cv.achievements.map((achievement, index) => editingAchievement === index ? <AchievementEditor key={`${achievement.title}-${index}`} achievement={achievement} onCancel={() => setEditingAchievement(null)} onSave={(next) => saveAchievement(index, next)} /> : <article key={`${achievement.title}-${index}`} className="achievement-card"><span className="achievement-icon"><Trophy size={21} /></span><div><h4>{achievement.title}</h4><p>{achievement.description}</p><small><CalendarDays size={13} /> {achievement.year}</small></div><button type="button" aria-label="Edit achievement" onClick={() => setEditingAchievement(index)}><Edit3 size={14} /></button></article>)}</section> : <section className="sportcv-placeholder"><FileText size={24} /><h3>{activeTab}</h3><p>Your {activeTab.toLowerCase()} will appear here.</p></section>}

      {showAdd && <div className="sportcv-overlay"><form className="sportcv-modal" onSubmit={addAchievement}><div className="sportcv-modal__head"><h2>Add Achievement</h2><button type="button" onClick={() => setShowAdd(false)}>×</button></div><label>Title<input value={newAchievement.title} onChange={(event) => setNewAchievement({ ...newAchievement, title: event.target.value })} required /></label><label>Description<input value={newAchievement.description} onChange={(event) => setNewAchievement({ ...newAchievement, description: event.target.value })} /></label><label>Year<input type="number" value={newAchievement.year} onChange={(event) => setNewAchievement({ ...newAchievement, year: event.target.value })} /></label><button className="sportcv-primary" type="submit">Add Achievement</button></form></div>}

      <nav className="sportcv-nav"><button type="button" className="sportcv-nav__back" onClick={() => navigate('/profile')} aria-label="Back to profile"><ArrowLeft size={24} /></button><button type="button" onClick={() => navigate('/athlete-dashboard')}><Compass size={23} /><small>Discover</small></button><button type="button"><MessageSquare size={23} /><small>Messages</small></button><button type="button" onClick={() => navigate('/assessment')}><Radio size={23} /><small>Assessments</small></button><button type="button" onClick={() => navigate('/profile')}><UserRound size={23} /><small>Profile</small></button></nav>
    </main>
  );
};

const Stat = ({ value, label }) => <div><strong>{value}</strong><small>{label}</small></div>;
const AchievementEditor = ({ achievement, onCancel, onSave }) => { const [draft, setDraft] = useState(achievement); return <div className="achievement-editor"><input value={draft.title} onChange={(event) => setDraft({ ...draft, title: event.target.value })} /><input value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /><input value={draft.year} onChange={(event) => setDraft({ ...draft, year: event.target.value })} /><div><button type="button" onClick={onCancel}>Cancel</button><button type="button" onClick={() => onSave(draft)}>Save</button></div></div>; };
const EditableSection = ({ title, value, editing, onEdit, onSave }) => { const [draft, setDraft] = useState(value); return <section className="sportcv-section"><div className="sportcv-section__title"><h3>{title}</h3><button type="button" onClick={onEdit} aria-label={`Edit ${title}`}><Edit3 size={17} /></button></div>{editing ? <div className="sportcv-edit-row"><textarea value={draft} onChange={(event) => setDraft(event.target.value)} /><button type="button" onClick={() => onSave('about', draft)}>Save</button></div> : <p>{value}</p>}</section>; };

export default SportCv;
