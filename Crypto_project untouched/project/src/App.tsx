import { Routes, Route } from 'react-router-dom';
import { useTheme } from '@/hooks/useTheme';
import Navbar from '@/components/Navbar';
import Hero from '@/components/Hero';
import LiveMarkets from '@/components/LiveMarkets';
import TrustSection from '@/components/TrustSection';
import StatsBar from '@/components/StatsBar';
import FeaturesGrid from '@/components/FeaturesGrid';
import VerifiedBy from '@/components/VerifiedBy';
import HowItWorks from '@/components/HowItWorks';
import SecuritySection from '@/components/SecuritySection';
import FinalCTA from '@/components/FinalCTA';
import Footer from '@/components/Footer';
import SignIn from '@/pages/SignIn';
import SignUp from '@/pages/SignUp';
import Dashboard from '@/pages/Dashboard';
import Deposit from '@/pages/Deposit';
import Withdraw from '@/pages/Withdraw';
import MyBalance from '@/pages/MyBalance';
import Trade from '@/pages/Trade';
import MarketOverview from '@/pages/MarketOverview';
import InviteEarn from '@/pages/InviteEarn';
import ProfileSettings from '@/pages/ProfileSettings';
import KYCVerification from '@/pages/KYCVerification';
import SupportFAQs from '@/pages/SupportFAQs';
import AdminPanel from '@/pages/AdminPanel';

function LandingPage() {
  const { theme, toggleTheme } = useTheme();

  return (
    <div className="min-h-screen bg-surface-light dark:bg-surface-dark transition-colors duration-300">
      <Navbar theme={theme} toggleTheme={toggleTheme} />
      <main>
        <Hero />
        <LiveMarkets />
        <TrustSection />
        <StatsBar />
        <FeaturesGrid />
        <VerifiedBy />
        <HowItWorks />
        <SecuritySection />
        <FinalCTA />
      </main>
      <Footer />
    </div>
  );
}

function App() {
  return (
    <Routes>
      <Route path="/" element={<LandingPage />} />
      <Route path="/sign-in" element={<SignIn />} />
      <Route path="/sign-up" element={<SignUp />} />
      <Route path="/dashboard" element={<Dashboard />} />
      <Route path="/deposit" element={<Deposit />} />
      <Route path="/withdraw" element={<Withdraw />} />
      <Route path="/balance" element={<MyBalance />} />
      <Route path="/trade" element={<Trade />} />
      <Route path="/market-overview" element={<MarketOverview />} />
      <Route path="/invite" element={<InviteEarn />} />
      <Route path="/profile" element={<ProfileSettings />} />
      <Route path="/kyc" element={<KYCVerification />} />
      <Route path="/faq" element={<SupportFAQs />} />
      <Route path="/support" element={<SupportFAQs />} />
      <Route path="/admin" element={<AdminPanel />} />
    </Routes>
  );
}

export default App;
