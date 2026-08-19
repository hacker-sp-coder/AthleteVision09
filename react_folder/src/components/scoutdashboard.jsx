import React, { useState, useEffect, useRef } from 'react';
import gsap from 'gsap';
import { Trophy, Activity, MapPin, ChevronRight, Zap } from 'lucide-react';

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
    squats: 50,
    crunches: 45,
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
    squats: 45,
    crunches: 42,
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
    squats: 40,
    crunches: 38,
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
    squats: 48,
    crunches: 50,
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

  const drawerRef = useRef(null);

  useEffect(() => {
    gsap.fromTo(
      '.dashboard-card',
      { y: 20, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.5, stagger: 0.1, ease: 'power3.out' }
    );
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

  return (
    <div className="min-h-screen bg-[#050505] text-white p-6 font-sans">
      {/* Header */}
      <header className="flex justify-between items-center mb-8 border-b border-zinc-800 pb-5 dashboard-card">
        <div>
          <div className="flex items-center gap-2">
            <Trophy className="text-amber-400 w-6 h-6" />
            <h1 className="text-2xl font-bold tracking-tight">SAI Scout National Dashboard</h1>
          </div>
          <p className="text-zinc-400 text-xs mt-1">Prototype Scope: High Jump • Long Jump • Basketball • Volleyball</p>
        </div>
        <div className="flex items-center gap-3">
          <span className="px-3 py-1 bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-xs font-semibold rounded-full flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></span>
            5-Test Live Assessment
          </span>
        </div>
      </header>

      {/* Analytics Summary Banner */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
        {[
          { label: 'Total Evaluated', val: '12,480', sub: 'Across 28 States' },
          { label: 'Top Qualified Pool', val: '624', sub: 'Target 4 Sports' },
          { label: 'Generalists (Track A)', val: '436', sub: 'Balanced 5-Test Metrics' },
          { label: 'Specialist Outliers (Track B)', val: '188', sub: 'Extreme Jump Scores' },
        ].map((stat, idx) => (
          <div key={idx} className="dashboard-card bg-[#0d0d0d] border border-zinc-800 rounded-xl p-4">
            <span className="text-zinc-400 text-xs uppercase font-semibold tracking-wider">{stat.label}</span>
            <div className="text-2xl font-bold mt-1 text-white">{stat.val}</div>
            <span className="text-zinc-500 text-[11px] mt-1 block">{stat.sub}</span>
          </div>
        ))}
      </div>

      {/* Leaderboard Table */}
      <div className="dashboard-card bg-[#0d0d0d] border border-zinc-800 rounded-xl p-5 mb-6">
        <div className="flex flex-wrap items-center justify-between gap-4 mb-4">
          <h2 className="text-lg font-semibold flex items-center gap-2">
            <Activity className="w-5 h-5 text-indigo-400" />
            National Candidate Rankings
          </h2>

          <div className="flex items-center gap-3">
            <select 
              value={genderFilter} 
              onChange={(e) => setGenderFilter(e.target.value)}
              className="bg-[#121214] border border-zinc-800 text-zinc-300 text-xs rounded-lg px-3 py-2 outline-none"
            >
              <option value="All">All Genders</option>
              <option value="Male">Male</option>
              <option value="Female">Female</option>
            </select>

            <select 
              value={trackFilter} 
              onChange={(e) => setTrackFilter(e.target.value)}
              className="bg-[#121214] border border-zinc-800 text-zinc-300 text-xs rounded-lg px-3 py-2 outline-none"
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
              <tr className="border-b border-zinc-800 text-zinc-400 text-xs uppercase tracking-wider">
                <th className="py-3 px-4">Rank</th>
                <th className="py-3 px-4">Athlete</th>
                <th className="py-3 px-4">V-Jump / H-Jump</th>
                <th className="py-3 px-4">Pushups / Squats / Crunches</th>
                <th className="py-3 px-4">Recommended Sport</th>
                <th className="py-3 px-4 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-800/60 text-sm">
              {filteredAthletes.map((athlete) => (
                <tr 
                  key={athlete.id} 
                  className="hover:bg-zinc-900/50 transition-colors cursor-pointer"
                  onClick={() => setSelectedAthlete(athlete)}
                >
                  <td className="py-4 px-4 font-bold text-amber-400">#{athlete.rank}</td>
                  <td className="py-4 px-4">
                    <div className="font-semibold text-white">{athlete.name}</div>
                    <div className="text-xs text-zinc-500">{athlete.id} • {athlete.state}</div>
                  </td>
                  <td className="py-4 px-4 font-mono text-zinc-300">
                    <div>{athlete.vJump} cm <span className="text-xs text-zinc-500">(Vert)</span></div>
                    <div className="text-xs text-zinc-500">{athlete.hJump} cm (Horiz)</div>
                  </td>
                  <td className="py-4 px-4 font-mono text-xs text-zinc-400">
                    {athlete.pushups} P • {athlete.squats} S • {athlete.crunches} C
                  </td>
                  <td className="py-4 px-4">
                    <span className="text-xs font-semibold text-indigo-400 block">{athlete.recommendedSport}</span>
                    <span className="text-[10px] text-zinc-500">{athlete.track}</span>
                  </td>
                  <td className="py-4 px-4 text-right">
                    <button className="p-1.5 hover:bg-zinc-800 rounded-lg text-zinc-400 hover:text-white">
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
        <div className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex justify-end">
          <div ref={drawerRef} className="w-full max-w-md bg-[#0d0d0d] border-l border-zinc-800 h-full p-6 overflow-y-auto flex flex-col justify-between">
            <div>
              <div className="flex justify-between items-start mb-6">
                <div>
                  <span className="text-xs text-amber-400 font-semibold tracking-wider uppercase">Athlete Profile</span>
                  <h3 className="text-xl font-bold text-white mt-1">{selectedAthlete.name}</h3>
                  <p className="text-xs text-zinc-400">{selectedAthlete.id} • {selectedAthlete.district}, {selectedAthlete.state}</p>
                </div>
                <button onClick={() => setSelectedAthlete(null)} className="text-zinc-400 hover:text-white bg-zinc-800 px-2.5 py-1 rounded-md text-xs">✕</button>
              </div>

              {/* 5 Physical Tests Metrics Box */}
              <div className="bg-[#121214] border border-zinc-800/80 rounded-xl p-4 mb-6">
                <h4 className="text-xs font-semibold text-zinc-400 uppercase tracking-wider mb-3 flex items-center gap-1.5">
                  <Zap className="w-4 h-4 text-amber-400" />
                  5 Core Test Metrics
                </h4>
                <div className="grid grid-cols-2 gap-2 text-xs font-mono mb-3">
                  <div className="bg-[#18181b] p-2.5 rounded-lg border border-zinc-800">Vertical Jump: <span className="text-white font-bold">{selectedAthlete.vJump} cm</span></div>
                  <div className="bg-[#18181b] p-2.5 rounded-lg border border-zinc-800">Horizontal Jump: <span className="text-white font-bold">{selectedAthlete.hJump} cm</span></div>
                  <div className="bg-[#18181b] p-2.5 rounded-lg border border-zinc-800">Pushups: <span className="text-white font-bold">{selectedAthlete.pushups}</span></div>
                  <div className="bg-[#18181b] p-2.5 rounded-lg border border-zinc-800">Squats: <span className="text-white font-bold">{selectedAthlete.squats}</span></div>
                </div>
                <div className="bg-[#18181b] p-2.5 rounded-lg border border-zinc-800 text-xs font-mono">Crunches: <span className="text-white font-bold">{selectedAthlete.crunches}</span></div>
              </div>

              {/* Recommended Sport */}
              <div className="mb-6">
                <span className="text-xs font-semibold text-zinc-400 uppercase tracking-wider block mb-2">Algorithm Sport Recommendation</span>
                <div className="bg-indigo-500/10 border border-indigo-500/20 p-3 rounded-xl">
                  <div className="text-sm font-bold text-indigo-400">{selectedAthlete.recommendedSport}</div>
                  <div className="text-xs text-zinc-400 mt-0.5">{selectedAthlete.track}</div>
                </div>
              </div>

              {/* Assigned KISCE */}
              <div className="mb-6">
                <span className="text-xs font-semibold text-zinc-400 uppercase tracking-wider block mb-2">Assigned KISCE Centre</span>
                <div className="bg-[#121214] border border-zinc-800 p-3.5 rounded-xl flex items-start gap-2.5">
                  <MapPin className="w-4 h-4 text-indigo-400 shrink-0 mt-0.5" />
                  <div className="text-xs text-zinc-300 font-semibold">{selectedAthlete.kisceCenter}</div>
                </div>
              </div>
            </div>

            <button 
              onClick={() => alert(`Official Offer Letter Dispatched to ${selectedAthlete.name}`)}
              className="w-full py-3 bg-white hover:bg-zinc-200 text-black font-bold text-xs uppercase tracking-wider rounded-lg transition-colors mt-4"
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