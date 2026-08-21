import React, { useState, useEffect, useRef } from 'react';
import gsap from 'gsap';
import { Trophy, Activity, MapPin, ChevronRight, Zap, Check, Eye, EyeOff } from 'lucide-react';
import { doc, onSnapshot, setDoc } from 'firebase/firestore';
import { db } from '../firebase/config';

const ASSESSMENT_TESTS = [
  { id: 'vertical-jump', name: 'Vertical Jump', unit: 'cm', description: 'Lower-body explosiveness' },
  { id: 'horizontal-jump', name: 'Horizontal Jump', unit: 'cm', description: 'Forward power and speed' },
  { id: 'pushups', name: 'Push-ups', unit: 'reps', description: 'Upper-body endurance' },
  { id: 'wall-sit', name: 'Wall Sit', unit: 'sec', description: 'Leg endurance' }
];

const INITIAL_ATHLETES = [
  {
    id: 'ATH-8092',
    name: 'Aarav Sharma',
    age: 16,
    gender: 'Male',
    state: 'Maharashtra',
    district: 'Pune',
    vJump: 68.5,
    hJump: 240,
    pushups: 42,
    wallSit: 95,
    zJump: 2.25,
    zPushups: 1.80,
    compositeScore: 2.02,
    track: 'Track B (Specialist Outlier)',
    recommendedSport: 'High Jump / Volleyball',
    kisceCenter: 'Shree Shivchhatrapati Sports Complex (Balewadi, Pune)',
    rank: 1
  },
  {
    id: 'ATH-4105',
    name: 'Riya Patel',
    age: 17,
    gender: 'Female',
    state: 'Gujarat',
    district: 'Ahmedabad',
    vJump: 52.0,
    hJump: 215,
    pushups: 38,
    wallSit: 88,
    zJump: 1.95,
    zPushups: 2.10,
    compositeScore: 2.02,
    track: 'Track A (Generalist)',
    recommendedSport: 'Basketball / Volleyball',
    kisceCenter: 'SAI NCOE Gandhinagar',
    rank: 2
  },
  {
    id: 'ATH-9931',
    name: 'Vikram Gowda',
    age: 18,
    gender: 'Male',
    state: 'Karnataka',
    district: 'Bengaluru Urban',
    vJump: 71.0,
    hJump: 260,
    pushups: 30,
    wallSit: 76,
    zJump: 2.45,
    zPushups: 1.10,
    compositeScore: 1.77,
    track: 'Track B (Specialist Outlier)',
    recommendedSport: 'Long Jump / High Jump',
    kisceCenter: 'SAI NCOE Bengaluru',
    rank: 3
  },
  {
    id: 'ATH-1044',
    name: 'Priya Das',
    age: 15,
    gender: 'Female',
    state: 'Assam',
    district: 'Guwahati',
    vJump: 48.0,
    hJump: 195,
    pushups: 35,
    wallSit: 92,
    zJump: 1.65,
    zPushups: 1.90,
    compositeScore: 1.77,
    track: 'Track A (Generalist)',
    recommendedSport: 'Basketball',
    kisceCenter: 'State Sports Academy, Sarusajai (Guwahati)',
    rank: 4
  }
];

const ScoutDashboard = () => {
  const [athletes] = useState(INITIAL_ATHLETES);
  const [selectedAthlete, setSelectedAthlete] = useState(null);
  const [genderFilter, setGenderFilter] = useState('All');
  const [trackFilter, setTrackFilter] = useState('All');
  const [publishedTests, setPublishedTests] = useState([]);
  const [publishError, setPublishError] = useState('');

  const drawerRef = useRef(null);

  useEffect(() => {
    gsap.fromTo(
      '.dashboard-card',
      { y: 20, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.5, stagger: 0.1, ease: 'power3.out' }
    );
  }, []);

  useEffect(() => {
    const unsubscribe = onSnapshot(doc(db, 'assessmentConfig', 'current'), (snapshot) => {
      const activeTests = snapshot.data()?.activeTests || [];
      setPublishedTests(activeTests.map((test) => typeof test === 'string' ? test : test.id));
    }, (error) => {
      console.error('Assessment config error:', error);
      setPublishError('Could not load published tests. Check Firestore permissions.');
    });

    return () => unsubscribe();
  }, []);

  useEffect(() => {
    if (selectedAthlete && drawerRef.current) {
      gsap.fromTo(
        drawerRef.current,
        { x: '100%' },
        { x: '0%', duration: 0.4, ease: 'power3.out' }
      );
    }
  }, [selectedAthlete]);

  const filteredAthletes = athletes.filter(a => {
    const matchesGender = genderFilter === 'All' || a.gender === genderFilter;
    const matchesTrack = trackFilter === 'All' || 
      (trackFilter === 'Generalist' && a.track.includes('Track A')) ||
      (trackFilter === 'Specialist' && a.track.includes('Track B'));
    return matchesGender && matchesTrack;
  });

  const toggleTestPublication = async (testId) => {
    setPublishError('');
    const nextTestIds = publishedTests.includes(testId)
      ? publishedTests.filter((id) => id !== testId)
      : [...publishedTests, testId];

    try {
      await setDoc(doc(db, 'assessmentConfig', 'current'), {
        activeTests: ASSESSMENT_TESTS.filter((test) => nextTestIds.includes(test.id)),
        updatedAt: new Date().toISOString()
      }, { merge: true });
      setPublishedTests(nextTestIds);
    } catch (error) {
      console.error('Assessment publish error:', error);
      setPublishError('Could not update tests. Check that this account can write to Firestore.');
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 text-slate-900 p-6 font-sans">
      {/* Header */}
      <header className="flex justify-between items-center mb-8 border-b border-slate-200 pb-5 dashboard-card">
        <div>
          <div className="flex items-center gap-2">
            <Trophy className="text-amber-500 w-6 h-6" />
            <h1 className="text-2xl font-extrabold tracking-tight text-slate-900">SAI Scout National Dashboard</h1>
          </div>
          <p className="text-slate-500 text-xs font-medium mt-1">Authority assessment and athlete recommendation control centre</p>
        </div>
        <div className="flex items-center gap-3">
          <span className="px-3 py-1 bg-emerald-50 text-emerald-700 border border-emerald-200 text-xs font-bold rounded-full flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
            {publishedTests.length}/{ASSESSMENT_TESTS.length} Tests Published
          </span>
        </div>
      </header>

      {publishError && (
        <div className="dashboard-card bg-red-50 border border-red-200 text-red-700 rounded-xl px-4 py-3 mb-6 text-xs font-semibold">
          {publishError}
        </div>
      )}

      {/* Assessment Publishing Controls */}
      <section className="dashboard-card bg-white border border-slate-200 rounded-xl p-5 mb-8 shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-4 mb-5">
          <div>
            <h2 className="text-lg font-bold text-slate-900">Assessment Tests</h2>
            <p className="text-xs text-slate-500 font-medium mt-1">Publish tests here before athletes can see them in their dashboard.</p>
          </div>
          <span className={`px-3 py-1 rounded-full text-xs font-bold ${publishedTests.length ? 'bg-blue-50 text-blue-700 border border-blue-200' : 'bg-slate-100 text-slate-500 border border-slate-200'}`}>
            {publishedTests.length ? 'Live for athletes' : 'No tests available to athletes'}
          </span>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
          {ASSESSMENT_TESTS.map((test) => {
            const isPublished = publishedTests.includes(test.id);
            return (
              <button
                key={test.id}
                type="button"
                onClick={() => toggleTestPublication(test.id)}
                className={`text-left p-4 rounded-xl border transition-colors ${isPublished ? 'border-blue-300 bg-blue-50/70' : 'border-slate-200 bg-slate-50 hover:bg-slate-100'}`}
              >
                <div className="flex items-start justify-between gap-2">
                  <span className="text-sm font-bold text-slate-900">{test.name}</span>
                  {isPublished ? <Eye className="w-4 h-4 text-blue-600" /> : <EyeOff className="w-4 h-4 text-slate-400" />}
                </div>
                <span className="text-[11px] text-slate-500 block mt-1">{test.description} • {test.unit}</span>
                <span className={`inline-flex items-center gap-1 text-[11px] font-bold mt-3 ${isPublished ? 'text-blue-700' : 'text-slate-500'}`}>
                  {isPublished && <Check className="w-3.5 h-3.5" />}
                  {isPublished ? 'Published' : 'Publish test'}
                </span>
              </button>
            );
          })}
        </div>
      </section>

      {/* Analytics Summary Banner */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
        {[
          { label: 'Total Evaluated', val: '12,480', sub: 'Across 28 States' },
          { label: 'Top Qualified Pool', val: '624', sub: 'Target 4 Sports' },
          { label: 'Generalists (Track A)', val: '436', sub: 'Balanced assessment metrics' },
          { label: 'Specialist Outliers (Track B)', val: '188', sub: 'Extreme jump scores' },
        ].map((stat, idx) => (
          <div key={idx} className="dashboard-card bg-white border border-slate-200 rounded-xl p-4 shadow-sm">
            <span className="text-slate-500 text-xs uppercase font-bold tracking-wider">{stat.label}</span>
            <div className="text-2xl font-extrabold mt-1 text-slate-900">{stat.val}</div>
            <span className="text-slate-500 text-[11px] mt-1 block font-medium">{stat.sub}</span>
          </div>
        ))}
      </div>

      {/* Leaderboard Table */}
      <div className="dashboard-card bg-white border border-slate-200 rounded-xl p-5 mb-6 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-4 mb-4">
          <h2 className="text-lg font-bold text-slate-900 flex items-center gap-2">
            <Activity className="w-5 h-5 text-indigo-600" />
            National Candidate Rankings
          </h2>

          <div className="flex items-center gap-3">
            <select 
              value={genderFilter} 
              onChange={(e) => setGenderFilter(e.target.value)}
              className="bg-slate-50 border border-slate-300 text-slate-700 font-semibold text-xs rounded-lg px-3 py-2 outline-none focus:border-indigo-500"
            >
              <option value="All">All Genders</option>
              <option value="Male">Male</option>
              <option value="Female">Female</option>
            </select>

            <select 
              value={trackFilter} 
              onChange={(e) => setTrackFilter(e.target.value)}
              className="bg-slate-50 border border-slate-300 text-slate-700 font-semibold text-xs rounded-lg px-3 py-2 outline-none focus:border-indigo-500"
            >
              <option value="All">All Tracks</option>
              <option value="Generalist">Track A (Generalist)</option>
              <option value="Specialist">Track B (Specialist Outlier)</option>
            </select>
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 text-slate-500 text-xs uppercase tracking-wider font-bold">
                <th className="py-3 px-4">Rank</th>
                <th className="py-3 px-4">Athlete</th>
                <th className="py-3 px-4">V-Jump / H-Jump</th>
                <th className="py-3 px-4">Push-ups / Wall Sit</th>
                <th className="py-3 px-4">Recommended Sport</th>
                <th className="py-3 px-4 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 text-sm font-medium">
              {filteredAthletes.map((athlete) => (
                <tr 
                  key={athlete.id} 
                  className="hover:bg-slate-50/80 transition-colors cursor-pointer"
                  onClick={() => setSelectedAthlete(athlete)}
                >
                  <td className="py-4 px-4 font-extrabold text-amber-600">#{athlete.rank}</td>
                  <td className="py-4 px-4">
                    <div className="font-bold text-slate-900">{athlete.name}</div>
                    <div className="text-xs text-slate-500">{athlete.id} • {athlete.state}</div>
                  </td>
                  <td className="py-4 px-4 font-mono text-slate-700">
                    <div>{athlete.vJump} cm <span className="text-xs text-slate-400 font-sans">(Vert)</span></div>
                    <div className="text-xs text-slate-400 font-sans">{athlete.hJump} cm (Horiz)</div>
                  </td>
                  <td className="py-4 px-4 font-mono text-xs text-slate-600">
                    {athlete.pushups} reps • {athlete.wallSit} sec
                  </td>
                  <td className="py-4 px-4">
                    <span className="text-xs font-bold text-indigo-600 block">{athlete.recommendedSport}</span>
                    <span className="text-[10px] text-slate-500 font-medium">{athlete.track}</span>
                  </td>
                  <td className="py-4 px-4 text-right">
                    <button className="p-1.5 hover:bg-slate-200 rounded-lg text-slate-400 hover:text-slate-900 transition-colors">
                      <ChevronRight className="w-4 h-4" />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Candidate Inspector Drawer */}
      {selectedAthlete && (
        <div className="fixed inset-0 bg-slate-900/40 backdrop-blur-sm z-50 flex justify-end">
          <div ref={drawerRef} className="w-full max-w-md bg-white border-l border-slate-200 h-full p-6 overflow-y-auto flex flex-col justify-between shadow-2xl">
            <div>
              <div className="flex justify-between items-start mb-6">
                <div>
                  <span className="text-xs text-amber-600 font-bold tracking-wider uppercase">Athlete Profile</span>
                  <h3 className="text-xl font-extrabold text-slate-900 mt-1">{selectedAthlete.name}</h3>
                  <p className="text-xs text-slate-500 font-medium">{selectedAthlete.id} • {selectedAthlete.district}, {selectedAthlete.state}</p>
                </div>
                <button 
                  onClick={() => setSelectedAthlete(null)} 
                  className="text-slate-500 hover:text-slate-900 bg-slate-100 hover:bg-slate-200 px-2.5 py-1 rounded-md text-xs font-bold transition-colors"
                >
                  ✕
                </button>
              </div>

              {/* 5 Physical Tests Metrics Box */}
              <div className="bg-slate-50 border border-slate-200 rounded-xl p-4 mb-6">
                <h4 className="text-xs font-bold text-slate-600 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                  <Zap className="w-4 h-4 text-amber-500" />
                  4 Core Test Metrics
                </h4>
                <div className="grid grid-cols-2 gap-2 text-xs font-mono mb-3">
                  <div className="bg-white p-2.5 rounded-lg border border-slate-200 text-slate-600">Vertical Jump: <span className="text-slate-900 font-bold">{selectedAthlete.vJump} cm</span></div>
                  <div className="bg-white p-2.5 rounded-lg border border-slate-200 text-slate-600">Horizontal Jump: <span className="text-slate-900 font-bold">{selectedAthlete.hJump} cm</span></div>
                  <div className="bg-white p-2.5 rounded-lg border border-slate-200 text-slate-600">Push-ups: <span className="text-slate-900 font-bold">{selectedAthlete.pushups} reps</span></div>
                  <div className="bg-white p-2.5 rounded-lg border border-slate-200 text-slate-600">Wall Sit: <span className="text-slate-900 font-bold">{selectedAthlete.wallSit} sec</span></div>
                </div>
              </div>

              {/* Recommended Sport */}
              <div className="mb-6">
                <span className="text-xs font-bold text-slate-500 uppercase tracking-wider block mb-2">Algorithm Sport Recommendation</span>
                <div className="bg-indigo-50 border border-indigo-200 p-3 rounded-xl">
                  <div className="text-sm font-bold text-indigo-700">{selectedAthlete.recommendedSport}</div>
                  <div className="text-xs text-indigo-900/70 font-medium mt-0.5">{selectedAthlete.track}</div>
                </div>
              </div>

              {/* Assigned KISCE */}
              <div className="mb-6">
                <span className="text-xs font-bold text-slate-500 uppercase tracking-wider block mb-2">Assigned KISCE Centre</span>
                <div className="bg-slate-50 border border-slate-200 p-3.5 rounded-xl flex items-start gap-2.5">
                  <MapPin className="w-4 h-4 text-indigo-600 shrink-0 mt-0.5" />
                  <div className="text-xs text-slate-800 font-bold">{selectedAthlete.kisceCenter}</div>
                </div>
              </div>
            </div>

            <button 
              onClick={() => alert(`Official Offer Letter Dispatched to ${selectedAthlete.name}`)}
              className="w-full py-3 bg-slate-900 hover:bg-slate-800 text-white font-bold text-xs uppercase tracking-wider rounded-lg transition-colors mt-4 shadow-sm"
            >
              Issue KISCE Admission Offer →
            </button>
          </div>
        </div>
      )}
    </div>
  );
};

export default ScoutDashboard;