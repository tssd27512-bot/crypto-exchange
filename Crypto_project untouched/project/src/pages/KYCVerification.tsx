import { useState } from 'react';
import {
  User, FileCheck, Upload, Clock, Check, Info, ShieldCheck,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';

const steps = [
  { label: 'Personal Info', icon: User },
  { label: 'Document Upload', icon: FileCheck },
  { label: 'Review', icon: Clock },
];

export default function KYCVerification() {
  const [currentStep, setCurrentStep] = useState(0);
  const [fullName, setFullName] = useState('');
  const [dob, setDob] = useState('');
  const [country, setCountry] = useState('');
  const [uploadedFile, setUploadedFile] = useState<string | null>(null);

  return (
    <DashboardLayout title="KYC Verification">
      <PageHeader title="KYC Verification" subtitle="Verify your identity to unlock all features" />

      <div className="max-w-2xl space-y-6">
        {/* Status badge */}
        <div className="flex items-center gap-3 rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-5">
          <div className="w-10 h-10 rounded-xl bg-yellow-50 dark:bg-yellow-500/10 flex items-center justify-center">
            <Clock className="w-5 h-5 text-yellow-500" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <span className="text-sm font-semibold text-gray-900 dark:text-white">Pending Demo Verification</span>
              <span className="px-2 py-0.5 rounded-md text-xs font-medium bg-yellow-50 dark:bg-yellow-500/10 text-yellow-600 dark:text-yellow-400 border border-yellow-200/40 dark:border-yellow-500/20">
                Pending
              </span>
            </div>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">Your verification is being reviewed (demo).</p>
          </div>
        </div>

        {/* Step indicator */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          <div className="flex items-center justify-between mb-8">
            {steps.map((step, i) => (
              <div key={step.label} className="flex items-center flex-1 last:flex-none">
                <div className="flex flex-col items-center gap-2">
                  <div
                    className={`w-10 h-10 rounded-full flex items-center justify-center transition-all ${
                      i < currentStep
                        ? 'bg-green-500 text-white'
                        : i === currentStep
                        ? 'bg-brand-600 text-white glow-purple'
                        : 'bg-gray-100 dark:bg-white/5 text-gray-400 dark:text-gray-600'
                    }`}
                  >
                    {i < currentStep ? (
                      <Check className="w-5 h-5" />
                    ) : (
                      <step.icon className="w-5 h-5" />
                    )}
                  </div>
                  <span className={`text-xs font-medium ${i <= currentStep ? 'text-gray-900 dark:text-white' : 'text-gray-400 dark:text-gray-600'}`}>
                    {step.label}
                  </span>
                </div>
                {i < steps.length - 1 && (
                  <div className={`flex-1 h-0.5 mx-2 -mt-6 ${i < currentStep ? 'bg-green-500' : 'bg-gray-200 dark:bg-white/10'}`} />
                )}
              </div>
            ))}
          </div>

          {/* Step content */}
          {currentStep === 0 && (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                setCurrentStep(1);
              }}
              className="space-y-4"
            >
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Full Legal Name</label>
                <input
                  type="text"
                  required
                  value={fullName}
                  onChange={(e) => setFullName(e.target.value)}
                  placeholder="John Doe"
                  className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Date of Birth</label>
                <input
                  type="date"
                  required
                  value={dob}
                  onChange={(e) => setDob(e.target.value)}
                  className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Country of Residence</label>
                <input
                  type="text"
                  required
                  value={country}
                  onChange={(e) => setCountry(e.target.value)}
                  placeholder="United States"
                  className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                />
              </div>
              <button type="submit" className="w-full py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple">
                Continue
              </button>
            </form>
          )}

          {currentStep === 1 && (
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Upload ID Document</label>
                <label className="flex flex-col items-center justify-center w-full h-48 rounded-xl border-2 border-dashed border-gray-200 dark:border-white/10 bg-gray-50 dark:bg-surface-dark-3 hover:border-brand-500 dark:hover:border-brand-600 transition-colors cursor-pointer">
                  <div className="flex flex-col items-center gap-3">
                    {uploadedFile ? (
                      <>
                        <div className="w-12 h-12 rounded-full bg-green-50 dark:bg-green-500/10 flex items-center justify-center">
                          <Check className="w-6 h-6 text-green-500" />
                        </div>
                        <span className="text-sm font-medium text-gray-900 dark:text-white">{uploadedFile}</span>
                        <span className="text-xs text-gray-400 dark:text-gray-500">Click to replace</span>
                      </>
                    ) : (
                      <>
                        <div className="w-12 h-12 rounded-full bg-gray-100 dark:bg-white/5 flex items-center justify-center">
                          <Upload className="w-6 h-6 text-gray-400 dark:text-gray-500" />
                        </div>
                        <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Click to upload</span>
                        <span className="text-xs text-gray-400 dark:text-gray-500">PNG, JPG, PDF up to 10MB</span>
                      </>
                    )}
                  </div>
                  <input
                    type="file"
                    className="hidden"
                    onChange={(e) => setUploadedFile(e.target.files?.[0]?.name || 'document.pdf')}
                  />
                </label>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Upload Proof of Address (Optional)</label>
                <label className="flex flex-col items-center justify-center w-full h-32 rounded-xl border-2 border-dashed border-gray-200 dark:border-white/10 bg-gray-50 dark:bg-surface-dark-3 hover:border-brand-500 dark:hover:border-brand-600 transition-colors cursor-pointer">
                  <div className="flex flex-col items-center gap-2">
                    <Upload className="w-5 h-5 text-gray-400 dark:text-gray-500" />
                    <span className="text-xs text-gray-500 dark:text-gray-400">Utility bill or bank statement</span>
                  </div>
                  <input type="file" className="hidden" />
                </label>
              </div>
              <div className="flex gap-3">
                <button
                  onClick={() => setCurrentStep(0)}
                  className="px-5 py-3 text-sm font-medium text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
                >
                  Back
                </button>
                <button
                  onClick={() => setCurrentStep(2)}
                  className="flex-1 py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
                >
                  Submit for Review
                </button>
              </div>
            </div>
          )}

          {currentStep === 2 && (
            <div className="text-center py-8">
              <div className="w-16 h-16 rounded-full bg-yellow-50 dark:bg-yellow-500/10 flex items-center justify-center mx-auto mb-4">
                <Clock className="w-8 h-8 text-yellow-500" />
              </div>
              <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">Under Review</h3>
              <p className="text-sm text-gray-500 dark:text-gray-400 mb-6 max-w-sm mx-auto">
                Your documents have been submitted. Verification typically takes 1-3 business days (demo).
              </p>
              <div className="flex items-center justify-center gap-2 rounded-xl bg-brand-50 dark:bg-brand-950/30 border border-brand-200/30 dark:border-brand-800/20 px-4 py-3 max-w-sm mx-auto">
                <Info className="w-4 h-4 text-brand-600 dark:text-brand-400 shrink-0" />
                <span className="text-xs text-brand-700 dark:text-brand-300">This is a demo — no documents are actually processed.</span>
              </div>
            </div>
          )}
        </div>

        {/* Security note */}
        <div className="flex items-start gap-3 rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5">
          <ShieldCheck className="w-5 h-5 text-brand-600 dark:text-brand-400 shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-gray-900 dark:text-white mb-1">Your data is protected</p>
            <p className="text-xs text-gray-500 dark:text-gray-400 leading-relaxed">
              All documents are encrypted and stored securely. We use industry-standard practices to protect your personal information.
            </p>
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
}
