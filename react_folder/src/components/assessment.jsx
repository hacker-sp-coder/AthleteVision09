import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { auth, db } from '../firebase/config';
import { onAuthStateChanged } from 'firebase/auth';
import { doc, getDoc, onSnapshot } from 'firebase/firestore';
import { ArrowDownUp, Dumbbell, MoveDown, PersonStanding, ChevronRight, Compass, MessageSquare, Radio, UserRound } from 'lucide-react';
import './assessment.css';

const TEST_RULES = {
  'vertical-jump': ['Warm up before starting.', 'Stand behind the line and jump vertically with maximum effort.', 'Land safely on both feet.', 'Complete three attempts; your best valid attempt counts.'],
  'horizontal-jump': ['Warm up and clear the landing area.', 'Start behind the line without a running start.', 'Jump forward and land with control.', 'Complete three attempts; your longest valid jump counts.'],
  pushups: ['Keep your body straight.', 'Lower your chest with control and fully extend your arms.', 'Only repetitions with correct form count.', 'Stop immediately if you feel pain or dizziness.'],
  'wall-sit': ['Keep your back flat against the wall.', 'Keep your feet flat and knees close to 90 degrees.', 'Hold without using your hands for support.', 'The timer stops when your position is no longer controlled.']
};

const DEFAULT_METRICS = { verticalJump: 68, horizontalJump: 245, pushups: 45, wallSit: 95 };

const TEST_DETAILS = {
  'vertical-jump': { description: 'Measure explosive lower-body power.', icon: ArrowDownUp },
  'horizontal-jump': { description: 'Measure forward power and speed.', icon: MoveDown },
  pushups: { description: 'Measure upper-body strength.', icon: Dumbbell },
  'wall-sit': { description: 'Measure lower-body endurance.', icon: PersonStanding }
};

const Assessment = () => {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(true);
  const [availableTests, setAvailableTests] = useState([]);
  const [previousMetrics, setPreviousMetrics] = useState(null);
  const [selectedTest, setSelectedTest] = useState(null);
  const [showRetest, setShowRetest] = useState(false);
  const [metrics, setMetrics] = useState(DEFAULT_METRICS);

  useEffect(() => {
    const unsubscribeAuth = onAuthStateChanged(auth, async (user) => {
      if (!user) {
        navigate('/login');
        return;
      }

      try {
        const snapshot = await getDoc(doc(db, 'users', user.uid));
        const data = snapshot.data() || {};
        const savedMetrics = data.metrics || data.assessmentResults?.metrics || null;
        if (savedMetrics) {
          setPreviousMetrics(savedMetrics);
          setMetrics((current) => ({ ...current, ...savedMetrics }));
        }
      } catch (error) {
        console.error('Assessment profile error:', error);
      } finally {
        setLoading(false);
      }
    });

    return () => unsubscribeAuth();
  }, [navigate]);

  useEffect(() => {
    const unsubscribeTests = onSnapshot(doc(db, 'assessmentConfig', 'current'), (snapshot) => {
      setAvailableTests(snapshot.data()?.activeTests || []);
    }, (error) => console.error('Assessment config error:', error));

    return () => unsubscribeTests();
  }, []);

  if (loading) return <div className="assessment-loading">Loading assessments...</div>;

  const saveRetest = (event) => {
    event.preventDefault();
    setPreviousMetrics(metrics);
    setShowRetest(false);
  };

  return (
    <main className="assessment-page">
      <section className="assessment-hero">
        <div>
          <h1>Assessment of Development</h1>
          <p>Measure your athletic performance through standardized fitness tests.</p>
        </div>
      </section>

      {availableTests.length === 0 && !previousMetrics ? (
        <section className="assessment-empty"><h2>No tests available</h2><p>The authority has not published any fitness tests for you yet.</p></section>
      ) : (
        <>
          {availableTests.length === 0 && previousMetrics && <section className="assessment-notice">No new tests are available right now. Your previous results are shown below.</section>}
          {availableTests.length > 0 && <section className="assessment-section"><div className="assessment-grid">
            {availableTests.map((test) => { const detail = TEST_DETAILS[test.id] || { description: 'Measure your athletic performance.', icon: Dumbbell }; const Icon = detail.icon; return <button type="button" key={test.id || test.name} className="assessment-test-card" onClick={() => setSelectedTest(test)}><span className="assessment-test-card__icon"><Icon size={30} /></span><span className="assessment-test-card__copy"><strong>{test.name}</strong><em>{detail.description}</em><small>Unit: {test.unit || 'score'}</small></span><ChevronRight className="assessment-test-card__arrow" size={30} /></button>; })}
          </div></section>}
          {previousMetrics && <section className="assessment-section"><h2>Previous Test Results</h2><div className="assessment-results"><Result label="Vertical Jump" value={metrics.verticalJump} unit="cm" /><Result label="Horizontal Jump" value={metrics.horizontalJump} unit="cm" /><Result label="Push-ups" value={metrics.pushups} unit="reps" /><Result label="Wall Sit" value={metrics.wallSit} unit="sec" /></div></section>}
        </>
      )}

      {selectedTest && <div className="assessment-overlay"><section className="assessment-modal"><div className="assessment-modal__head"><div><span className="assessment-eyebrow">Assessment instructions</span><h2>{selectedTest.name}</h2><p>Unit: {selectedTest.unit || 'score'}</p></div><button type="button" onClick={() => setSelectedTest(null)} aria-label="Close">×</button></div><div className="assessment-rules"><h3>Rules before you start</h3><ol>{(TEST_RULES[selectedTest.id] || ['Read the instructions carefully before starting.', 'Complete the test with safe and controlled movement.', 'Only valid attempts will be considered.']).map((rule) => <li key={rule}>{rule}</li>)}</ol></div><p className="assessment-footnote">Your camera will be used for real-time pose detection and scoring.</p><div className="assessment-modal__actions"><button type="button" className="assessment-secondary" onClick={() => setSelectedTest(null)}>Back</button><button type="button" className="assessment-primary" onClick={() => { const typeMap = { 'vertical-jump': 'verticalJump', 'horizontal-jump': 'verticalJump', pushups: 'pushUp', squats: 'squat', 'controlled-crunch': 'controlledCrunch', 'wall-sit': 'wallSit', plank: 'plank' }; const exerciseType = typeMap[selectedTest.id] || 'pushUp'; setSelectedTest(null); navigate(`/live-test/${exerciseType}`); }}>Start Test</button></div></section></div>}

      {showRetest && <div className="assessment-overlay"><section className="assessment-modal"><div className="assessment-modal__head"><div><span className="assessment-eyebrow">Retest results</span><h2>Update previous scores</h2></div><button type="button" onClick={() => setShowRetest(false)} aria-label="Close">×</button></div><form className="assessment-form" onSubmit={saveRetest}>{Object.entries({ verticalJump: ['Vertical Jump', 'cm'], horizontalJump: ['Horizontal Jump', 'cm'], pushups: ['Push-ups', 'reps'], wallSit: ['Wall Sit', 'sec'] }).map(([key, [label, unit]]) => <label key={key}>{label} ({unit})<input type="number" value={metrics[key]} onChange={(event) => setMetrics({ ...metrics, [key]: Number(event.target.value) })} /></label>)}<div className="assessment-modal__actions"><button type="button" className="assessment-secondary" onClick={() => setShowRetest(false)}>Cancel</button><button type="submit" className="assessment-primary">Save scores</button></div></form></section></div>}

      <nav className="assessment-nav" aria-label="Athlete navigation"><button type="button" onClick={() => navigate('/athlete-dashboard')}><Compass size={24} /><span>Discover</span></button><button type="button"><MessageSquare size={24} /><span>Messages</span></button><button type="button" className="is-active"><Radio size={24} /><span>Assessments</span></button><button type="button" onClick={() => navigate('/profile')}><UserRound size={24} /><span>Profile</span></button></nav>
    </main>
  );
};

const Result = ({ label, value, unit }) => <div className="assessment-result"><span>{label}</span><strong>{value} <small>{unit}</small></strong></div>;

export default Assessment;
