import { useState } from 'react';
import { ChevronDown, MessageCircle, LifeBuoy, Mail, Search } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';

const faqs = [
  {
    q: 'How do I deposit funds into my account?',
    a: 'Navigate to the Deposit page, choose your preferred method (Bank Transfer, Debit/Credit Card, or Crypto), and follow the instructions. Bank transfers are typically instant, while crypto deposits may take up to 30 minutes depending on network confirmations.',
  },
  {
    q: 'What are the trading fees?',
    a: 'We charge a 0.05% taker fee and 0.02% maker fee for spot trading. Futures trading fees may vary. There are no fees for deposits, and withdrawals have minimal network fees.',
  },
  {
    q: 'How long do withdrawals take?',
    a: 'Bank transfer withdrawals are processed within 1-3 business days. Crypto withdrawals are typically processed within 30 minutes, depending on network congestion.',
  },
  {
    q: 'Is my account secure?',
    a: 'Yes. We employ a multi-layered security framework including encrypted cold storage for the majority of user funds, multi-factor authentication, and regular independent security reviews by third-party auditors.',
  },
  {
    q: 'What is KYC and why is it required?',
    a: 'KYC (Know Your Customer) is a verification process that helps us comply with regulatory standards and protect against fraud. You can complete KYC from the KYC Verification page in your account settings.',
  },
  {
    q: 'How do I contact support?',
    a: 'You can reach our support team via the floating chat button in the bottom-right corner of any page, or email us at support@globaltradevx.com. Our team is available 24/7.',
  },
];

export default function SupportFAQs() {
  const [openIdx, setOpenIdx] = useState<number | null>(0);

  return (
    <DashboardLayout title="Support">
      <PageHeader title="Support & FAQs" subtitle="Find answers and get help" />

      <div className="max-w-3xl space-y-6">
        {/* Support cards */}
        <div className="grid sm:grid-cols-2 gap-4">
          <div className="rounded-2xl bg-gradient-to-br from-brand-700 to-brand-800 p-6 text-white">
            <div className="w-10 h-10 rounded-xl bg-white/10 flex items-center justify-center mb-3">
              <MessageCircle className="w-5 h-5" />
            </div>
            <h3 className="text-base font-semibold mb-1">Live Chat</h3>
            <p className="text-sm text-brand-100 mb-4">Chat with our support team 24/7</p>
            <p className="text-xs text-brand-200">Click the chat button in the bottom-right corner to start.</p>
          </div>

          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
            <div className="w-10 h-10 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center mb-3">
              <Mail className="w-5 h-5 text-brand-600 dark:text-brand-400" />
            </div>
            <h3 className="text-base font-semibold text-gray-900 dark:text-white mb-1">Email Support</h3>
            <p className="text-sm text-gray-500 dark:text-gray-400 mb-2">Get help via email</p>
            <a href="mailto:support@globaltradevx.com" className="text-sm font-medium text-brand-600 dark:text-brand-400 hover:text-brand-700 dark:hover:text-brand-300 transition-colors">
              support@globaltradevx.com
            </a>
          </div>
        </div>

        {/* FAQ accordion */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow overflow-hidden">
          <div className="flex items-center gap-2 px-6 py-4 border-b border-gray-200 dark:border-white/5">
            <LifeBuoy className="w-5 h-5 text-brand-600 dark:text-brand-400" />
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Frequently Asked Questions</h3>
          </div>

          <div className="divide-y divide-gray-100 dark:divide-white/5">
            {faqs.map((faq, i) => (
              <div key={i}>
                <button
                  onClick={() => setOpenIdx(openIdx === i ? null : i)}
                  className="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-gray-50 dark:hover:bg-white/5 transition-colors"
                >
                  <span className="text-sm font-medium text-gray-900 dark:text-white">{faq.q}</span>
                  <ChevronDown
                    className={`w-5 h-5 text-gray-400 shrink-0 transition-transform ${openIdx === i ? 'rotate-180' : ''}`}
                  />
                </button>
                {openIdx === i && (
                  <div className="px-6 pb-4">
                    <p className="text-sm text-gray-500 dark:text-gray-400 leading-relaxed">{faq.a}</p>
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
}
