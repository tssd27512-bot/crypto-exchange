import { Sparkles, Twitter, Github, Linkedin, MessageCircle } from 'lucide-react';
import { footerColumns } from '@/data/mockData';

export default function Footer() {
  return (
    <footer className="bg-surface-dark text-gray-400 pt-16 pb-8">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        {/* Top section */}
        <div className="grid lg:grid-cols-5 gap-8 mb-12">
          {/* Brand */}
          <div className="lg:col-span-1">
            <a href="#hero" className="flex items-center gap-2 mb-4">
              <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center">
                <Sparkles className="w-5 h-5 text-white" />
              </div>
              <span className="text-lg font-bold text-white">
                GlobalTrade<span className="text-brand-400">VX</span>
              </span>
            </a>
            <p className="text-sm text-gray-500 leading-relaxed mb-4">
              A professional-grade cryptocurrency trading platform for traders worldwide.
            </p>
            {/* Social icons */}
            <div className="flex gap-3">
              {[Twitter, Github, Linkedin, MessageCircle].map((Icon, i) => (
                <a
                  key={i}
                  href="#"
                  className="w-9 h-9 rounded-lg bg-white/5 border border-white/5 flex items-center justify-center hover:bg-brand-600 hover:border-brand-600 transition-all"
                >
                  <Icon className="w-4 h-4 text-gray-400" />
                </a>
              ))}
            </div>
          </div>

          {/* Link columns */}
          {footerColumns.map((col) => (
            <div key={col.title}>
              <h4 className="text-sm font-semibold text-white mb-4">{col.title}</h4>
              <ul className="space-y-3">
                {col.links.map((link) => (
                  <li key={link}>
                    <a
                      href="#"
                      className="text-sm text-gray-500 hover:text-brand-400 transition-colors"
                    >
                      {link}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        {/* Divider */}
        <div className="border-t border-white/5 pt-6">
          {/* Disclaimer */}
          <p className="text-xs text-gray-600 text-center mb-4 max-w-3xl mx-auto leading-relaxed">
            Concept/demo project for portfolio purposes — not an operating financial platform.
            All data shown is fictional and for demonstration only.
          </p>
          {/* Copyright */}
          <div className="flex flex-col sm:flex-row items-center justify-between gap-4">
            <p className="text-xs text-gray-600">
              &copy; {new Date().getFullYear()} GlobalTradeVX. All rights reserved.
            </p>
            <div className="flex gap-6">
              <a href="#" className="text-xs text-gray-600 hover:text-gray-400 transition-colors">Privacy Policy</a>
              <a href="#" className="text-xs text-gray-600 hover:text-gray-400 transition-colors">Terms of Service</a>
              <a href="#" className="text-xs text-gray-600 hover:text-gray-400 transition-colors">Cookies</a>
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
}
