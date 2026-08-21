import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { auth, db } from '../firebase/config';
import { onAuthStateChanged, signOut } from 'firebase/auth';
import { doc, getDoc } from 'firebase/firestore';
import { AlertTriangle, Bell, Compass, Dumbbell, MessageSquare, Radio, Search, UserRound } from 'lucide-react';
import athleteVisionLogo from '../assets/athletevision-logo.svg';
import './athletedashboard.css';

const DUMMY_COACHES = [
  { name: 'Neha Kulkarni', sports: ['Volleyball', 'Basketball'], specialty: 'Jump technique and court movement', location: 'Pune, Maharashtra', experience: '8 years', availability: 'Available this week' },
  { name: 'Arjun Mehta', sports: ['Football', 'Basketball'], specialty: 'Speed, agility and endurance', location: 'Mumbai, Maharashtra', experience: '10 years', availability: 'Available next week' },
  { name: 'Kavya Reddy', sports: ['Athletics', 'Long Jump'], specialty: 'Explosive power and landing form', location: 'Bengaluru, Karnataka', experience: '7 years', availability: 'Available this week' },
  { name: 'Rahul Deshmukh', sports: ['Volleyball', 'Athletics'], specialty: 'Strength and conditioning', location: 'Nashik, Maharashtra', experience: '12 years', availability: 'Available this month' }
];

const DUMMY_CAMPS = [
  { title: 'High Jump Masterclass', coach: 'Coach Smith', sport: 'Athletics' },
  { title: 'Sprint Mechanics', coach: 'Coach Johnson', sport: 'Athletics' },
  { title: 'Volleyball Power Lab', coach: 'Coach Neha', sport: 'Volleyball' }
];

const AthleteDashboard = () => {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');

  // Dynamic state for logged in athlete
  const [athlete, setAthlete] = useState({
    name: "Athlete",
    athleteId: "ATH-2026-0000",
    age: 0,
    gender: "Male",
    sport: "Volleyball",
    state: "Maharashtra",
    district: "Mumbai",
    heightCm: 175,
    weightKg: 68,
    rank: "#12",
    track: "Track B (Specialist Outlier)",
    kisceStatus: "Selected - KISCE Facility",
    metrics: {
      verticalJump: 68,
      horizontalJump: 245,
      pushups: 45,
      wallSit: 95
    }
  });

  useEffect(() => {
    // Listen for Auth State changes
    const unsubscribe = onAuthStateChanged(auth, async (user) => {
      if (user) {
        try {
          // Fetch user document from Firestore
          const userDocRef = doc(db, "users", user.uid);
          const userDocSnap = await getDoc(userDocRef);

          if (userDocSnap.exists()) {
            const userData = userDocSnap.data();
            setAthlete(prev => ({
              ...prev,
              name: userData.name || user.displayName || "Athlete",
              athleteId: `ATH-2026-${user.uid.slice(0, 4).toUpperCase()}`,
              sport: userData.primarySport || "Volleyball",
              state: userData.state || "Maharashtra",
              district: userData.district || "Mumbai",
              heightCm: userData.heightCm || 175,
              weightKg: userData.weightKg || 68,
            }));
          } else {
            // Fallback for direct auth without firestore doc
            setAthlete(prev => ({
              ...prev,
              name: user.displayName || user.email.split('@')[0],
              athleteId: `ATH-2026-${user.uid.slice(0, 4).toUpperCase()}`
            }));
          }
        } catch (err) {
          console.error("Error fetching user profile:", err);
        }
      } else {
        // If not logged in, redirect to login
        navigate('/login');
      }
      setLoading(false);
    });

    return () => unsubscribe();
  }, [navigate]);

  const handleLogout = async () => {
    await signOut(auth);
    navigate('/login');
  };


  if (loading) {
    return (
      <div className="min-h-screen bg-slate-50 text-slate-900 flex items-center justify-center font-sans">
        <div className="text-slate-500 text-sm font-medium animate-pulse">Loading Profile...</div>
      </div>
    );
  }

  return (
    <div className="athlete-dashboard min-h-screen bg-slate-50 text-slate-900 p-6 font-sans">
      {/* Top Header */}
      <div className="athlete-dashboard__header flex justify-between items-center mb-8 border-b border-slate-200 pb-5">
        <div>
          <h1 className="athlete-dashboard__greeting">Welcome back, {athlete.name}!</h1>
          <p className="athlete-dashboard__subgreeting">Ready to play?</p>
        </div>
        <div className="athlete-dashboard__actions">
          <button type="button" className="athlete-icon-button" aria-label="Notifications"><Bell size={25} /></button>
          <button type="button" onClick={handleLogout} className="athlete-logout">Logout</button>
        </div>
      </div>

      <section className="deadline-card">
        <div className="deadline-card__heading"><AlertTriangle size={25} /><div><h2>Upcoming Test Deadlines</h2><p>Important tests due soon</p></div></div>
        <div className="deadline-card__rows"><span>Push-ups</span><strong>Due tomorrow</strong><span>Wall Sit</span><span>Due Mon, Aug 24</span></div>
      </section>

      <label className="athlete-search">
        <Search size={25} />
        <input value={searchQuery} onChange={(event) => setSearchQuery(event.target.value)} placeholder="Search coaches, sports..." />
      </label>

      <section className="discovery-section">
        <div className="discovery-section__heading"><h2>Online Camps</h2><button type="button">See all</button></div>
        <div className="camp-scroller">
          {DUMMY_CAMPS.filter((camp) => !searchQuery || `${camp.title} ${camp.coach} ${camp.sport}`.toLowerCase().includes(searchQuery.toLowerCase())).map((camp) => (
            <article className="camp-card" key={camp.title}>
              <div className="camp-card__image"><Dumbbell size={43} /></div>
              <div className="camp-card__body"><h3>{camp.title}</h3><p>{camp.coach}</p><span>{camp.sport}</span></div>
            </article>
          ))}
        </div>
      </section>

      {/* Main Stats Grid */}
      <section className="snapshot-section">
        <div className="snapshot-section__heading">
          <h2>Your Performance Snapshot</h2>
          <span>Based on your athlete profile</span>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        
        {/* Selection Status */}
        <div className="bg-white border border-slate-200 rounded-xl p-5 shadow-sm">
          <span className="text-slate-500 text-xs uppercase font-bold tracking-wider block mb-3">National Selection Status</span>
          <div className="bg-emerald-50 border border-emerald-200 text-emerald-700 p-3 rounded-lg font-bold text-sm mb-4">
            ✓ {athlete.track}
          </div>
          <p className="text-xs text-slate-500 font-medium">Assigned KISCE Facility:</p>
          <p className="font-bold text-sm text-slate-900 mt-1">{athlete.kisceStatus}</p>
        </div>

        {/* National Ranking */}
        <div className="bg-white border border-slate-200 rounded-xl p-5 shadow-sm">
          <span className="text-slate-500 text-xs uppercase font-bold tracking-wider block mb-3">National Rank</span>
          <div className="text-4xl font-extrabold text-amber-600 font-mono">
            {athlete.rank} <span className="text-xs text-slate-500 font-sans font-normal">/ National Pool</span>
          </div>
          <p className="text-xs text-slate-600 mt-4 font-medium">
            Physical Profile: <strong className="text-slate-900">{athlete.heightCm} cm</strong> | <strong className="text-slate-900">{athlete.weightKg} kg</strong>
          </p>
        </div>

        {/* Dynamic Target Sports Box */}
        <div className="bg-white border border-slate-200 rounded-xl p-5 shadow-sm flex flex-col justify-between">
          <div>
            <span className="text-slate-500 text-xs uppercase font-bold tracking-wider block mb-2">Prototype Target Sports</span>
            <div className="flex flex-wrap gap-2 mt-2">
              {['High Jump', 'Long Jump', 'Basketball', 'Volleyball'].map((sp, idx) => {
                const isSelected = athlete.sport.includes(sp);
                return (
                  <span 
                    key={idx} 
                    className={`text-xs px-2.5 py-1 rounded-md border font-semibold ${
                      isSelected 
                        ? 'bg-emerald-50 border-emerald-300 text-emerald-700 font-bold' 
                        : 'bg-slate-100 border-slate-200 text-slate-500'
                    }`}
                  >
                    {sp} {isSelected ? '✓' : ''}
                  </span>
                );
              })}
            </div>
          </div>
          <span className="text-[11px] text-slate-500 font-medium mt-4 block">Evaluated using 5 core fitness test protocols.</span>
        </div>

        </div>
      </section>

      {/* Coach recommendations */}
      <section className="coach-section bg-white border border-slate-200 rounded-xl p-6 shadow-sm mt-6">
        <div className="flex flex-wrap items-start justify-between gap-3 mb-5">
          <div>
            <h2 className="text-lg font-bold text-slate-900">Coach Near Me</h2>
            <p className="text-sm text-slate-500 mt-1">Coaches matched to your interest in {athlete.sport}.</p>
          </div>
          <span className="bg-blue-50 border border-blue-200 text-blue-700 px-3 py-1 rounded-full text-xs font-bold">Based on your profile</span>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
          {DUMMY_COACHES
            .filter((coach) => coach.sports.some((sport) => sport.toLowerCase() === athlete.sport.toLowerCase()))
            .concat(DUMMY_COACHES.filter((coach) => !coach.sports.some((sport) => sport.toLowerCase() === athlete.sport.toLowerCase())))
            .filter((coach) => !searchQuery || `${coach.name} ${coach.sports.join(' ')} ${coach.location}`.toLowerCase().includes(searchQuery.toLowerCase()))
            .slice(0, 3)
            .map((coach) => (
              <article key={coach.name} className="bg-slate-50 border border-slate-200 rounded-xl p-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <h3 className="font-bold text-slate-900">{coach.name}</h3>
                    <p className="text-xs text-blue-600 font-semibold mt-1">{coach.sports.join(' • ')}</p>
                  </div>
                  <span className="w-10 h-10 rounded-full bg-blue-100 text-blue-700 grid place-items-center font-extrabold">{coach.name.split(' ').map((part) => part[0]).join('')}</span>
                </div>
                <p className="text-xs text-slate-600 mt-4">{coach.specialty}</p>
                <p className="text-xs text-slate-500 mt-2">{coach.location} • {coach.experience}</p>
                <div className="flex items-center justify-between gap-2 mt-4 pt-3 border-t border-slate-200">
                  <span className="text-[11px] text-emerald-700 font-bold">{coach.availability}</span>
                  <button type="button" className="text-xs text-blue-700 font-bold hover:underline">View profile</button>
                </div>
              </article>
            ))}
        </div>
      </section>

      <nav className="athlete-bottom-nav" aria-label="Athlete navigation">
        <div className="dashboard-brand" aria-label="AthleteVision"><img src={athleteVisionLogo} alt="AthleteVision logo" /></div>
        <button type="button" className="is-active"><Compass size={22} /><span>Discover</span></button>
        <button type="button"><MessageSquare size={22} /><span>Messages</span></button>
        <button type="button" onClick={() => navigate('/assessment')}><Radio size={22} /><span>Assessments</span></button>
        <button type="button" onClick={() => navigate('/profile')}><UserRound size={22} /><span>Profile</span></button>
      </nav>
    </div>
  );
};

export default AthleteDashboard;