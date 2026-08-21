import React, { useState, useEffect } from 'react';
import { db } from '../firebase/config';
import {
  collection, query, where, orderBy, onSnapshot, addDoc, serverTimestamp, doc
} from 'firebase/firestore';
import {
  Scale, Plus, X, ChevronRight, AlertCircle, CheckCircle,
  XCircle, Clock, CreditCard, FileVideo, ArrowLeft
} from 'lucide-react';

const TEST_TYPES = ['Vertical Jump', 'Horizontal Jump', 'Push-ups', 'Wall Sit'];

const APPEAL_REASONS = [
  'Incorrect repetition count',
  'Pose detection error',
  'Camera issue',
  'Technical glitch',
  'Other',
];

const STATUS_CFG = {
  under_review: { label: 'Under Review',              cls: 'appeal-badge--amber'   },
  approved:     { label: 'Approved (Refund Initiated)', cls: 'appeal-badge--green'   },
  rejected:     { label: 'Rejected',                  cls: 'appeal-badge--red'     },
  payment_pending:{ label: 'Payment Pending',          cls: 'appeal-badge--blue'    },
};

const EMPTY_FORM = {
  testType: '', sessionCode: '', reason: '',
  claimedScore: '', description: '', videoUrl: '',
};

/* ─────────────────────────── helpers ─────────────────────────── */
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
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
}

/* ─────────────────────────── component ─────────────────────────── */
const AthleteAppeals = ({ athleteId, athleteName }) => {
  const [appeals,       setAppeals]       = useState([]);
  const [loading,       setLoading]       = useState(true);
  const [selected,      setSelected]      = useState(null);
  const [showModal,     setShowModal]     = useState(false);
  const [formData,      setFormData]      = useState(EMPTY_FORM);
  const [formStep,      setFormStep]      = useState('form'); // 'form' | 'payment' | 'success'
  const [submitting,    setSubmitting]    = useState(false);
  const [formError,     setFormError]     = useState('');
  const [publishedTests,setPublishedTests]= useState([]);

  /* fetch active published tests for auto session codes */
  useEffect(() => {
    const unsub = onSnapshot(doc(db, 'assessmentConfig', 'current'), (snapshot) => {
      const tests = snapshot.data()?.activeTests || [];
      setPublishedTests(tests);
    });
    return () => unsub();
  }, []);

  /* real-time appeals for this athlete */
  useEffect(() => {
    if (!athleteId) { setLoading(false); return; }
    const q = query(
      collection(db, 'appeals'),
      where('athleteId', '==', athleteId),
      orderBy('createdAt', 'desc')
    );
    const unsub = onSnapshot(q,
      snap => { setAppeals(snap.docs.map(d => ({ id: d.id, ...d.data() }))); setLoading(false); },
      err  => { console.error('Appeals fetch error:', err); setLoading(false); }
    );
    return () => unsub();
  }, [athleteId]);

  // When test type changes, auto-fill session code if available
  const handleTestTypeChange = (selectedType) => {
    const matched = publishedTests.find(
      (t) => t.name === selectedType || t.id === selectedType.toLowerCase().replace(' ', '-')
    );
    const autoCode = matched?.sessionCode || '';
    setFormData((prev) => ({
      ...prev,
      testType: selectedType,
      sessionCode: autoCode || prev.sessionCode
    }));
  };

  /* ── helpers ── */
  const resetModal = () => {
    setShowModal(false); setFormData(EMPTY_FORM);
    setFormStep('form');  setFormError('');
  };

  const openModal = () => { setShowModal(true); setFormStep('form'); setFormData(EMPTY_FORM); setFormError(''); };

  const handleFormNext = () => {
    const { testType, sessionCode, reason, claimedScore, description } = formData;
    if (!testType || !sessionCode || !reason || !claimedScore || !description) {
      setFormError('Please fill in all required fields.');
      return;
    }
    setFormError('');
    setFormStep('payment');
  };

  const handleMockPayment = async () => {
    setSubmitting(true);
    try {
      await addDoc(collection(db, 'appeals'), {
        athleteId,
        athleteName,
        testType:        formData.testType,
        sessionCode:     formData.sessionCode.toUpperCase(),
        reason:          formData.reason,
        description:     formData.description,
        claimedScore:    Number(formData.claimedScore),
        originalResult:  { reps: 0, overallScore: 0 },
        correctedResult: null,
        videoUrl:        formData.videoUrl || null,
        feeAmount:       1500,
        currency:        'INR',
        paymentStatus:   'paid',
        paymentGatewayId: `pay_mock_${Date.now()}`,
        status:          'under_review',
        reviewerNotes:   null,
        scoreChanged:    false,
        refundEligible:  false,
        refundStatus:    'none',
        refundId:        null,
        createdAt:       serverTimestamp(),
        reviewedAt:      null,
      });
      setFormStep('success');
    } catch (err) {
      console.error('Appeal submit error:', err);
      setFormError('Failed to submit. Check your connection and try again.');
      setFormStep('payment');
    } finally {
      setSubmitting(false);
    }
  };

  /* ═══════════════════════════ RENDER ══════════════════════════ */
  return (
    <div className="appeals-page">

      {/* ── Page header ── */}
      <div className="appeals-page__header">
        <div>
          <h2 className="appeals-page__title">
            <Scale className="w-6 h-6 text-indigo-600" /> My Appeals
          </h2>
          <p className="appeals-page__subtitle">Track and manage your assessment appeal requests</p>
        </div>
        <button type="button" className="appeals-btn-new" onClick={openModal}>
          <Plus className="w-4 h-4" /> New Appeal
        </button>
      </div>

      {/* ── Loading ── */}
      {loading && (
        <div className="appeals-loading">Loading appeals…</div>
      )}

      {/* ── Empty state ── */}
      {!loading && appeals.length === 0 && (
        <div className="appeals-empty">
          <Scale className="w-14 h-14 text-slate-200 mb-4" />
          <h3 className="text-slate-700 font-bold text-lg">No appeals yet</h3>
          <p className="text-slate-500 text-sm mt-1 max-w-xs text-center leading-relaxed">
            If you believe your assessment score was incorrect, submit an appeal for review.
          </p>
          <button type="button" className="appeals-btn-new mt-5" onClick={openModal}>
            <Plus className="w-4 h-4" /> Submit First Appeal
          </button>
        </div>
      )}

      {/* ── Appeals list ── */}
      {!loading && appeals.length > 0 && (
        <div className="appeals-list">
          {appeals.map(ap => (
            <button
              key={ap.id}
              type="button"
              className="appeal-card"
              onClick={() => setSelected(ap)}
            >
              <div className="appeal-card__left">
                <div className="appeal-card__top">
                  <span className="appeal-card__test">{ap.testType}</span>
                  <span className="appeal-card__code">{ap.sessionCode}</span>
                  <StatusBadge status={ap.status} />
                </div>
                <div className="appeal-card__meta">
                  <span>Claimed: <strong>{ap.claimedScore}</strong></span>
                  <span>Fee: <strong>₹{ap.feeAmount?.toLocaleString('en-IN')}</strong></span>
                  <span>{fmtDate(ap.createdAt)}</span>
                </div>
                <p className="appeal-card__reason">{ap.reason}</p>
              </div>
              <ChevronRight className="w-4 h-4 text-slate-300 group-hover:text-indigo-500 shrink-0" />
            </button>
          ))}
        </div>
      )}

      {/* ══════════ Appeal Detail Drawer ══════════ */}
      {selected && (
        <div className="appeals-overlay" onClick={() => setSelected(null)}>
          <div className="appeals-drawer" onClick={e => e.stopPropagation()}>
            <div className="appeals-drawer__head">
              <button type="button" className="appeals-back-btn" onClick={() => setSelected(null)}>
                <ArrowLeft className="w-4 h-4" /> Back
              </button>
              <StatusBadge status={selected.status} />
            </div>

            <h3 className="text-xl font-extrabold text-slate-900">{selected.testType} Appeal</h3>
            <p className="text-xs text-slate-500 font-medium mt-1 mb-5">
              Session: <span className="font-mono bg-slate-100 px-1.5 py-0.5 rounded text-slate-700">{selected.sessionCode}</span>
              &nbsp;•&nbsp;{fmtDate(selected.createdAt)}
            </p>

            {/* Score comparison */}
            <div className="grid grid-cols-2 gap-3 mb-4">
              <div className="appeal-score-box">
                <span className="appeal-score-box__label">Original Score</span>
                <span className="appeal-score-box__val text-slate-700">{selected.originalResult?.overallScore ?? '—'}</span>
              </div>
              <div className={`appeal-score-box ${selected.correctedResult ? 'appeal-score-box--green' : 'appeal-score-box--indigo'}`}>
                <span className="appeal-score-box__label">
                  {selected.correctedResult ? 'Corrected Score' : 'Claimed Score'}
                </span>
                <span className={`appeal-score-box__val ${selected.correctedResult ? 'text-emerald-700' : 'text-indigo-600'}`}>
                  {selected.correctedResult?.overallScore ?? selected.claimedScore}
                </span>
              </div>
            </div>

            {/* Reason */}
            <div className="appeal-info-box mb-3">
              <span className="appeal-info-box__label">Appeal Reason</span>
              <p className="text-sm font-semibold text-slate-700">{selected.reason}</p>
              <p className="text-xs text-slate-500 mt-1.5 leading-relaxed">{selected.description}</p>
            </div>

            {/* Evidence */}
            {selected.videoUrl && (
              <div className="appeal-info-box mb-3">
                <span className="appeal-info-box__label">Evidence</span>
                <a href={selected.videoUrl} target="_blank" rel="noopener noreferrer"
                  className="inline-flex items-center gap-2 text-sm text-indigo-600 font-bold hover:underline">
                  <FileVideo className="w-4 h-4" /> View Evidence Video
                </a>
              </div>
            )}

            {/* Scout decision */}
            {(selected.status === 'approved' || selected.status === 'rejected') && (
              <div className={`appeal-decision-box mb-3 ${selected.status === 'approved' ? 'appeal-decision-box--green' : 'appeal-decision-box--red'}`}>
                <span className="appeal-decision-box__label">
                  Scout Decision — {selected.status === 'approved' ? 'Approved ✓' : 'Rejected ✗'}
                </span>
                {selected.reviewerNotes && (
                  <p className="text-sm text-slate-700 leading-relaxed">{selected.reviewerNotes}</p>
                )}
                <p className="text-[11px] text-slate-400 mt-1.5">Reviewed: {fmtDate(selected.reviewedAt)}</p>
              </div>
            )}

            {/* Refund */}
            {selected.status === 'approved' && (
              <div className="appeal-info-box mb-3 border-emerald-200 bg-white">
                <span className="appeal-info-box__label">Refund Status</span>
                <div className="flex items-center gap-2">
                  <CheckCircle className="w-4 h-4 text-emerald-500" />
                  <span className="text-sm font-bold text-slate-800">
                    {selected.refundStatus === 'completed' ? 'Refund Completed' : 'Refund Pending'}
                  </span>
                </div>
                {selected.refundId && (
                  <p className="text-[11px] text-slate-400 mt-1 font-mono">Txn ID: {selected.refundId}</p>
                )}
                <p className="text-[11px] text-slate-500 mt-0.5">
                  Amount: ₹{selected.feeAmount?.toLocaleString('en-IN')}
                </p>
              </div>
            )}

            {/* Payment info */}
            <div className="appeal-info-box">
              <span className="appeal-info-box__label">Payment</span>
              <div className="flex items-center justify-between">
                <span className="text-sm text-slate-700 font-semibold">₹{selected.feeAmount?.toLocaleString('en-IN')} Appeal Fee</span>
                <span className="text-[11px] bg-emerald-100 text-emerald-700 font-bold px-2 py-0.5 rounded-full">Paid</span>
              </div>
              <p className="text-[10px] text-slate-400 mt-0.5 font-mono">{selected.paymentGatewayId}</p>
            </div>
          </div>
        </div>
      )}

      {/* ══════════ New Appeal Modal ══════════ */}
      {showModal && (
        <div className="appeals-overlay" onClick={resetModal}>
          <div className="appeals-modal" onClick={e => e.stopPropagation()}>

            {/* ── FORM step ── */}
            {formStep === 'form' && (
              <>
                <div className="appeals-modal__head">
                  <h3 className="text-xl font-extrabold text-slate-900">New Appeal</h3>
                  <button type="button" onClick={resetModal} className="appeals-modal__close">
                    <X className="w-5 h-5" />
                  </button>
                </div>

                <div className="space-y-4">
                  {[
                    {
                      label: 'Test Type *', type: 'select', key: 'testType',
                      options: TEST_TYPES, placeholder: 'Select test…'
                    },
                    { label: 'Session Code *', type: 'text', key: 'sessionCode', placeholder: 'e.g. AV-7892' },
                    {
                      label: 'Reason *', type: 'select', key: 'reason',
                      options: APPEAL_REASONS, placeholder: 'Select reason…'
                    },
                    { label: 'Claimed Score / Reps *', type: 'number', key: 'claimedScore', placeholder: 'Your actual score' },
                  ].map(field => (
                    <div key={field.key}>
                      <label className="appeal-form-label">{field.label}</label>
                      {field.type === 'select' ? (
                        <select
                          value={formData[field.key]}
                          onChange={e => {
                            if (field.key === 'testType') {
                              handleTestTypeChange(e.target.value);
                            } else {
                              setFormData(p => ({ ...p, [field.key]: e.target.value }));
                            }
                          }}
                          className="appeal-form-input"
                        >
                          <option value="">{field.placeholder}</option>
                          {field.options.map(o => <option key={o} value={o}>{o}</option>)}
                        </select>
                      ) : (
                        <input
                          type={field.type}
                          placeholder={field.placeholder}
                          value={formData[field.key]}
                          onChange={e => setFormData(p => ({ ...p, [field.key]: e.target.value }))}
                          className="appeal-form-input"
                        />
                      )}
                    </div>
                  ))}

                  <div>
                    <label className="appeal-form-label">Detailed Description *</label>
                    <textarea
                      placeholder="Explain what went wrong during your assessment…"
                      value={formData.description}
                      onChange={e => setFormData(p => ({ ...p, description: e.target.value }))}
                      rows={3}
                      className="appeal-form-input resize-none"
                    />
                  </div>

                  <div>
                    <label className="appeal-form-label">Evidence Video URL <span className="font-normal text-slate-400">(optional)</span></label>
                    <input
                      type="url"
                      placeholder="https://…"
                      value={formData.videoUrl}
                      onChange={e => setFormData(p => ({ ...p, videoUrl: e.target.value }))}
                      className="appeal-form-input"
                    />
                  </div>
                </div>

                {formError && (
                  <div className="appeal-form-error">
                    <AlertCircle className="w-4 h-4 shrink-0" /> {formError}
                  </div>
                )}

                <div className="flex gap-3 mt-6">
                  <button type="button" onClick={resetModal} className="appeal-btn-cancel">Cancel</button>
                  <button type="button" onClick={handleFormNext} className="appeal-btn-primary flex-1">
                    Continue to Payment →
                  </button>
                </div>
              </>
            )}

            {/* ── PAYMENT step ── */}
            {formStep === 'payment' && (
              <>
                <div className="flex items-center gap-3 mb-6">
                  <button type="button" onClick={() => setFormStep('form')}
                    className="text-slate-400 hover:text-slate-900 p-1 rounded-lg hover:bg-slate-100 transition-colors">
                    <ArrowLeft className="w-5 h-5" />
                  </button>
                  <h3 className="text-xl font-extrabold text-slate-900">Appeal Fee Payment</h3>
                </div>

                <div className="appeal-payment-card">
                  <CreditCard className="w-10 h-10 text-indigo-400 mx-auto mb-3" />
                  <div className="appeal-payment-amount">₹1,500</div>
                  <p className="text-slate-500 text-sm font-medium">Appeal processing fee</p>
                  <p className="text-xs text-slate-400 mt-1">Refunded if appeal is approved</p>
                </div>

                <div className="appeal-payment-summary">
                  {[
                    ['Test Type',     formData.testType],
                    ['Session',       formData.sessionCode.toUpperCase()],
                    ['Claimed Score', formData.claimedScore],
                    ['Reason',        formData.reason],
                  ].map(([k, v]) => (
                    <div key={k} className="flex justify-between text-xs py-1">
                      <span className="text-slate-500">{k}</span>
                      <strong className="text-slate-800">{v}</strong>
                    </div>
                  ))}
                </div>

                {formError && (
                  <div className="appeal-form-error">
                    <AlertCircle className="w-4 h-4 shrink-0" /> {formError}
                  </div>
                )}

                <button
                  type="button"
                  onClick={handleMockPayment}
                  disabled={submitting}
                  className="appeal-pay-btn"
                >
                  <CreditCard className="w-4 h-4" />
                  {submitting ? 'Processing…' : 'Pay ₹1,500 & Submit Appeal'}
                </button>
                <p className="text-[10px] text-slate-400 text-center mt-2">Secured mock payment • No real transaction</p>
              </>
            )}

            {/* ── SUCCESS step ── */}
            {formStep === 'success' && (
              <div className="text-center py-4">
                <div className="w-16 h-16 bg-emerald-100 rounded-full grid place-items-center mx-auto mb-4">
                  <CheckCircle className="w-8 h-8 text-emerald-500" />
                </div>
                <h3 className="text-xl font-extrabold text-slate-900 mb-2">Appeal Submitted!</h3>
                <p className="text-slate-500 text-sm mb-1">Your appeal is now under review by our assessment team.</p>
                <p className="text-slate-400 text-xs mb-6">You'll be notified once a decision is made.</p>
                <button type="button" onClick={resetModal}
                  className="px-6 py-2.5 bg-indigo-600 text-white font-bold text-sm rounded-xl hover:bg-indigo-700 transition-colors">
                  Done
                </button>
              </div>
            )}

          </div>
        </div>
      )}
    </div>
  );
};

export default AthleteAppeals;
