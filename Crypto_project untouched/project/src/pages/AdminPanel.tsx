import { useState, useEffect, useRef, useCallback } from 'react';
import {
  Lock, User, ArrowRight, Send, MessageCircle, LogOut,
  Search, Clock, CheckCircle2, KeyRound, ArrowLeft, RefreshCw,
} from 'lucide-react';
import { Link } from 'react-router-dom';
import { supabase } from '@/lib/supabase';
import { adminChatUrl, adminChatHeaders } from '@/lib/supabaseEnv';

interface Conversation {
  id: string;
  visitor_id: string;
  visitor_name: string | null;
  status: string;
  created_at: string;
  updated_at: string;
}

interface ChatMessage {
  id: string;
  conversation_id: string;
  sender: 'visitor' | 'agent';
  content: string;
  created_at: string;
}

// Endpoint + headers come from @/lib/supabaseEnv, which normalises
// VITE_SUPABASE_URL (strips any trailing slash, so the URL can never become
// `.../admin-chat//login`) and throws a message naming the missing variable
// instead of requesting `undefined/functions/v1/admin-chat/...`.

export default function AdminPanel() {
  const [token, setToken] = useState<string | null>(() => sessionStorage.getItem('admin_token'));
  const [username, setUsername] = useState<string>(() => sessionStorage.getItem('admin_username') || '');

  const handleLogin = (newToken: string, newUsername: string) => {
    sessionStorage.setItem('admin_token', newToken);
    sessionStorage.setItem('admin_username', newUsername);
    setToken(newToken);
    setUsername(newUsername);
  };

  const handleLogout = () => {
    sessionStorage.removeItem('admin_token');
    sessionStorage.removeItem('admin_username');
    setToken(null);
    setUsername('');
  };

  if (!token) {
    return <LoginScreen onLogin={handleLogin} />;
  }

  return <AdminDashboard token={token} username={username} onLogout={handleLogout} />;
}

// ============ LOGIN SCREEN ============

function LoginScreen({ onLogin }: { onLogin: (token: string, username: string) => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      const res = await fetch(`${adminChatUrl()}/login`, {
        method: 'POST',
        headers: adminChatHeaders(),
        body: JSON.stringify({ username, password }),
      });
      // A gateway/edge error can return HTML instead of JSON — don't let
      // `res.json()` blow up into the generic "Network error" branch.
      const data = await res.json().catch(() => ({} as { error?: string; token?: string; username?: string }));

      if (!res.ok) {
        setError(data.error || `Login failed (HTTP ${res.status})`);
        return;
      }
      if (!data.token) {
        setError('Login succeeded but no token was returned. The admin-chat function may need redeploying.');
        return;
      }

      onLogin(data.token, data.username || username);
    } catch (err) {
      // Surfaces the actionable config message from @/lib/supabaseEnv
      // (e.g. "Missing VITE_SUPABASE_URL ...") instead of a generic failure.
      setError(err instanceof Error ? err.message : 'Network error. Please try again.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-surface-light dark:bg-surface-dark flex items-center justify-center p-4 transition-colors duration-300">
      <div className="absolute inset-0 overflow-hidden">
        <div className="absolute top-1/4 left-1/4 w-96 h-96 bg-brand-500/10 rounded-full blur-[120px]" />
        <div className="absolute bottom-1/4 right-1/4 w-96 h-96 bg-brand-700/10 rounded-full blur-[120px]" />
      </div>

      <div className="relative w-full max-w-md">
        <Link
          to="/"
          className="inline-flex items-center gap-1.5 text-sm text-gray-500 dark:text-gray-400 hover:text-brand-600 dark:hover:text-brand-400 transition-colors mb-6"
        >
          <ArrowLeft className="w-4 h-4" />
          Back to site
        </Link>

        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-8">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-11 h-11 rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center glow-purple">
              <Lock className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-gray-900 dark:text-white">Admin Panel</h1>
              <p className="text-xs text-gray-500 dark:text-gray-400">Live Chat Administration</p>
            </div>
          </div>

          {error && (
            <div className="mb-4 rounded-xl bg-red-50 dark:bg-red-500/10 border border-red-200/40 dark:border-red-500/20 px-4 py-3">
              <span className="text-sm text-red-600 dark:text-red-400">{error}</span>
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Username</label>
              <div className="relative">
                <User className="absolute left-3.5 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400" />
                <input
                  type="text"
                  required
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  placeholder="admin"
                  className="w-full pl-11 pr-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Password</label>
              <div className="relative">
                <Lock className="absolute left-3.5 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400" />
                <input
                  type="password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Enter password"
                  className="w-full pl-11 pr-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                />
              </div>
            </div>

            <button
              type="submit"
              disabled={loading}
              className="w-full inline-flex items-center justify-center gap-2 px-6 py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple disabled:opacity-50"
            >
              {loading ? 'Signing in...' : 'Sign In'}
              {!loading && <ArrowRight className="w-4 h-4" />}
            </button>
          </form>

          <div className="mt-6 rounded-xl bg-brand-50 dark:bg-brand-950/30 border border-brand-200/30 dark:border-brand-800/20 px-4 py-3">
            <p className="text-xs text-brand-700 dark:text-brand-300">
              Default credentials: <span className="font-mono font-semibold">admin / admin123</span>
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

// ============ ADMIN DASHBOARD ============

function AdminDashboard({ token, username, onLogout }: { token: string; username: string; onLogout: () => void }) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [replyText, setReplyText] = useState('');
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [showSettings, setShowSettings] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const scrollToBottom = useCallback(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, []);

  // Fetch conversations
  const fetchConversations = useCallback(async () => {
    try {
      const res = await fetch(`${adminChatUrl()}/conversations`, {
        method: 'POST',
        headers: adminChatHeaders(),
        body: JSON.stringify({ token }),
      });
      const data = await res.json();
      if (res.ok && data.conversations) {
        setConversations(data.conversations);
      }
    } catch {
      // ignore
    }
    setLoading(false);
  }, [token]);

  // Fetch messages for selected conversation
  const fetchMessages = useCallback(async (convId: string) => {
    try {
      const res = await fetch(`${adminChatUrl()}/messages`, {
        method: 'POST',
        headers: adminChatHeaders(),
        body: JSON.stringify({ token, conversationId: convId }),
      });
      const data = await res.json();
      if (res.ok && data.messages) {
        setMessages(data.messages);
      }
    } catch {
      // ignore
    }
  }, [token]);

  // Initial load
  useEffect(() => {
    fetchConversations();
  }, [fetchConversations]);

  // Poll conversations every 5 seconds for new ones
  useEffect(() => {
    const interval = setInterval(fetchConversations, 5000);
    return () => clearInterval(interval);
  }, [fetchConversations]);

  // Load messages when selecting a conversation
  useEffect(() => {
    if (selectedId) {
      fetchMessages(selectedId);
    } else {
      setMessages([]);
    }
  }, [selectedId, fetchMessages]);

  // Subscribe to realtime messages for selected conversation
  useEffect(() => {
    if (!selectedId) return;

    const channel = supabase
      .channel(`admin:${selectedId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'chat_messages',
          filter: `conversation_id=eq.${selectedId}`,
        },
        (payload) => {
          const newMsg = payload.new as ChatMessage;
          setMessages((prev) => {
            if (prev.some((m) => m.id === newMsg.id)) return prev;
            return [...prev, newMsg];
          });
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [selectedId]);

  // Auto-scroll
  useEffect(() => {
    scrollToBottom();
  }, [messages, scrollToBottom]);

  const handleReply = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!replyText.trim() || !selectedId) return;

    const content = replyText.trim();
    setReplyText('');

    // Optimistic
    const tempId = `temp_${Date.now()}`;
    setMessages((prev) => [
      ...prev,
      {
        id: tempId,
        conversation_id: selectedId,
        sender: 'agent',
        content,
        created_at: new Date().toISOString(),
      },
    ]);

    await fetch(`${adminChatUrl()}/reply`, {
      method: 'POST',
      headers: adminChatHeaders(),
      body: JSON.stringify({ token, conversationId: selectedId, content }),
    });

    // Refresh conversations to update order
    fetchConversations();
  };

  const handleCloseConversation = async () => {
    if (!selectedId) return;
    await fetch(`${adminChatUrl()}/close`, {
      method: 'POST',
      headers: adminChatHeaders(),
      body: JSON.stringify({ token, conversationId: selectedId }),
    });
    fetchConversations();
  };

  const filteredConversations = conversations.filter(
    (c) =>
      c.visitor_name?.toLowerCase().includes(search.toLowerCase()) ||
      c.visitor_id.toLowerCase().includes(search.toLowerCase())
  );

  const selectedConversation = conversations.find((c) => c.id === selectedId);

  return (
    <div className="min-h-screen bg-surface-light-2 dark:bg-surface-dark flex transition-colors duration-300">
      {/* Sidebar: Conversation list */}
      <div className="w-80 shrink-0 border-r border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-2 flex flex-col h-screen sticky top-0">
        {/* Header */}
        <div className="px-4 py-4 border-b border-gray-200 dark:border-white/5 shrink-0">
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center">
                <MessageCircle className="w-4 h-4 text-white" />
              </div>
              <span className="text-sm font-semibold text-gray-900 dark:text-white">Live Chat Admin</span>
            </div>
            <div className="flex items-center gap-1">
              <button
                onClick={() => setShowSettings(true)}
                className="p-2 rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-white/5 hover:text-brand-600 dark:hover:text-brand-400 transition-colors"
                title="Change password"
              >
                <KeyRound className="w-4 h-4" />
              </button>
              <button
                onClick={onLogout}
                className="p-2 rounded-lg text-gray-500 dark:text-gray-400 hover:bg-red-50 dark:hover:bg-red-500/10 hover:text-red-600 dark:hover:text-red-400 transition-colors"
                title="Logout"
              >
                <LogOut className="w-4 h-4" />
              </button>
            </div>
          </div>
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              placeholder="Search conversations..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="w-full pl-9 pr-3 py-2 text-sm rounded-lg bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 transition-all"
            />
          </div>
        </div>

        {/* Conversation list */}
        <div className="flex-1 overflow-y-auto">
          {loading && (
            <div className="flex items-center justify-center py-8">
              <div className="w-6 h-6 border-2 border-brand-500 border-t-transparent rounded-full animate-spin" />
            </div>
          )}
          {!loading && filteredConversations.length === 0 && (
            <div className="text-center py-8 px-4">
              <MessageCircle className="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto mb-2" />
              <p className="text-sm text-gray-400 dark:text-gray-600">No conversations yet</p>
            </div>
          )}
          {filteredConversations.map((conv) => (
            <button
              key={conv.id}
              onClick={() => setSelectedId(conv.id)}
              className={`w-full text-left px-4 py-3 border-b border-gray-100 dark:border-white/5 transition-colors ${
                selectedId === conv.id
                  ? 'bg-brand-50 dark:bg-brand-950/30'
                  : 'hover:bg-gray-50 dark:hover:bg-white/5'
              }`}
            >
              <div className="flex items-center justify-between mb-1">
                <span className="text-sm font-medium text-gray-900 dark:text-white truncate">
                  {conv.visitor_name || 'Anonymous'}
                </span>
                {conv.status === 'open' && (
                  <span className="w-2 h-2 rounded-full bg-green-400 shrink-0 ml-2" />
                )}
              </div>
              <div className="flex items-center gap-1.5 text-xs text-gray-400 dark:text-gray-500">
                <Clock className="w-3 h-3" />
                {new Date(conv.updated_at).toLocaleString(undefined, {
                  month: 'short',
                  day: 'numeric',
                  hour: '2-digit',
                  minute: '2-digit',
                })}
              </div>
            </button>
          ))}
        </div>
      </div>

      {/* Main: Chat area */}
      <div className="flex-1 flex flex-col h-screen">
        {selectedId ? (
          <>
            {/* Chat header */}
            <div className="px-6 py-4 border-b border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-2 flex items-center justify-between shrink-0">
              <div>
                <h2 className="text-sm font-semibold text-gray-900 dark:text-white">
                  {selectedConversation?.visitor_name || 'Anonymous'}
                </h2>
                <p className="text-xs text-gray-400 dark:text-gray-500">
                  {selectedConversation?.status === 'open' ? 'Active conversation' : 'Closed'}
                </p>
              </div>
              <div className="flex items-center gap-2">
                <button
                  onClick={fetchConversations}
                  className="p-2 rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-white/5 transition-colors"
                  title="Refresh"
                >
                  <RefreshCw className="w-4 h-4" />
                </button>
                {selectedConversation?.status === 'open' && (
                  <button
                    onClick={handleCloseConversation}
                    className="px-3 py-1.5 text-xs font-medium rounded-lg bg-gray-100 dark:bg-white/5 text-gray-600 dark:text-gray-400 hover:bg-red-50 dark:hover:bg-red-500/10 hover:text-red-600 dark:hover:text-red-400 transition-colors"
                  >
                    Close
                  </button>
                )}
              </div>
            </div>

            {/* Messages */}
            <div className="flex-1 overflow-y-auto p-6 space-y-3">
              {messages.length === 0 && (
                <div className="text-center py-12">
                  <p className="text-sm text-gray-400 dark:text-gray-600">No messages yet</p>
                </div>
              )}
              {messages.map((msg) => (
                <div
                  key={msg.id}
                  className={`flex ${msg.sender === 'agent' ? 'justify-end' : 'justify-start'}`}
                >
                  <div className={`max-w-[70%] ${msg.sender === 'agent' ? 'order-2' : ''}`}>
                    <div
                      className={`rounded-2xl px-4 py-2.5 text-sm leading-relaxed ${
                        msg.sender === 'agent'
                          ? 'rounded-tr-sm bg-brand-600 text-white'
                          : 'rounded-tl-sm bg-gray-100 dark:bg-white/5 text-gray-700 dark:text-gray-300'
                      }`}
                    >
                      {msg.content}
                    </div>
                    <p className={`text-xs text-gray-400 dark:text-gray-600 mt-1 ${msg.sender === 'agent' ? 'text-right' : ''}`}>
                      {new Date(msg.created_at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}
                    </p>
                  </div>
                </div>
              ))}
              <div ref={messagesEndRef} />
            </div>

            {/* Reply input */}
            <form onSubmit={handleReply} className="px-6 py-4 border-t border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-2 shrink-0">
              <div className="flex items-center gap-2 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 px-4 py-2.5">
                <input
                  type="text"
                  value={replyText}
                  onChange={(e) => setReplyText(e.target.value)}
                  placeholder="Type your reply..."
                  className="flex-1 bg-transparent text-sm text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none"
                />
                <button
                  type="submit"
                  disabled={!replyText.trim()}
                  className="p-2 text-brand-600 dark:text-brand-400 disabled:opacity-40 hover:text-brand-700 dark:hover:text-brand-300 transition-colors"
                >
                  <Send className="w-4 h-4" />
                </button>
              </div>
            </form>
          </>
        ) : (
          <div className="flex-1 flex flex-col items-center justify-center">
            <div className="w-16 h-16 rounded-full bg-gray-100 dark:bg-white/5 flex items-center justify-center mb-4">
              <MessageCircle className="w-8 h-8 text-gray-300 dark:text-gray-600" />
            </div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-1">Select a conversation</h3>
            <p className="text-sm text-gray-400 dark:text-gray-600">Choose a conversation from the left to start chatting</p>
          </div>
        )}
      </div>

      {/* Settings modal */}
      {showSettings && (
        <SettingsModal token={token} onClose={() => setShowSettings(false)} />
      )}
    </div>
  );
}

// ============ SETTINGS MODAL ============

function SettingsModal({ token, onClose }: { token: string; onClose: () => void }) {
  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (newPassword !== confirmPassword) {
      setError('New passwords do not match');
      return;
    }

    if (newPassword.length < 6) {
      setError('New password must be at least 6 characters');
      return;
    }

    setLoading(true);

    try {
      const res = await fetch(`${adminChatUrl()}/change-password`, {
        method: 'POST',
        headers: adminChatHeaders(),
        body: JSON.stringify({ token, currentPassword, newPassword }),
      });
      const data = await res.json();

      if (!res.ok) {
        setError(data.error || 'Failed to change password');
        return;
      }

      setSuccess(true);
      setCurrentPassword('');
      setNewPassword('');
      setConfirmPassword('');
      setTimeout(() => {
        onClose();
        setSuccess(false);
      }, 2000);
    } catch {
      setError('Network error. Please try again.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm p-4" onClick={onClose}>
      <div
        className="w-full max-w-md rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/10 shadow-2xl p-6"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 mb-5">
          <div className="w-10 h-10 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center">
            <KeyRound className="w-5 h-5 text-brand-600 dark:text-brand-400" />
          </div>
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Change Admin Password</h3>
        </div>

        {success && (
          <div className="mb-4 flex items-center gap-2 rounded-xl bg-green-50 dark:bg-green-500/10 border border-green-200/30 dark:border-green-500/20 px-4 py-3">
            <CheckCircle2 className="w-4 h-4 text-green-600 dark:text-green-400 shrink-0" />
            <span className="text-sm text-green-700 dark:text-green-400">Password changed successfully!</span>
          </div>
        )}

        {error && (
          <div className="mb-4 rounded-xl bg-red-50 dark:bg-red-500/10 border border-red-200/40 dark:border-red-500/20 px-4 py-3">
            <span className="text-sm text-red-600 dark:text-red-400">{error}</span>
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Current Password</label>
            <input
              type="password"
              required
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
              className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">New Password</label>
            <input
              type="password"
              required
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Confirm New Password</label>
            <input
              type="password"
              required
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
            />
          </div>
          <div className="flex gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-5 py-3 text-sm font-medium text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={loading}
              className="flex-1 py-3 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple disabled:opacity-50"
            >
              {loading ? 'Saving...' : 'Update Password'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
