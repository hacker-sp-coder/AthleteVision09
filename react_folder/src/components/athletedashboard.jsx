import React from 'react';
import { useNavigate } from 'react-router-dom';

const AthleteDashboard = () => {
  const navigate = useNavigate();

  const athlete = {
    name: "Mith Pawar",
    athleteId: "ATH-2026-8802",
    age: 19,
    gender: "Male",
    sport: "Volleyball",
    state: "Maharashtra",
    district: "Mumbai North",
    heightCm: 182,
    weightKg: 74,
    rank: "#12",
    track: "Track B (Specialist Outlier)",
    kisceStatus: "Selected - Balewadi, Pune",
    metrics: {
      verticalJump: "68 cm",
      horizontalJump: "245 cm",
      pushups: "45 reps",
      squats: "52 reps",
      crunches: "40 reps"
    }
  };

  return (
    <div className="min-h-screen bg-[#050505] text-white p-6 font-sans">
      {/* Top Header */}
      <div className="flex justify-between items-center mb-8 border-b border-zinc-800 pb-5">
        <div>
          <span className="bg-zinc-800 text-zinc-400 px-3 py-1 rounded-full text-xs uppercase font-semibold tracking-wider">
            Athlete Performance Portal
          </span>
          <h1 className="text-2xl font-bold mt-2">Welcome back, {athlete.name}</h1>
          <p className="text-zinc-500 text-xs mt-1">ID: {athlete.athleteId} • Target Sport: {athlete.sport} ({athlete.state})</p>
        </div>
        <button 
          onClick={() => navigate('/login')} 
          className="bg-zinc-900 hover:bg-zinc-800 text-rose-400 border border-zinc-800 px-4 py-2 rounded-lg text-xs font-semibold transition-colors"
        >
          Logout
        </button>
      </div>

      {/* Main Grid */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {/* Selection Status */}
        <div className="bg-[#0d0d0d] border border-zinc-800 rounded-xl p-5">
          <span className="text-zinc-400 text-xs uppercase font-semibold tracking-wider block mb-3">National Selection Status</span>
          <div className="bg-emerald-500/10 border border-emerald-500/20 text-emerald-400 p-3 rounded-lg font-bold text-sm mb-4">
            ✓ {athlete.track}
          </div>
          <p className="text-xs text-zinc-500">Assigned KISCE Facility:</p>
          <p className="font-semibold text-sm text-white mt-1">{athlete.kisceStatus}</p>
        </div>

        {/* National Ranking */}
        <div className="bg-[#0d0d0d] border border-zinc-800 rounded-xl p-5">
          <span className="text-zinc-400 text-xs uppercase font-semibold tracking-wider block mb-3">National Rank</span>
          <div className="text-4xl font-bold text-amber-400 font-mono">
            {athlete.rank} <span className="text-xs text-zinc-500 font-sans font-normal">/ National Pool</span>
          </div>
          <p className="text-xs text-zinc-400 mt-4">
            Physical Profile: <strong className="text-white">{athlete.heightCm} cm</strong> | <strong className="text-white">{athlete.weightKg} kg</strong>
          </p>
        </div>

        {/* Prototype Scope Banner */}
        <div className="bg-[#0d0d0d] border border-zinc-800 rounded-xl p-5 flex flex-col justify-between">
          <div>
            <span className="text-zinc-400 text-xs uppercase font-semibold tracking-wider block mb-2">Prototype Target Sports</span>
            <div className="flex flex-wrap gap-2 mt-2">
              {['High Jump', 'Long Jump', 'Basketball', 'Volleyball'].map((sp, idx) => (
                <span key={idx} className="bg-zinc-800 border border-zinc-700/50 text-zinc-300 text-xs px-2.5 py-1 rounded-md">
                  {sp}
                </span>
              ))}
            </div>
          </div>
          <span className="text-[11px] text-zinc-500 mt-4 block">Evaluated using 5 core fitness test protocols.</span>
        </div>

        {/* 5 Physical Fitness Test Benchmark Grid */}
        <div className="bg-[#0d0d0d] border border-zinc-800 rounded-xl p-6 md:col-span-3">
          <div className="flex justify-between items-center mb-6">
            <h3 className="text-lg font-bold text-white">5 Core Physical Benchmarks</h3>
            <button className="bg-white hover:bg-zinc-200 text-black px-3 py-1.5 rounded-lg text-xs font-bold transition-colors">
              + Upload Retest Score
            </button>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-5 gap-4">
            <div className="bg-[#121214] p-4 rounded-xl border border-zinc-800">
              <span className="text-zinc-400 text-xs block">Vertical Jump</span>
              <p className="text-xl font-bold text-white font-mono mt-1">{athlete.metrics.verticalJump}</p>
            </div>
            <div className="bg-[#121214] p-4 rounded-xl border border-zinc-800">
              <span className="text-zinc-400 text-xs block">Horizontal Jump</span>
              <p className="text-xl font-bold text-white font-mono mt-1">{athlete.metrics.horizontalJump}</p>
            </div>
            <div className="bg-[#121214] p-4 rounded-xl border border-zinc-800">
              <span className="text-zinc-400 text-xs block">Pushups</span>
              <p className="text-xl font-bold text-white font-mono mt-1">{athlete.metrics.pushups}</p>
            </div>
            <div className="bg-[#121214] p-4 rounded-xl border border-zinc-800">
              <span className="text-zinc-400 text-xs block">Squats</span>
              <p className="text-xl font-bold text-white font-mono mt-1">{athlete.metrics.squats}</p>
            </div>
            <div className="bg-[#121214] p-4 rounded-xl border border-zinc-800">
              <span className="text-zinc-400 text-xs block">Crunches</span>
              <p className="text-xl font-bold text-white font-mono mt-1">{athlete.metrics.crunches}</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default AthleteDashboard;