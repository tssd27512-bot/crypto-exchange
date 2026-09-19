import { useState } from 'react';
import { Link, useNavigate, useLocation } from 'react-router-dom';
import {
  Sparkles, LayoutDashboard, Wallet, ArrowDownToLine,
  ArrowUpFromLine, LineChart, BarChart3, Gift,
  User, FileCheck, LifeBuoy, HelpCircle,
  Bell, LogOut, X, Check,
} from 'lucide-react';

interface SidebarProps {
  collapsed: boolean;
  mobileOpen: boolean;
  onCloseMobile: () => void;
}

const mainMenu = [
  { label: 'Dashboard', icon: LayoutDashboard, path: '/dashboard' },
  { label: 'My Balance', icon: Wallet, path: '/balance' },
  { label: 'Deposit', icon: ArrowDownToLine, path: '/deposit' },
  { label: 'Withdraw', icon: ArrowUpFromLine, path: '/withdraw' },
  { label: 'Trade', icon: LineChart, path: '/trade' },
  { label: 'Market Overview', icon: BarChart3, path: '/market-overview' },
  { label: 'Invite & Earn', icon: Gift, path: '/invite' },
];

const accountCenter = [
  { label: 'Profile Settings', icon: User, path: '/profile' },
  { label: 'KYC Verification', icon: FileCheck, path: '/kyc' },
];

const helpCenter = [
  { label: 'Support', icon: LifeBuoy, path: '/support' },
  { label: 'FAQs', icon: HelpCircle, path: '/faq' },
];

const mockNotifications = [
  { title: 'Welcome to GlobalTradeVX', desc: 'Your demo account is ready to explore.', time: 'Just now', unread: true },
  { title: 'Markets are live', desc: 'Track 13+ assets in Market Overview.', time: '2 min ago', unread: true },
  { title: 'Complete your profile', desc: 'Visit Profile Settings to personalize.', time: '1 hour ago', unread: false },
];

export default function DashboardSidebar({ collapsed, mobileOpen, onCloseMobile }: SidebarProps) {
  const navigate = useNavigate();
  const location = useLocation();
  const [notifOpen, setNotifOpen] = useState(false);

  const isActive = (path: string) => location.pathname === path;

  return (
    <>
      {mobileOpen && (
        <div
          className="fixed inset-0 z-40 bg-black/50 backdrop-blur-sm lg:hidden"
          onClick={onCloseMobile}
        />
      )}

      <aside
        className={`fixed lg:sticky top-0 left-0 z-50 h-screen bg-surface-light dark:bg-surface-dark-2 border-r border-gray-200 dark:border-white/5 flex flex-col transition-all duration-300 ${
          mobileOpen ? 'translate-x-0' : '-translate-x-full lg:translate-x-0'
        } ${collapsed ? 'w-20' : 'w-64'}`}
      >
        {/* Logo */}
        <div className="flex items-center justify-between px-4 h-16 border-b border-gray-200 dark:border-white/5 shrink-0">
          <Link to="/" className="flex items-center gap-2 group">
            <div className="relative w-9 h-9 rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center glow-purple group-hover:scale-105 transition-transform shrink-0">
              <Sparkles className="w-5 h-5 text-white" />
            </div>
            {!collapsed && (
              <span className="text-base font-bold tracking-tight text-gray-900 dark:text-white whitespace-nowrap">
                GlobalTrade<span className="text-brand-500">VX</span>
              </span>
            )}
          </Link>
          <button
            onClick={onCloseMobile}
            className="lg:hidden p-1.5 rounded-lg text-gray-500 hover:bg-gray-100 dark:hover:bg-white/5"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Scrollable nav */}
        <div className="flex-1 overflow-y-auto py-4 scrollbar-hide">
          <NavSection title="Main Menu" items={mainMenu} collapsed={collapsed} isActive={isActive} />
          <NavSection title="Account Center" items={accountCenter} collapsed={collapsed} isActive={isActive} />
          <NavSection title="Help Center" items={helpCenter} collapsed={collapsed} isActive={isActive} />
        </div>

        {/* Bottom: Notifications + Logout */}
        <div className="border-t border-gray-200 dark:border-white/5 p-3 space-y-1 shrink-0 relative">
          {/* Notifications dropdown */}
          {notifOpen && !collapsed && (
            <div className="absolute bottom-full left-3 right-3 mb-2 rounded-2xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-2xl card-glow overflow-hidden">
              <div className="px-4 py-3 border-b border-gray-100 dark:border-white/5 flex items-center justify-between">
                <span className="text-sm font-semibold text-gray-900 dark:text-white">Notifications</span>
                <span className="text-xs text-gray-400">2 new</span>
              </div>
              <div className="max-h-64 overflow-y-auto scrollbar-hide">
                {mockNotifications.map((n, i) => (
                  <div key={i} className="px-4 py-3 hover:bg-gray-50 dark:hover:bg-white/5 border-b border-gray-100 dark:border-white/5 last:border-0">
                    <div className="flex items-start gap-2">
                      {n.unread && <span className="w-2 h-2 rounded-full bg-brand-500 mt-1.5 shrink-0" />}
                      <div className={n.unread ? '' : 'pl-4'}>
                        <p className="text-sm font-medium text-gray-900 dark:text-white">{n.title}</p>
                        <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">{n.desc}</p>
                        <p className="text-xs text-gray-400 dark:text-gray-600 mt-1">{n.time}</p>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
              <button
                onClick={() => setNotifOpen(false)}
                className="w-full px-4 py-2.5 text-xs font-medium text-brand-600 dark:text-brand-400 hover:bg-brand-50 dark:hover:bg-brand-950/30 transition-colors border-t border-gray-100 dark:border-white/5 flex items-center justify-center gap-1.5"
              >
                <Check className="w-3.5 h-3.5" />
                Mark all as read
              </button>
            </div>
          )}

          <button
            onClick={() => setNotifOpen(!notifOpen)}
            className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-white/5 hover:text-brand-600 dark:hover:text-brand-400 transition-colors ${
              collapsed ? 'justify-center' : ''
            }`}
          >
            <div className="relative shrink-0">
              <Bell className="w-5 h-5" />
              <span className="absolute -top-1 -right-1 w-2 h-2 rounded-full bg-brand-500" />
            </div>
            {!collapsed && <span>Notifications</span>}
          </button>
          <button
            onClick={() => navigate('/')}
            className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium text-gray-600 dark:text-gray-400 hover:bg-red-50 dark:hover:bg-red-500/10 hover:text-red-600 dark:hover:text-red-400 transition-colors ${
              collapsed ? 'justify-center' : ''
            }`}
          >
            <LogOut className="w-5 h-5 shrink-0" />
            {!collapsed && <span>Logout</span>}
          </button>
        </div>
      </aside>
    </>
  );
}

function NavSection({
  title,
  items,
  collapsed,
  isActive,
}: {
  title: string;
  items: { label: string; icon: typeof LayoutDashboard; path: string }[];
  collapsed: boolean;
  isActive: (path: string) => boolean;
}) {
  return (
    <div className="px-3 mb-6">
      {!collapsed && (
        <p className="px-3 mb-2 text-xs font-semibold text-gray-400 dark:text-gray-600 uppercase tracking-wider">{title}</p>
      )}
      <nav className="space-y-1">
        {items.map((item) => (
          <SidebarItem key={item.label} item={item} collapsed={collapsed} active={isActive(item.path)} />
        ))}
      </nav>
    </div>
  );
}

function SidebarItem({
  item,
  collapsed,
  active,
}: {
  item: { label: string; icon: typeof LayoutDashboard; path: string };
  collapsed: boolean;
  active: boolean;
}) {
  return (
    <Link
      to={item.path}
      title={collapsed ? item.label : undefined}
      className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors ${
        collapsed ? 'justify-center' : ''
      } ${
        active
          ? 'bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border border-brand-200/40 dark:border-brand-800/30'
          : 'text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-white/5 hover:text-brand-600 dark:hover:text-brand-400 border border-transparent'
      }`}
    >
      <item.icon className="w-5 h-5 shrink-0" />
      {!collapsed && <span className="whitespace-nowrap">{item.label}</span>}
    </Link>
  );
}
