import { ChevronRight, UserRound, UsersRound } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import './landingpage.css';

const LandingPage = () => {
  const navigate = useNavigate();

  return (
    <main className="landing-page">
      <div className="landing-page__glow landing-page__glow--one" />
      <div className="landing-page__glow landing-page__glow--two" />

      {/* Center Branding Area */}
      <section className="brand-block">
        <h1>AthleteVision</h1>

        <p className="brand-block__tagline">Connect. Play. Compete.</p>
        <p className="brand-block__subline">Join as an athlete or create your team profile</p>
      </section>

      {/* Bottom Option Cards Section */}
      <section className="role-list" aria-label="Choose your role">
        {/* Updated route to /signup */}
        <button 
          className="role-card" 
          type="button" 
          onClick={() => navigate('/signup')}
        >
          <span className="role-card__icon role-card__icon--athlete"><UserRound size={25} /></span>
          <span className="role-card__copy">
            <strong>I'm an Athlete</strong>
            <span>Find teams and playing opportunities</span>
          </span>
          <ChevronRight className="role-card__arrow" size={22} />
        </button>

        <button 
          className="role-card" 
          type="button" 
          onClick={() => navigate('/admin-login')}
        >
          <span className="role-card__icon role-card__icon--team"><UsersRound size={25} /></span>
          <span className="role-card__copy">
            <strong>I'm a Team/Coach</strong>
            <span>Find talented athletes for your team</span>
          </span>
          <ChevronRight className="role-card__arrow" size={22} />
        </button>
      </section>

      <footer className="legal-copy">
        By continuing, you agree to our <br />
        <a href="#terms">Terms</a> &amp; <a href="#privacy">Privacy Policy</a>
      </footer>
    </main>
  );
};

export default LandingPage;