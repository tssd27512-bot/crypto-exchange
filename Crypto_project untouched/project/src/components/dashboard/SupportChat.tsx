import { useState, useEffect, useRef, useCallback } from 'react';
import { MessageCircle, X, Send, User } from 'lucide-react';
import { supabase } from '@/lib/supabase';

interface ChatMessage {
  id: string;
  conversation_id: string;
  sender: 'visitor' | 'agent';
  content: string;
  created_at: string;
}

function getOrCreateVisitorId(): string {
  const KEY = 'gtvx_visitor_id';
  let id = localStorage.getItem(KEY);
  if (!id) {
    id = `v_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
    localStorage.setItem(KEY, id);
  }
  return id;
}

function getOrCreateVisitorName(): string {
  const KEY = 'gtvx_visitor_name';
  let name = localStorage.getItem(KEY);
  if (!name) {
    const num = Math.floor(Math.random() * 9000 + 1000);
    name = `Guest${num}`;
    localStorage.setItem(KEY, name);
  }
  return name;
}

export default function SupportChat() {
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [agentOnline, setAgentOnline] = useState(true);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const visitorId = useRef(getOrCreateVisitorId());
  const visitorName = useRef(getOrCreateVisitorName());

  const scrollToBottom = useCallback(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, []);

  // Load or create conversation when chat opens
  useEffect(() => {
    if (!open || conversationId) return;

    (async () => {
      setLoading(true);
      // Check if conversation exists for this visitor
      const { data: existing } = await supabase
        .from('chat_conversations')
        .select('id, status')
        .eq('visitor_id', visitorId.current)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (existing && existing.status === 'open') {
        setConversationId(existing.id);
        // Load messages
        const { data: msgs } = await supabase
          .from('chat_messages')
          .select('*')
          .eq('conversation_id', existing.id)
          .order('created_at', { ascending: true });
        if (msgs) setMessages(msgs as ChatMessage[]);
      } else {
        // Create new conversation
        const { data: conv, error } = await supabase
          .from('chat_conversations')
          .insert({
            visitor_id: visitorId.current,
            visitor_name: visitorName.current,
            status: 'open',
          })
          .select('id')
          .single();

        if (!error && conv) {
          setConversationId(conv.id);
          // Add welcome message
          await supabase.from('chat_messages').insert({
            conversation_id: conv.id,
            sender: 'agent',
            content: `Welcome to GlobalTradeVX! I'm a real support agent. How can I help you today?`,
          });
        }
      }
      setLoading(false);
    })();
  }, [open, conversationId]);

  // Subscribe to new messages via realtime
  useEffect(() => {
    if (!conversationId) return;

    const channel = supabase
      .channel(`chat:${conversationId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'chat_messages',
          filter: `conversation_id=eq.${conversationId}`,
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
  }, [conversationId]);

  // Auto-scroll on new messages
  useEffect(() => {
    scrollToBottom();
  }, [messages, scrollToBottom]);

  const handleSend = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || !conversationId) return;

    const content = input.trim();
    setInput('');

    // Optimistic: add message immediately
    const tempId = `temp_${Date.now()}`;
    setMessages((prev) => [
      ...prev,
      {
        id: tempId,
        conversation_id: conversationId,
        sender: 'visitor',
        content,
        created_at: new Date().toISOString(),
      },
    ]);

    await supabase.from('chat_messages').insert({
      conversation_id: conversationId,
      sender: 'visitor',
      content,
    });

    // Bump conversation updated_at
    await supabase
      .from('chat_conversations')
      .update({ updated_at: new Date().toISOString() })
      .eq('id', conversationId);
  };

  return (
    <>
      {/* Floating button */}
      <button
        onClick={() => setOpen(!open)}
        className="fixed bottom-6 right-6 z-50 w-14 h-14 rounded-full bg-gradient-to-br from-brand-600 to-brand-700 flex items-center justify-center glow-purple-strong hover:scale-110 transition-transform shadow-xl"
        aria-label="Live support chat"
      >
        {open ? <X className="w-6 h-6 text-white" /> : <MessageCircle className="w-6 h-6 text-white" />}
      </button>

      {/* Chat panel */}
      {open && (
        <div className="fixed bottom-24 right-6 z-50 w-80 max-w-[calc(100vw-3rem)] rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/10 shadow-2xl card-glow overflow-hidden flex flex-col" style={{ maxHeight: '70vh' }}>
          {/* Header */}
          <div className="flex items-center gap-3 px-4 py-3.5 bg-gradient-to-r from-brand-600 to-brand-700 shrink-0">
            <div className="w-9 h-9 rounded-full bg-white/20 flex items-center justify-center">
              <User className="w-5 h-5 text-white" />
            </div>
            <div>
              <div className="text-sm font-semibold text-white">Live Support — Chat with a real person</div>
              <div className="text-xs text-brand-100 flex items-center gap-1.5 mt-0.5">
                <span className={`w-2 h-2 rounded-full ${agentOnline ? 'bg-green-400' : 'bg-gray-400'}`} />
                {agentOnline ? 'Agent online' : 'Agent offline'}
              </div>
            </div>
          </div>

          {/* Messages */}
          <div className="flex-1 overflow-y-auto p-4 space-y-2 scrollbar-hide min-h-[200px]">
            {loading && (
              <div className="flex items-center justify-center py-8">
                <div className="w-6 h-6 border-2 border-brand-500 border-t-transparent rounded-full animate-spin" />
              </div>
            )}
            {!loading && messages.length === 0 && (
              <p className="text-xs text-gray-400 dark:text-gray-600 text-center py-4">
                Start typing to chat with a support agent.
              </p>
            )}
            {messages.map((msg) => (
              <div
                key={msg.id}
                className={`flex ${msg.sender === 'visitor' ? 'justify-end' : 'justify-start'}`}
              >
                <div
                  className={`max-w-[80%] rounded-2xl px-3.5 py-2 text-xs leading-relaxed ${
                    msg.sender === 'visitor'
                      ? 'rounded-tr-sm bg-brand-600 text-white'
                      : 'rounded-tl-sm bg-gray-100 dark:bg-white/5 text-gray-700 dark:text-gray-300'
                  }`}
                >
                  {msg.content}
                </div>
              </div>
            ))}
            <div ref={messagesEndRef} />
          </div>

          {/* Input */}
          <form onSubmit={handleSend} className="px-4 pb-4 shrink-0">
            <div className="flex items-center gap-2 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 px-3 py-2">
              <input
                type="text"
                value={input}
                onChange={(e) => setInput(e.target.value)}
                placeholder="Type a message..."
                disabled={!conversationId}
                className="flex-1 bg-transparent text-sm text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none"
              />
              <button
                type="submit"
                disabled={!input.trim() || !conversationId}
                className="p-1.5 text-brand-600 dark:text-brand-400 disabled:opacity-40 hover:text-brand-700 dark:hover:text-brand-300 transition-colors"
              >
                <Send className="w-4 h-4" />
              </button>
            </div>
          </form>
        </div>
      )}
    </>
  );
}
