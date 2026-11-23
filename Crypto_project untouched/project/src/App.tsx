import { Routes, Route } from 'react-router-dom';
import { useTheme } from '@/hooks/useTheme';
import { AuthProvider } from '@/hooks/useAuth';
import ProtectedRoute from '@/components/ProtectedRoute';
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
import History from '@/pages/History';
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

/** Every trading/dashboard route requires a Supabase session (stage 6, area 1). */
function Protected({ children }: { children: React.ReactNode }) {
  return <ProtectedRoute>{children}</ProtectedRoute>;
}

function App() {
  return (
    <AuthProvider>
      <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/sign-in" element={<SignIn />} />
        <Route path="/sign-up" element={<SignUp />} />
        <Route path="/dashboard" element={<Protected><Dashboard /></Protected>} />
        <Route path="/deposit" element={<Protected><Deposit /></Protected>} />
        <Route path="/withdraw" element={<Protected><Withdraw /></Protected>} />
        <Route path="/balance" element={<Protected><MyBalance /></Protected>} />
        <Route path="/trade" element={<Protected><Trade /></Protected>} />
        <Route path="/market-overview" element={<Protected><MarketOverview /></Protected>} />
        <Route path="/history" element={<Protected><History /></Protected>} />
        <Route path="/invite" element={<Protected><InviteEarn /></Protected>} />
        <Route path="/profile" element={<Protected><ProfileSettings /></Protected>} />
        <Route path="/kyc" element={<Protected><KYCVerification /></Protected>} />
        <Route path="/faq" element={<Protected><SupportFAQs /></Protected>} />
        <Route path="/support" element={<Protected><SupportFAQs /></Protected>} />
        {/* Admin console keeps its own token-based auth path (unchanged). */}
        <Route path="/admin" element={<AdminPanel />} />
      </Routes>
    </AuthProvider>
  );
}

export default App;
