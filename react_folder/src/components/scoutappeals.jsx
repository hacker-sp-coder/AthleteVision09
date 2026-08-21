import React, { useState, useEffect } from 'react';
import { db } from '../firebase/config';
import {
  collection, query, orderBy, onSnapshot, doc, updateDoc, serverTimestamp
} from 'firebase/firestore';
import {
  Scale, Clock, CheckCircle, XCircle, ChevronRight,
  ArrowLeft, FileVideo, AlertCircle, TrendingUp
} from 'lucide-react';

const STATUS_CFG = {
  under_review: { label: 'Under Review', cls: 'appeal-badge--amber' },
  approved:     { label: 'Approved',     cls: 'appeal-badge--green' },
  rejected:     { label: 'Rejected',     cls: 'appeal-badge--red'   },
};

function StatusBadge({ status }) {
  const cfg = STATUS_CFG[status] || STATUS_CFG.under_review;
  return (
    <span className={`appeal-badge ${cfg.cls}`}>
      {status === 'under_review' && <Clock className="w-3 h-3" />}
      {status === 'approved'     && <CheckCircle className="w-3 h-3" />}
      {status === 'rejected'     && <XCircle className="w-3 h-3" />}
      {cfg.label}
    </span>
  );
}

function fmtDate(ts) {
  if (!ts) return '—';
  const d = ts.toDate ? ts.toDate() : new Date(ts);
  return d.toLocaleDateString('en-IN', {
    day: 'numeric', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
}

/* ─────────────────────────── component ─────────────────────────── */
const ScoutAppeals = () => {
  const [appeals,       setAppeals]       = useState([]);
  const [loading,       setLoading]       = useState(true);
  const [selected,      setSelected]      = useState(null);
  const [reviewerNotes, setReviewerNotes] = useState('');
  const [correctedScore,setCorrectedScore]= useState('');
  const [settling,      setSettling]      = useState(false);
  const [settleError,   setSettleError]   = useState('');

  /* all appeals, real-time */
  useEffect(() => {
    const q = query(collection(db, 'appeals'), orderBy('createdAt', 'desc'));
    const unsub = onSnapshot(q,
      snap => { setAppeals(snap.docs.map(d => ({ id: d.id, ...d.data() }))); setLoading(false); },
      err  => { console.error('Scout appeals error:', err); setLoading(false); }
    );
    return () => unsub();
  }, []);

  const openInspect = (ap) => {
    setSelected(ap);
    setReviewerNotes(ap.reviewerNotes || '');
    setCorrectedScore(ap.correctedResult?.overallScore ?? ap.claimedScore ?? '');
    setSettleError('');
  };

  const settleAppeal = async (decision) => {
    if (!selected) return;
    if (!reviewerNotes.trim()) {
      setSettleError('Add reviewer notes before deciding.');
      return;
    }
    setSettling(true);
    setSettleError('');
    const isApproved = decision === 'approved';
    const refundId   = isApproved ? `REF_${Date.now()}` : null;

    try {
      await updateDoc(doc(db, 'appeals', selected.id), {
        status:       decision,
        reviewerNotes: reviewerNotes.trim(),
        reviewedAt:   serverTimestamp(),
        ...(isApproved ? {
          correctedResult: {
            reps: Number(correctedScore) || 0,
            overallScore: Number(correctedScore) || 0,
          },
          scoreChanged:   Number(correctedScore) !== (selected.originalResult?.overallScore || 0),
          refundEligible: true,
          refundStatus:   'completed',
          refundId,
        } : {
          refundEligible: false,
          refundStatus:   'none',
        }),
      });
      /* optimistic local update so drawer reflects decision without re-fetch */
      setSelected(prev => ({
        ...prev,
        status:       decision,
        reviewerNotes: reviewerNotes.trim(),
        ...(isApproved && {
          correctedResult: { reps: Number(correctedScore) || 0, overallScore: Number(correctedScore) || 0 },
          refundStatus: 'completed',
          refundId,
        }),
      }));
    } catch (err) {
      console.error('Settle error:', err);
      setSettleError('Failed to update. Check Firestore permissions.');
    } finally {
      setSettling(false);
    }
  };

  /* analytics */
  const total    = appeals.length;
  const pending  = appeals.filter(a => a.status === 'under_review').length;
  const approved = appeals.filter(a => a.status === 'approved').length;
  const rejected = appeals.filter(a => a.status === 'rejected').length;

  /* ═══════════════════════════ RENDER ══════════════════════════ */
  return (
    <div>
      {/* ── Section header ── */}
      <div className="flex items-center justify-between mb-6 border-b border-slate-200 pb-5">
        <div>
          <div className="flex items-center gap-2">
            <Scale className="w-5 h-5 text-indigo-600" />
            <h2 className="text-xl font-extrabold text-slate-900">Appeals Management</h2>
          </div>
          <p className="text-slate-500 text-xs font-medium mt-1">
            Review and settle athlete assessment appeals
          </p>
        </div>
        {pending > 0 && (
          <span className="px-3 py-1.5 bg-amber-50 border border-amber-300 text-amber-700 text-xs font-bold rounded-full flex items-center gap-1.5 animate-pulse">
            <Clock className="w-3.5 h-3.5" />
            {pending} Pending Review
          </span>
        )}
      </div>

      {/* ── Analytics cards ── */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-8">
        {[
          { label: 'Total Appeals',  val: total,    color: 'text-slate-900',   bg: 'bg-white',       border: 'border-slate-200',  icon: <Scale className="w-4 h-4 text-slate-400" /> },
          { label: 'Pending Review', val: pending,  color: 'text-amber-700',   bg: 'bg-amber-50',    border: 'border-amber-200',  icon: <Clock className="w-4 h-4 text-amber-500" /> },
          { label: 'Approved',       val: approved, color: 'text-emerald-700', bg: 'bg-emerald-50',  border: 'border-emerald-200',icon: <CheckCircle className="w-4 h-4 text-emerald-500" /> },
          { label: 'Rejected',       val: rejected, color: 'text-red-700',     bg: 'bg-red-50',      border: 'border-red-200',    icon: <XCircle className="w-4 h-4 text-red-400" /> },
          {
            label: 'Appeal Rate',
            val: total > 0 ? `${((pending / total) * 100).toFixed(0)}%` : '0%',
            color: 'text-indigo-700', bg: 'bg-indigo-50', border: 'border-indigo-200',
            icon: <TrendingUp className="w-4 h-4 text-indigo-400" />
          },
        ].map((stat, i) => (
          <div key={i} className={`${stat.bg} border ${stat.border} rounded-xl p-4 shadow-sm`}>
            <div className="flex items-center gap-1.5 mb-2">
              {stat.icon}
              <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider">{stat.label}</span>
            </div>
            <div className={`text-2xl font-extrabold ${stat.color}`}>{stat.val}</div>
          </div>
        ))}
      </div>

      {/* ── Loading / empty ── */}
      {loading && (
        <div className="text-center py-16 text-slate-400 text-sm font-medium animate-pulse">
          Loading appeals…
        </div>
      )}

      {!loading && appeals.length === 0 && (
        <div className="flex flex-col items-center justify-center py-20 text-center">
          <Scale className="w-12 h-12 text-slate-200 mb-4" />
          <h3 className="text-slate-600 font-bold text-lg">No appeals submitted yet</h3>
          <p className="text-slate-400 text-sm mt-1">Athletes' appeals will appear here when submitted.</p>
        </div>
      )}

      {/* ── Appeals queue table ── */}
      {!loading && appeals.length > 0 && (
        <div className="bg-white border border-slate-200 rounded-xl shadow-sm overflow-hidden">
          <div className="border-b border-slate-100 px-5 py-3 flex items-center justify-between">
            <h3 className="text-xs font-bold text-slate-500 uppercase tracking-wider">Appeals Queue</h3>
            <span className="text-xs text-slate-400 font-medium">{total} total</span>
          </div>
          <div className="divide-y divide-slate-100">
            {appeals.map(ap => (
              <button
                key={ap.id}
                type="button"
                onClick={() => openInspect(ap)}
                className="w-full text-left px-5 py-4 hover:bg-slate-50/80 transition-colors group"
              >
                <div className="flex items-center justify-between gap-4">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-3 flex-wrap mb-1">
                      <span className="font-bold text-slate-900 text-sm">{ap.athleteName}</span>
                      <span className="text-[11px] text-slate-500">{ap.testType}</span>
                      <span className="text-[11px] font-mono text-slate-400 bg-slate-100 px-1.5 py-0.5 rounded">{ap.sessionCode}</span>
                      <StatusBadge status={ap.status} />
                    </div>
                    <div className="flex items-center gap-4 text-[11px] text-slate-400 font-medium">
                      <span>Claimed: <strong className="text-slate-600">{ap.claimedScore}</strong></span>
                      <span>₹{ap.feeAmount?.toLocaleString('en-IN')}</span>
                      <span>{fmtDate(ap.createdAt)}</span>
                    </div>
                  </div>
                  <ChevronRight className="w-4 h-4 text-slate-300 group-hover:text-indigo-500 shrink-0 transition-colors" />
                </div>
              </button>
            ))}
          </div>
        </div>
      )}

      {/* ══════════ Inspection + Decision Side Panel ══════════ */}
      {selected && (
        <div
          className="fixed inset-0 bg-slate-900/40 backdrop-blur-sm z-50 flex justify-end"
          onClick={() => setSelected(null)}
        >
          <div
            className="w-full max-w-lg bg-white border-l border-slate-200 h-full overflow-y-auto flex flex-col shadow-2xl"
            onClick={e => e.stopPropagation()}
          >
            {/* sticky header */}
            <div className="flex items-center justify-between px-6 py-4 border-b border-slate-100 sticky top-0 bg-white z-10">
              <button
                type="button"
                onClick={() => setSelected(null)}
                className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-sm font-bold transition-colors"
              >
                <ArrowLeft className="w-4 h-4" /> Close
              </button>
              <StatusBadge status={selected.status} />
            </div>

            <div className="flex-1 p-6 space-y-5">

              {/* Athlete */}
              <div>
                <span className="text-[10px] text-slate-400 font-bold uppercase tracking-wider block mb-1">Athlete</span>
                <h3 className="text-xl font-extrabold text-slate-900">{selected.athleteName}</h3>
                <p className="text-xs text-slate-500 mt-0.5">
                  ID: <span className="font-mono">{selected.athleteId?.slice(0, 10)}…</span>
                  &nbsp;•&nbsp;{fmtDate(selected.createdAt)}
                </p>
              </div>

              {/* Test details */}
              <div className="bg-slate-50 border border-slate-200 rounded-xl p-4">
                <span className="text-[10px] text-slate-400 font-bold uppercase tracking-wider block mb-3">Test Details</span>
                <div className="grid grid-cols-2 gap-4">
                  {[
                    ['Test Type',     selected.testType,                                          ''],
                    ['Session Code',  selected.sessionCode,                                       'font-mono'],
                    ['Original Score',selected.originalResult?.overallScore ?? '—',               'text-lg font-extrabold text-slate-700'],
                    ['Claimed Score', selected.claimedScore,                                      'text-lg font-extrabold text-indigo-600'],
                  ].map(([label, val, extra]) => (
                    <div key={label}>
                      <span className="text-[10px] text-slate-400 block mb-0.5">{label}</span>
                      <span className={`text-sm font-bold text-slate-800 ${extra}`}>{val}</span>
                    </div>
                  ))}
                </div>
              </div>

              {/* Reason */}
              <div className="bg-slate-50 border border-slate-200 rounded-xl p-4">
                <span className="text-[10px] text-slate-400 font-bold uppercase tracking-wider block mb-2">Reason</span>
                <p className="text-sm font-semibold text-slate-700">{selected.reason}</p>
                <p className="text-xs text-slate-500 mt-2 leading-relaxed">{selected.description}</p>
              </div>

              {/* Evidence */}
              {selected.videoUrl && (
                <div className="bg-slate-50 border border-slate-200 rounded-xl p-4">
                  <span className="text-[10px] text-slate-400 font-bold uppercase tracking-wider block mb-2">Evidence</span>
                  <a
                    href={selected.videoUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-2 text-sm text-indigo-600 font-bold hover:underline"
                  >
                    <FileVideo className="w-4 h-4" /> Watch Evidence Video
                  </a>
                </div>
              )}

              {/* ── Decision panel (only when under_review) ── */}
              {selected.status === 'under_review' ? (
                <div className="border border-slate-200 rounded-xl p-5 space-y-4">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">Scout Decision</span>

                  <div>
                    <label className="appeal-form-label">Corrected Score <span className="font-normal text-slate-400">(if approving)</span></label>
                    <input
                      type="number"
                      placeholder="Enter corrected score…"
                      value={correctedScore}
                      onChange={e => setCorrectedScore(e.target.value)}
                      className="appeal-form-input"
                    />
                  </div>

                  <div>
                    <label className="appeal-form-label">Reviewer Notes *</label>
                    <textarea
                      placeholder="Add decision rationale and notes for the athlete…"
                      value={reviewerNotes}
                      onChange={e => setReviewerNotes(e.target.value)}
                      rows={3}
                      className="appeal-form-input resize-none"
                    />
                  </div>

                  {settleError && (
                    <div className="appeal-form-error">
                      <AlertCircle className="w-4 h-4 shrink-0" /> {settleError}
                    </div>
                  )}

                  <div className="grid grid-cols-2 gap-3">
                    <button
                      type="button"
                      disabled={settling}
                      onClick={() => settleAppeal('approved')}
                      className="flex items-center justify-center gap-2 py-3 bg-emerald-600 hover:bg-emerald-700 text-white font-bold text-sm rounded-xl transition-colors disabled:opacity-60"
                    >
                      <CheckCircle className="w-4 h-4" />
                      {settling ? '…' : 'Approve & Refund'}
                    </button>
                    <button
                      type="button"
                      disabled={settling}
                      onClick={() => settleAppeal('rejected')}
                      className="flex items-center justify-center gap-2 py-3 bg-red-600 hover:bg-red-700 text-white font-bold text-sm rounded-xl transition-colors disabled:opacity-60"
                    >
                      <XCircle className="w-4 h-4" />
                      {settling ? '…' : 'Reject Appeal'}
                    </button>
                  </div>
                </div>
              ) : (
                /* Already settled */
                <div className={`rounded-xl p-4 border ${selected.status === 'approved' ? 'bg-emerald-50 border-emerald-200' : 'bg-red-50 border-red-200'}`}>
                  <span className={`text-[10px] font-bold uppercase tracking-wider block mb-2 ${selected.status === 'approved' ? 'text-emerald-600' : 'text-red-500'}`}>
                    Decision — {selected.status === 'approved' ? '✅ Approved' : '❌ Rejected'}
                  </span>
                  {selected.reviewerNotes && (
                    <p className="text-sm text-slate-700 leading-relaxed">{selected.reviewerNotes}</p>
                  )}
                  {selected.refundId && (
                    <p className="text-[11px] text-slate-500 mt-2 font-mono">Refund: {selected.refundId}</p>
                  )}
                </div>
              )}

              {/* Payment info */}
              <div className="bg-slate-50 border border-slate-100 rounded-xl p-4">
                <span className="text-[10px] text-slate-400 font-bold uppercase tracking-wider block mb-2">Payment</span>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-600 font-medium">₹{selected.feeAmount?.toLocaleString('en-IN')} paid</span>
                  <span className="font-mono text-slate-400 text-[10px]">{selected.paymentGatewayId}</span>
                </div>
              </div>

            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default ScoutAppeals;
